import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart';
import 'package:media_kit/media_kit.dart' hide Track, Player;
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

/// Builds a [Player] that lets a plugin drive Spotube's real player.
///
/// This is the generic "plugin can control playback" primitive. It contains no
/// metadata-provider specifics: a plugin hands us plain track maps and we play
/// them through the normal pipeline. Any plugin (listen-along, radio, DJ queues,
/// remote control, ...) can use it.
Player createSpotubePlayer(Ref ref) {
  final notifier = ref.read(audioPlayerProvider.notifier);

  SpotubeFullTrackObject parseTrack(Map<String, dynamic> json) =>
      SpotubeFullTrackObject.fromJson(json);

  return Player(
    loadTracks: (tracks, {autoPlay = false, initialIndex = 0}) async {
      final parsed = tracks.map(parseTrack).toList();
      if (parsed.isEmpty) return;
      await notifier.load(
        parsed,
        autoPlay: autoPlay,
        initialIndex: initialIndex.clamp(0, parsed.length - 1),
      );
    },
    playTrack: (track) async {
      await notifier.load([parseTrack(track)], autoPlay: true);
    },
    addToQueue: (track) async {
      await notifier.addTrack(parseTrack(track));
    },
    play: () async {
      await audioPlayer.resume();
    },
    pause: () async {
      await audioPlayer.pause();
    },
    next: () async {
      await audioPlayer.skipToNext();
    },
    previous: () async {
      await audioPlayer.skipToPrevious();
    },
    seek: (positionMs) async {
      await audioPlayer.seek(Duration(milliseconds: positionMs));
    },
    getState: () async {
      final state = ref.read(audioPlayerProvider);
      return {
        'activeTrack': state.activeTrack?.toJson(),
        'queue': state.tracks.map((t) => t.toJson()).toList(),
        'currentIndex': state.currentIndex,
        'positionMs': audioPlayer.position.inMilliseconds,
        'isPlaying': state.playing,
        // Connect-state reflection: official clients read these from our
        // published state to render toggle states for our virtual device.
        'shufflingContext': state.shuffled,
        'repeatingContext': state.loopMode == PlaylistMode.loop,
        'repeatingTrack': state.loopMode == PlaylistMode.single,
      };
    },
    setVolume: (volume) async {
      await audioPlayer.setVolume(volume.clamp(0.0, 1.0));
    },
  );
}
