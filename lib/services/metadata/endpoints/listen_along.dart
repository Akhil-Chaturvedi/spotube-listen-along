import 'dart:async';

import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';

/// Generic host wrapper over an *optional* plugin member named `listenAlong`.
///
/// The host does not know or care that this is Spotify: any metadata plugin may
/// expose a `listenAlong` object with `availableFriends()`, `activeUserId()`,
/// `start(userId)`, `stop()` and `tick()`. If the current plugin does not,
/// [isSupported] is false and the UI hides itself. All provider-specific logic
/// (buddylist, playback policy) lives inside the plugin.
///
/// The host owns the polling clock because hetu cannot resolve the internal
/// `_Timer` object returned by `std.Timer` (it throws "Undefined identifier
/// [_Timer]"). So we schedule a Dart [Timer] here and call the plugin's `tick()`.
class MetadataPluginListenAlongEndpoint {
  final Hetu hetu;
  Timer? _timer;

  /// Poll interval for mirroring the friend's current track.
  static const pollInterval = Duration(seconds: 10);

  /// Slow maintenance loop: many plugins use [tick] for periodic upkeep (e.g.
  /// refreshing their own auth token) even when nothing is being mirrored.
  /// Fire-and-forget and cheap - the plugin early-returns when idle.
  static const keepAliveInterval = Duration(minutes: 1);
  Timer? _keepAliveTimer;

  /// Notified with the plugin's current active id after every tick, so the
  /// host can sync its UI state when the plugin auto-stops (e.g. the live
  /// entity went idle). Null means mirroring stopped.
  void Function(String? activeId)? onActiveIdChanged;

  MetadataPluginListenAlongEndpoint(this.hetu);

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

  Future<List<Map<String, dynamic>>> availableFriends() async {
    final instance = _instance;
    if (instance == null) return const [];
    final raw = await instance.invoke("availableFriends");
    return (raw as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  String? activeUserId() {
    final instance = _instance;
    if (instance == null) return null;
    final value = instance.invoke("activeUserId");
    return value as String?;
  }

  Future<void> start(String userId) async {
    final instance = _instance;
    if (instance == null) return;
    await instance.invoke("start", positionalArgs: [userId]);
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final instance = _instance;
    if (instance == null) return;
    await instance.invoke("stop");
  }

  void _tick() {
    final instance = _instance;
    if (instance == null) return;
    // Fire and forget; the plugin guards its own state.
    instance.invoke("tick");

    // Sync mirroring state: the plugin may have auto-stopped (the live entity
    // went idle), in which case its activeUserId() becomes null.
    final activeId = activeUserId();
    if (activeId == null) {
      _timer?.cancel();
      _timer = null;
    }
    onActiveIdChanged?.call(activeId);
  }

  /// Starts the slow maintenance loop (idempotent). Call once after the
  /// plugin has loaded. Skipped while the faster mirroring loop is running,
  /// since that one already ticks.
  void startKeepAlive() {
    _keepAliveTimer ??= Timer.periodic(keepAliveInterval, (_) {
      final instance = _instance;
      if (instance == null) return;
      if (_timer != null) return; // mirroring loop is already ticking
      instance.invoke("tick");
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }
}
