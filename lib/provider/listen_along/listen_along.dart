import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

/// The Spotify user id (without the `friend-` prefix) currently being mirrored,
/// or null. Backed by the plugin's own `listenAlong.activeUserId()`.
class ListenAlongController extends Notifier<String?> {
  @override
  String? build() => null;

  Future<void> start(String userId) async {
    final plugin = await ref.read(metadataPluginProvider.future);
    if (plugin == null) return;
    await plugin.listenAlong.start(userId);
    state = userId;
  }

  Future<void> stop() async {
    final plugin = await ref.read(metadataPluginProvider.future);
    if (plugin == null) return;
    await plugin.listenAlong.stop();
    state = null;
  }

  Future<void> toggle(String userId) async {
    if (state == userId) {
      await stop();
    } else {
      await start(userId);
    }
  }
}

final listenAlongControllerProvider =
    NotifierProvider<ListenAlongController, String?>(ListenAlongController.new);
