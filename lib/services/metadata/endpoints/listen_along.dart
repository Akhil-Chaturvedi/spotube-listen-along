import 'dart:async';

import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart'
    show Player;

/// Generic host wrapper over an *optional* plugin member named `listenAlong`.
///
/// The host does not know or care that this is Spotify: any metadata plugin may
/// expose a `listenAlong` object with `availableFriends()`, `activeUserId()`,
/// `start(userId)`, `stop()`, `tick()` and `currentEntryFor(userId)`. If the
/// current plugin does not, [isSupported] is false and the UI hides itself.
///
/// The host owns BOTH the clock and the MIRROR POLICY. Hetu proved unable to
/// dispatch external-instance methods from inside async callbacks
/// ("Undefined identifier [Player]" from `player.loadTracks(...)` inside a
/// `.then` closure), so playback control lives entirely on this side now: the
/// plugin only supplies DATA (`currentEntryFor`), and this endpoint implements
/// the mirroring rules in plain Dart against the same [Player] bridge the
/// hetu binding exposes:
///
///  1. friend's track id changed  -> load + play the new track (from 0:00)
///  2. friend's track unchanged   -> do nothing (never restart/seek)
///  3. our song is ending soon    -> request one immediate data refresh
///                                   ([onDemandDataRefresh], adaptive lead)
///  4. our song ended but the friend is still on the same track -> they
///     replayed/looped it: seek(0) + resume to stay in sync
///  5. friend went idle           -> let the current song FINISH, then pause
///                                   and stop mirroring; after 5 idle minutes
///                                   stop regardless
///  6. user paused manually       -> respect it (no auto-resume mid-song)
class MetadataPluginListenAlongEndpoint {
  final Hetu hetu;

  /// Host-supplied playback surface (the generic plugin player bridge).
  /// Null when the host didn't wire playback; the mirror then degrades to
  /// data-only (no playback control).
  final Player Function()? createPlayer;
  Player? _player;

  Timer? _timer;

  /// Poll interval for mirroring the friend's current track.
  static const pollInterval = Duration(seconds: 10);

  /// Slow maintenance loop: many plugins use [tick] for periodic upkeep (e.g.
  /// refreshing their own auth token) even when nothing is being mirrored.
  /// Fire-and-forget and cheap - the plugin early-returns when idle.
  static const keepAliveInterval = Duration(minutes: 1);
  Timer? _keepAliveTimer;

  /// Notified with the current active id after every tick, so the host can
  /// sync its UI state when mirroring stops (manual or auto). Null means
  /// mirroring stopped.
  void Function(String? activeId)? onActiveIdChanged;

  /// Optional hook: the mirror wants FRESH data NOW (our song is ending and
  /// the friend may have skipped ahead). Wired to the data service's
  /// immediate refresh. Rate-limited by the caller's own demand model.
  void Function()? onDemandDataRefresh;

  // ---- mirror state (host-owned policy) ----
  String? _startedWith;
  String? _targetUserId;
  String? _lastTrackId;
  bool _wasPlaying = false;
  DateTime? _friendIdleSince;
  DateTime _lastEarlyFetchAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// How long before OUR song ends we ask for fresh data. Starts at 15s and
  /// self-corrects toward the measured sync lag (see [_adaptLead]), clamped
  /// to 10..30 seconds.
  int _earlyFetchLeadMs = 15000;

  /// After an early fetch, don't ask again for at least this long.
  static const earlyFetchCooldown = Duration(seconds: 15);

  /// Idle that long (with no playback to finish) fully stops the mirror.
  static const idleStopAfter = Duration(minutes: 5);

  MetadataPluginListenAlongEndpoint(this.hetu, {this.createPlayer});

  HTInstance? get _instance {
    final plugin = hetu.fetch("metadataPlugin");
    if (plugin is! HTInstance) return null;
    try {
      final member = plugin.memberGet("listenAlong");
      return member is HTInstance ? member : null;
    } catch (_) {
      // The plugin does not expose a `listenAlong` member.
      return null;
    }
  }

  bool get isSupported => _instance != null;

  /// True while the faster mirroring loop is running (the host started a
  /// Listen-Along mirror). Exposed so the Spotify session service knows to
  /// keep the feed fresh even when no friend surface is visible.
  bool get isMirroring => _timer != null;

