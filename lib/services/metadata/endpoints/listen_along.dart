import 'dart:async';

import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';
import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart'
    show Player;
import 'package:spotube/services/metadata/endpoints/mirror_telemetry.dart';

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
///
/// TEMP DIAGNOSTICS (remove together with mirror_telemetry.dart): every
/// decision, fetch, load, observed pause/resume/track-change and playback
/// start is logged via [MirrorTelemetry] into the in-app Logs page
/// (`.spotube_logs`), tagged [ListenAlong]. The [REPLAY] line includes
/// `entryTsChanged` so we can tell "friend genuinely replayed" (their activity
/// timestamp moved) from "our lead guessed wrong" (timestamp unchanged); the
/// [STARTED] line measures load -> actually-audible; [OBSERVED-*] lines flag
/// transitions the mirror did not cause itself (user actions, endless-radio).
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

  /// TEMP-adjacent improvement from log analysis (2026-11-04): the feed
  /// service pushes a content-change callback the moment a fetch brings a
  /// track/state change. Running the policy immediately instead of waiting
  /// out the next [pollInterval] tick shaves up to 10s off the
  /// friend-changed-song -> our-speakers latency.
  void pokeForFeedChange() {
    if (_timer == null) return; // not mirroring
    unawaited(_policyTick());
  }

  // ---- mirror state (host-owned policy) ----
  String? _startedWith;
  String? _targetUserId;
  String? _lastTrackId;
  bool _wasPlaying = false;
  DateTime? _friendIdleSince;
  DateTime _lastEarlyFetchAt =
      DateTime.fromMillisecondsSinceEpoch(0);

  /// Friend's activity timestamp at the moment WE loaded the current track -
  /// lets the REPLAY log distinguish a genuine friend replay (timestamp
  /// changed) from our lead firing early (timestamp unchanged).
  int? _loadEntryTsMs;
  DateTime? _loadedAt;

  /// Our player's track id as seen by the previous tick (for OBSERVED-*
  /// transition logs).
  String? _lastObservedOurTrackId;

  /// Actions the mirror itself took, with timestamps, so observed playback
  /// transitions can be attributed to "us" vs "the user / endless radio".
  final Map<String, DateTime> _selfActions = {};

  /// How long before OUR song ends we ask for fresh data. Starts at 15s and
  /// self-corrects toward the measured sync lag (see [_adaptLead]), clamped
  /// to 10..30 seconds.
  int _earlyFetchLeadMs = 10000;

  /// After an early fetch, don't ask again for at least this long.
  static const earlyFetchCooldown = Duration(seconds: 15);

  /// Idle that long (with no playback to finish) fully stops the mirror.
  static const idleStopAfter = Duration(minutes: 5);

  // ---- TEMP: playback-start watcher ----
  Timer? _startWatchTimer;
  String? _pendingStartTrackId;
  DateTime? _pendingStartSince;
  bool _pendingStartNoteLogged = false;

  MetadataPluginListenAlongEndpoint(this.hetu, {this.createPlayer});

  /// TEMP telemetry (remove with mirror_telemetry.dart).
  Future<void> _t(String msg) =>
      MirrorTelemetry.log('ListenAlong', msg);

  void _markSelf(String action) => _selfActions[action] = DateTime.now();

  bool _selfActionWithin(String action, Duration window) {
    final at = _selfActions[action];
    return at != null && DateTime.now().difference(at) <= window;
  }

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

  /// The friend's live entry `{ track, timestamp, active }`, or null.
  Future<Map<String, dynamic>?> _currentEntry(String userId) async {
    final instance = _instance;
    if (instance == null) return null;
    try {
      final raw = await instance.invoke(
        "currentEntryFor",
        positionalArgs: [userId],
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : null;
    } catch (e) {
      await _t('entry fetch error for $userId: $e');
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
    _loadEntryTsMs = null;
    _loadedAt = null;
    _lastObservedOurTrackId = null;
    _selfActions.clear();
    if (_player == null && createPlayer != null) {
      _player = createPlayer!();
    }
    await _t(
        'start id=$userId playerWired=${_player != null} leadMs=$_earlyFetchLeadMs');
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

  Future<void> stop({String reason = 'user'}) async {
    if (_startedWith != null) {
      await _t('stop reason=$reason id=$_startedWith');
    }
    _timer?.cancel();
    _timer = null;
    _startWatchTimer?.cancel();
    _startWatchTimer = null;
    _pendingStartTrackId = null;
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
    final friendAgeMs = entry["timestamp"] is num
        ? now.millisecondsSinceEpoch - (entry["timestamp"] as num).toInt()
        : null;

    // Policy 5: friend idle -> let the current song finish, then pause and
    // stop. After 5 idle minutes stop regardless (no zombie mirrors).
    if (!active) {
      _friendIdleSince ??= now;
      final idleMin =
          now.difference(_friendIdleSince!).inMilliseconds / 60000.0;
      if (now.difference(_friendIdleSince!) > idleStopAfter) {
        await _t('IDLE timeout after ${idleMin.toStringAsFixed(1)}min '
            '-> stop mirror');
        await _pauseAndStop();
        return;
      }
      final state = await _playbackState();
      final playing = state?["isPlaying"] == true;
      final remaining = _remainingMs(state);
      await _t('IDLE friend idleSince=${idleMin.toStringAsFixed(1)}min '
          'playing=$playing remainingMs=$remaining '
          '-> ${!playing || (remaining != null && remaining <= _earlyFetchLeadMs) ? "stop now" : "finish current song"}');
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
    if (track is! Map) {
      await _t('no playable track object yet (thin entry), waiting');
      return; // thin/unresolved yet; next tick retries
    }
    final trackId = track["id"];
    if (trackId == null) return;

    // Policy 1: friend's track changed -> play the new one.
    if (trackId != _lastTrackId) {
      final old = _lastTrackId;
      final name = track["name"];
      final durationMs = track["durationMs"];
      await _t('PLAY newTrack oldId=$old newId=$trackId name="$name" '
          'friendAgeMs=$friendAgeMs durationMs=$durationMs');
      _lastTrackId = trackId;
      _loadEntryTsMs =
          entry["timestamp"] is num ? (entry["timestamp"] as num).toInt() : null;
      _loadedAt = now;
      if (player != null) {
        try {
          _markSelf('load');
          final t0 = DateTime.now();
          await player.loadTracks(
            [Map<String, dynamic>.from(track)],
            autoPlay: true,
          );
          await _t('loadTracks returned in '
              '${DateTime.now().difference(t0).inMilliseconds}ms '
              '(stream resolution happens lazily on the player side)');
          _watchStart(trackId.toString());
        } catch (e) {
          await _t('loadTracks FAILED: $e');
        }
      } else {
        await _t('no player wired; data-only mirror');
      }
      _adaptLead(entry, oldLead: _earlyFetchLeadMs);
      _wasPlaying = true;
      return;
    }

    // Policy 2/3/4: same track - inspect OUR playback.
    if (player == null) return;
    final state = await _playbackState();
    if (state == null) return;
    final playing = state["isPlaying"] == true;
    final remaining = _remainingMs(state);
    final friendRemainingMs = (friendAgeMs != null && track["durationMs"] is num)
        ? (track["durationMs"] as num).toInt() - friendAgeMs
        : null;
    final ourActive = state["activeTrack"];
    final ourTrackId = ourActive is Map ? ourActive["id"] : null;
    final drift =
        ourTrackId != null && ourTrackId.toString() != trackId.toString();
    final sinceLoadMs =
        _loadedAt != null ? now.difference(_loadedAt!).inMilliseconds : null;

    // TEMP attribution: transitions the mirror did NOT just cause itself.
    if (_wasPlaying && !playing && !_selfActionWithin('pause', const Duration(seconds: 5))) {
      await _t('OBSERVED-PAUSE posMs=${state["positionMs"]} '
          'ourRemainingMs=$remaining (not ours -> user?)');
    }
    if (!_wasPlaying &&
        playing &&
        !_selfActionWithin('play', const Duration(seconds: 25)) &&
        !_selfActionWithin('load', const Duration(seconds: 25))) {
      await _t('OBSERVED-RESUME posMs=${state["positionMs"]} '
          '(not ours -> user?)');
    }
    if (_lastObservedOurTrackId != null &&
        ourTrackId != null &&
        ourTrackId.toString() != _lastObservedOurTrackId &&
        !_selfActionWithin('load', const Duration(seconds: 25))) {
      await _t('OBSERVED-TRACK-CHANGE '
          'old=$_lastObservedOurTrackId new=$ourTrackId '
          '(not ours -> user skip / endless radio?)');
    }
    _lastObservedOurTrackId = ourTrackId?.toString();

    if (playing && remaining != null && remaining <= _earlyFetchLeadMs) {
      // Policy 3: our song is about to end - the friend may have skipped.
      // Ask for fresh data NOW (rate-limited); the next tick plays the new
      // track if there is one.
      final cooldownOk =
          now.difference(_lastEarlyFetchAt) >= earlyFetchCooldown;
      await _t('EARLY-FETCH ourRemainingMs=$remaining leadMs=$_earlyFetchLeadMs '
          'friendRemainingMs=$friendRemainingMs friendAgeMs=$friendAgeMs '
          'sinceLoadMs=$sinceLoadMs cooldownOk=$cooldownOk');
      if (cooldownOk) {
        _lastEarlyFetchAt = now;
        onDemandDataRefresh?.call();
      }
    } else if (!playing &&
        _wasPlaying &&
        remaining != null &&
        remaining <= _earlyFetchLeadMs + 2000) {
      // Policy 4: our song ENDED but the friend is still on the same track -
      // they replayed/looped it. Seek back and keep mirroring.
      // TEMP: entryTsChanged=true means the friend's activity timestamp moved
      // since we loaded the track (genuine replay); false means our lead
      // simply fired while the friend was still on the same playthrough.
      final entryTs = entry["timestamp"] is num
          ? (entry["timestamp"] as num).toInt()
          : null;
      await _t('REPLAY seek0 ourRemainingMs=$remaining '
          'friendRemainingMs=$friendRemainingMs friendAgeMs=$friendAgeMs '
          'entryTsNow=$entryTs entryTsAtLoad=$_loadEntryTsMs '
          'entryTsChanged=${entryTs != null && _loadEntryTsMs != null && entryTs != _loadEntryTsMs} '
          'posMs=${state["positionMs"]} ourTrackId=$ourTrackId');
      try {
        _markSelf('seek');
        _markSelf('play');
        await player.seek(0);
        await player.play();
      } catch (e) {
        await _t('replay seek/play FAILED: $e');
      }
    } else {
      await _t('no-change playing=$playing positionMs=${state["positionMs"]} '
          'durationMs=${(state["activeTrack"] is Map) ? (state["activeTrack"] as Map)["durationMs"] : null} '
          'ourRemainingMs=$remaining friendRemainingMs=$friendRemainingMs '
          'ourTrackId=$ourTrackId${drift ? " DRIFT(friend=$trackId)" : ""} '
          'wasPlaying=$_wasPlaying sinceLoadMs=$sinceLoadMs');
    }
    // Policy 6: !playing with lots of remaining = the user paused manually.
    _wasPlaying = playing;
  }

  /// TEMP: watches until the track we just loaded is ACTUALLY audible
  /// (isPlaying on that id) and logs the load -> playing delta, which
  /// includes sourcing/stream-resolution time. Also catches "never started"
  /// (sourcing failed) and "overridden" (radio/user took the queue).
  void _watchStart(String trackId) {
    _startWatchTimer?.cancel();
    _pendingStartTrackId = trackId;
    _pendingStartSince = DateTime.now();
    _pendingStartNoteLogged = false;
    var ticks = 0;
    _startWatchTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!identical(_startWatchTimer, timer)) return; // superseded watcher
      ticks++;
      final since = _pendingStartSince;
      final id = _pendingStartTrackId;
      if (since == null || id == null) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(since).inMilliseconds;
      final state = await _playbackState();
      if (state == null) return;
      final active = state["activeTrack"];
      final activeId = active is Map ? active["id"]?.toString() : null;
      if (state["isPlaying"] == true && activeId == id) {
        timer.cancel();
        _startWatchTimer = null;
        _pendingStartTrackId = null;
        await _t('STARTED id=$id load->play=${elapsed}ms '
            'posMs=${state["positionMs"]}');
        return;
      }
      if (!_pendingStartNoteLogged && ticks >= 5) {
        _pendingStartNoteLogged = true;
        await _t('start-watch 5s: playing=${state["isPlaying"]} '
            'activeId=$activeId posMs=${state["positionMs"]} '
            '(still sourcing/stream-resolving?)');
      }
      if (state["isPlaying"] == true && activeId != null && activeId != id) {
        timer.cancel();
        _startWatchTimer = null;
        _pendingStartTrackId = null;
        await _t('OVERRIDDEN wanted=$id but player is on $activeId '
            'after ${elapsed}ms (endless radio / user?)');
        return;
      }
      if (ticks >= 20) {
        timer.cancel();
        _startWatchTimer = null;
        _pendingStartTrackId = null;
        await _t('NEVER-STARTED id=$id after ${elapsed}ms '
            '(sourcing failed? see TrackNotFoundError in logs)');
      }
    });
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
  void _adaptLead(Map<String, dynamic> entry, {int? oldLead}) {
    final timestampMs = entry["timestamp"];
    if (timestampMs is! num) return;
    final lagMs = DateTime.now().millisecondsSinceEpoch - timestampMs.toInt();
    if (lagMs < 3000 || lagMs > 60000) return; // nonsense samples
    final target = lagMs + 3000; // lag + reaction margin
    _earlyFetchLeadMs = (
      0.6 * _earlyFetchLeadMs + 0.4 * target
    ).clamp(10000, 30000).toInt();
    unawaited(_t('lead adapt lagMs=$lagMs leadMs=${oldLead ?? "?"}'
        '->$_earlyFetchLeadMs'));
  }

  Future<void> _pauseAndStop() async {
    final player = _player;
    if (player != null) {
      try {
        _markSelf('pause');
        await player.pause();
      } catch (_) {}
    }
    _wasPlaying = false;
    await stop(reason: 'auto (friend idle)');
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
    _startWatchTimer?.cancel();
    _startWatchTimer = null;
  }
}
