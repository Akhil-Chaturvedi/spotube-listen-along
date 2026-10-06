import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_script/values.dart';

/// Generic host wrapper over an *optional* plugin member named `listenAlong`.
///
/// The host does not know or care that this is Spotify: any metadata plugin may
/// expose a `listenAlong` object with `availableFriends()`, `activeUserId()`,
/// `start(userId)` and `stop()`. If the current plugin does not, [isSupported]
/// is false and the UI hides itself. All provider-specific logic (buddylist,
/// polling, playback policy) lives inside the plugin.
class MetadataPluginListenAlongEndpoint {
  final Hetu hetu;
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
  }

  Future<void> stop() async {
    final instance = _instance;
    if (instance == null) return;
    await instance.invoke("stop");
  }
}
