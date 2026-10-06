/// A generic, host-provided playback-control surface for Spotube plugins.
///
/// This is intentionally free of any metadata-provider specifics: a plugin
/// hands the host plain track maps (the same shape as `MetadataTrack`) and the
/// host plays them through its normal metadata + audio-source pipeline. That
/// makes it reusable for any plugin that needs to drive playback (listen-along,
/// radio, DJ/party queues, scrobble playback, remote control, ...).
///
/// All functions are supplied by the host; this class is just a typed bag of
/// callbacks that the Hetu binding forwards to.
class SpotubePlayer {
  /// Replace the current queue with [tracks] and optionally start playing.
  final Future<void> Function(
    List<Map<String, dynamic>> tracks, {
    bool autoPlay,
    int initialIndex,
  })
  loadTracks;

  /// Play a single track immediately (replaces the queue).
  final Future<void> Function(Map<String, dynamic> track) playTrack;

  /// Append a track to the end of the current queue.
  final Future<void> Function(Map<String, dynamic> track) addToQueue;

  /// Resume playback.
  final Future<void> Function() play;

  /// Pause playback.
  final Future<void> Function() pause;

  /// Skip to the next track.
  final Future<void> Function() next;

  /// Go to the previous track.
  final Future<void> Function() previous;

  /// Seek to [positionMs] within the active track.
  final Future<void> Function(int positionMs) seek;

  /// Current player state as a map:
  /// `{ activeTrack: <track map>|null, queue: [<track map>], currentIndex: int,
  ///    positionMs: int, isPlaying: bool }`
  final Future<Map<String, dynamic>> Function() getState;

  const SpotubePlayer({
    required this.loadTracks,
    required this.playTrack,
    required this.addToQueue,
    required this.play,
    required this.pause,
    required this.next,
    required this.previous,
    required this.seek,
    required this.getState,
  });
}
