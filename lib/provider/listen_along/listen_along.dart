import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/services/logger/logger.dart';

/// How often we ask the metadata plugin for the friend's current track.
///
/// Spotify exposes friend activity through a *polling* endpoint (there is no
/// push/websocket for it), so we poll. 10s is a good balance: responsive enough
/// that a skip is mirrored almost immediately, while staying far below any
/// rate limit. We do NOT poll every second - that would be wasteful and could
/// get the account throttled.
const _listenAlongPollInterval = Duration(seconds: 10);

class ListenAlongState {
  /// The Spotify user id of the friend we are mirroring, or null when inactive.
  final String? friendId;

  /// Display name of the friend (for the UI).
  final String? friendName;

  /// The id of the last track we auto-played, so we only act on changes.
  final String? lastTrackId;

  /// When we last saw a new track.
  final DateTime? lastSync;

  /// True when we are actively mirroring a friend.
  bool get isActive => friendId != null;

  const ListenAlongState({
    this.friendId,
    this.friendName,
    this.lastTrackId,
    this.lastSync,
  });

  ListenAlongState copyWith({
    String? friendId,
    String? friendName,
    String? lastTrackId,
    DateTime? lastSync,
  }) {
    return ListenAlongState(
      friendId: friendId ?? this.friendId,
      friendName: friendName ?? this.friendName,
      lastTrackId: lastTrackId ?? this.lastTrackId,
      lastSync: lastSync ?? this.lastSync,
    );
  }
}

/// Mirrors a friend's currently-playing track into the local player.
///
/// This is deliberately a *host* feature: the metadata plugin already exposes
/// each friend's current track (via its synthetic `friend-<userId>` playlist),
/// so the host can poll that and drive its own player. No plugin-binding
/// changes are required, and it works with any plugin that implements the same
/// `friend-<userId>` convention.
class ListenAlongNotifier extends Notifier<ListenAlongState> {
  Timer? _timer;

  @override
  ListenAlongState build() {
    ref.onDispose(() {
      _timer?.cancel();
    });
    return const ListenAlongState();
  }

  /// Begin mirroring [friendId] (the Spotify user id, without the `friend-`
  /// prefix). [friendName] is only used for display.
  void start(String friendId, String friendName) {
    _timer?.cancel();
    state = ListenAlongState(friendId: friendId, friendName: friendName);
    _timer = Timer.periodic(_listenAlongPollInterval, (_) => _tick());
    _tick();
  }

  /// Stop mirroring.
  void stop() {
    _timer?.cancel();
    _timer = null;
    state = const ListenAlongState();
  }

  Future<void> _tick() async {
    final friendId = state.friendId;
    if (friendId == null) return;

    try {
      final plugin = await ref.read(metadataPluginProvider.future);
      if (plugin == null) return;

      // The plugin exposes the friend's current track as a one-item playlist
      // with id `friend-<userId>`.
      final page = await plugin.playlist.tracks(
        'friend-$friendId',
        limit: 1,
      );
      if (page.items.isEmpty) return;

      final track = page.items.first;
      if (track.id == state.lastTrackId) return; // nothing changed

      state = state.copyWith(
        lastTrackId: track.id,
        lastSync: DateTime.now(),
      );

      // Replace the queue with just this track and start playing it. We start
      // from the beginning because the friend feed does not expose the friend's
      // current playback position.
      await ref.read(audioPlayerProvider.notifier).load(
            [track],
            autoPlay: true,
          );
    } catch (e, stack) {
      // Never let a transient failure (no audio source, 401, endpoint hiccup)
      // kill the timer; just log and try again on the next tick.
      AppLogger.reportError(e, stack);
    }
  }
}

final listenAlongProvider =
    NotifierProvider<ListenAlongNotifier, ListenAlongState>(
  ListenAlongNotifier.new,
);
