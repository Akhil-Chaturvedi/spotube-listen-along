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

  MetadataPluginListenAlongEndpoint(this.hetu);

  HTInstance? get _instance {
    final plugin = hetu.fetch("metadataPlugin");
    if (plugin is! HTInstance) return null;
    final member = plugin.memberGet("listenAlong");
    return member is HTInstance ? member : null;
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
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
