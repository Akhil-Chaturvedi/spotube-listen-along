import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/services/kv_store/kv_store.dart';

/// Tracks hidden from specific playlists in Spotube only ("Remove from this
/// playlist"). Keyed by playlistId -> set of hidden trackIds. Purely local:
/// the metadata source's playlist is never touched, so a re-import or a
/// source-side change restores the track.
class HiddenPlaylistTracksNotifier
    extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() {
    return KVStoreService.hiddenPlaylistTracks
        .map((key, value) => MapEntry(key, value.toSet()));
  }

  Future<void> _persist() async {
    await KVStoreService.setHiddenPlaylistTracks(
      state.map((key, value) => MapEntry(key, value.toList())),
    );
  }

  Future<void> hide(String playlistId, String trackId) async {
    final tracks = {...state};
    final set = {...(tracks[playlistId] ?? const <String>{})};
    set.add(trackId);
    tracks[playlistId] = set;
    state = tracks;
    await _persist();
  }

  bool isHidden(String playlistId, String trackId) {
    return state[playlistId]?.contains(trackId) ?? false;
  }

  Set<String> hiddenIdsFor(String playlistId) {
    return state[playlistId] ?? const <String>{};
  }
}

final hiddenPlaylistTracksProvider = NotifierProvider<
    HiddenPlaylistTracksNotifier, Map<String, Set<String>>>(
  HiddenPlaylistTracksNotifier.new,
);
