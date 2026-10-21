import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

/// The opaque live-entity id currently being mirrored (whatever id was passed
/// to the plugin's `listenAlong.start`, e.g. a live card's playlist id), or
/// null. Backed by the plugin's own `listenAlong.activeUserId()`.
class ListenAlongController extends Notifier<String?> {
  @override
  String? build() => null;

  Future<void> start(String id) async {
    final plugin = await ref.read(metadataPluginProvider.future);
    if (plugin == null) return;
    // Keep our state in sync when the plugin auto-stops (entity went idle).
    plugin.listenAlong.onActiveIdChanged = (activeId) => state = activeId;
    await plugin.listenAlong.start(id);
    state = id;
  }

  Future<void> stop() async {
    final plugin = await ref.read(metadataPluginProvider.future);
    if (plugin == null) return;
    await plugin.listenAlong.stop();
    state = null;
  }

  Future<void> toggle(String id) async {
    // Consult the plugin's current state (not our possibly-stale mirror) so
    // tapping after an auto-stop correctly restarts instead of "stopping".
    final plugin = await ref.read(metadataPluginProvider.future);
    final current = plugin?.listenAlong.activeUserId();
    if (current == id) {
      await stop();
    } else {
      await start(id);
    }
  }
}

final listenAlongControllerProvider =
    NotifierProvider<ListenAlongController, String?>(ListenAlongController.new);