  Future<List<Map<String, dynamic>>> availableFriends() async {
    final instance = _instance;
    if (instance == null) return const [];
    final raw = await instance.invoke("availableFriends");
    return (raw as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  String? activeUserId() => _startedWith;

  /// The friend's live entry `{ track, timestampMs, active }`, or null.
  Future<Map<String, dynamic>?> _currentEntry(String userId) async {
    final instance = _instance;
    if (instance == null) return null;
    try {
      final raw = await instance.invoke(
        "currentEntryFor",
        positionalArgs: [userId],
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> start(String userId) async {
    final instance = _instance;
    if (instance == null) return;
    _startedWith = userId;
    _targetUserId = userId.startsWith("friend-")
        ? userId.substring("friend-".length)
        : userId;
    _lastTrackId = null;
    _friendIdleSince = null;
    _wasPlaying = false;
    if (_player == null && createPlayer != null) {
      _player = createPlayer!();
    }
    try {
      await instance.invoke("start", positionalArgs: [userId]);
    } catch (_) {
      // The plugin's own start is best-effort state-keeping.
    }
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    // Not awaited: ListenAlongController.start sets its UI state right after
    // this returns, and an immediate auto-stop (friend idle, nothing playing)
    // must be able to override it afterwards, not before.
    unawaited(_policyTick());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _startedWith = null;
    _targetUserId = null;
    _lastTrackId = null;
    _friendIdleSince = null;
    final instance = _instance;
    if (instance == null) return;
    try {
      await instance.invoke("stop");
    } catch (_) {}
  }

  void _tick() {
    // Plugin maintenance (auth token refresh, feed-change refresh pushes) -
    // fire and forget; the plugin guards its own state.
    final instance = _instance;
    if (instance != null) {
      unawaited(Future.sync(() => instance.invoke("tick")).catchError((_) {}));
    }

    unawaited(_policyTick());
    onActiveIdChanged?.call(_startedWith);
  }

  Future<Map<String, dynamic>?> _playbackState() async {
    final player = _player;
    if (player == null) return null;
    try {
      return await player.getState();
    } catch (_) {
      return null;
    }
  }

  Future<void> _policyTick() async {
    final target = _targetUserId;
    if (target == null) return;
    final player = _player;

    final entry = await _currentEntry(target);
    if (entry == null) return;

    final active = entry["active"] == true;
    final now = DateTime.now();

    // Policy 5: friend idle -> let the current song finish, then pause and
    // stop. After 5 idle minutes stop regardless (no zombie mirrors).
    if (!active) {
      _friendIdleSince ??= now;
      if (now.difference(_friendIdleSince!) > idleStopAfter) {
        await _pauseAndStop();
        return;
      }
      final state = await _playbackState();
      final playing = state?["isPlaying"] == true;
      final remaining = _remainingMs(state);
      if (!playing || (remaining != null && remaining <= _earlyFetchLeadMs)) {
        // Song finished (or nothing playing): stop now.
        await _pauseAndStop();
        return;
      }
      _wasPlaying = playing;
      return; // keep enjoying the rest of the track
    }
    _friendIdleSince = null;

    final track = entry["track"];
    if (track is! Map) return; // thin/unresolved yet; next tick retries
    final trackId = track["id"];
    if (trackId == null) return;

    // Policy 1: friend's track changed -> play the new one.
    if (trackId != _lastTrackId) {
      _lastTrackId = trackId;
      if (player != null) {
        try {
          await player.loadTracks(
            [Map<String, dynamic>.from(track)],
            autoPlay: true,
          );
        } catch (_) {}
      }
      _adaptLead(entry);
      _wasPlaying = true;
      return;
    }

    // Policy 2/3/4: same track - inspect OUR playback.
    if (player == null) return;
    final state = await _playbackState();
    if (state == null) return;
    final playing = state["isPlaying"] == true;
    final remaining = _remainingMs(state);

    if (playing && remaining != null && remaining <= _earlyFetchLeadMs) {
      // Policy 3: our song is about to end - the friend may have skipped.
      // Ask for fresh data NOW (rate-limited); the next tick plays the new
      // track if there is one.
      if (now.difference(_lastEarlyFetchAt) >= earlyFetchCooldown) {
        _lastEarlyFetchAt = now;
        onDemandDataRefresh?.call();
      }
    } else if (!playing &&
        _wasPlaying &&
        remaining != null &&
        remaining <= _earlyFetchLeadMs + 2000) {
      // Policy 4: our song ENDED but the friend is still on the same track -
      // they replayed/looped it. Seek back and keep mirroring.
      try {
        await player.seek(0);
        await player.play();
      } catch (_) {}
    }
    // Policy 6: !playing with lots of remaining = the user paused manually.
    _wasPlaying = playing;
  }

  /// Remaining milliseconds of OUR active track (null when unknown).
  int? _remainingMs(Map<String, dynamic>? state) {
    if (state == null) return null;
    final track = state["activeTrack"];
    final duration = track is Map ? track["durationMs"] : null;
    final position = state["positionMs"];
    if (duration is num && position is num) {
      return (duration.toInt() - position.toInt());
    }
    return null;
  }

  /// Self-correcting early-fetch lead: blend the measured sync lag (how long
  /// after the friend's activity timestamp we actually started playing)
  /// toward the lead we use next time, clamped to 10..30 seconds.
  void _adaptLead(Map<String, dynamic> entry) {
    // The plugin's entry shape is { track, timestamp (epoch ms), active }.
    final timestampMs = entry["timestamp"];
    if (timestampMs is! num) return;
    final lagMs = DateTime.now().millisecondsSinceEpoch - timestampMs.toInt();
    if (lagMs < 3000 || lagMs > 60000) return; // nonsense samples
    final target = lagMs + 3000; // lag + reaction margin
    _earlyFetchLeadMs = (
      0.6 * _earlyFetchLeadMs + 0.4 * target
    ).clamp(10000, 30000).toInt();
  }

  Future<void> _pauseAndStop() async {
    final player = _player;
    if (player != null) {
      try {
        await player.pause();
      } catch (_) {}
    }
    _wasPlaying = false;
    await stop();
    onActiveIdChanged?.call(null);
  }

  /// Starts the slow maintenance loop (idempotent). Call once after the
  /// plugin has loaded. Skipped while the faster mirroring loop is running,
  /// since that one already ticks.
  void startKeepAlive() {
    _keepAliveTimer ??= Timer.periodic(keepAliveInterval, (_) async {
      final instance = _instance;
      if (instance == null) return;
      if (_timer != null) return; // mirroring loop is already ticking
      try {
        await instance.invoke("tick");
      } catch (_) {
        // Plugin maintenance is best-effort; never let it kill the clock.
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }
}
