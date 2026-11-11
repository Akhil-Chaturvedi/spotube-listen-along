import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

/// Generic plugin-settings contract.
///
/// A plugin can declare settings in its plugin.json:
/// ```json
/// "settings": [
///   {
///     "id": "la_publish_enabled",
///     "title": "Share my Spotube playback",
///     "description": "Friends see what you play here on their Spotify",
///     "type": "switch",
///     "defaultValue": false
///   }
/// ]
/// ```
/// The host renders these under Settings -> Playback (like its own switches)
/// and persists each value under the SAME key the plugin's LocalStorage
/// binding uses (`spotube_plugin.<pluginSlug>.<id>`), so the plugin just
/// reads the key - no plugin-side UI code needed. Nothing about this is
/// listen-along specific: any plugin can declare any switch settings.
class PluginSettingDeclaration {
  final String pluginSlug;
  final String pluginName;
  final String id;
  final String title;
  final String? description;
  final bool defaultValue;

  const PluginSettingDeclaration({
    required this.pluginSlug,
    required this.pluginName,
    required this.id,
    required this.title,
    this.description,
    this.defaultValue = false,
  });

  factory PluginSettingDeclaration.fromJson(
    PluginConfiguration plugin,
    Map<String, dynamic> json,
  ) {
    return PluginSettingDeclaration(
      pluginSlug: plugin.slug,
      pluginName: plugin.name,
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? json['id'] ?? '').toString(),
      description: json['description']?.toString(),
      defaultValue: json['defaultValue'] == true,
    );
  }

  /// The exact key both the plugin's LocalStorage and SharedPreferences use.
  String get storageKey => 'spotube_plugin.$pluginSlug.$id';
}

/// All switch declarations from every installed plugin, flattened.
final pluginSettingsProvider =
    FutureProvider<List<PluginSettingDeclaration>>((ref) async {
  final pluginsState = await ref.watch(metadataPluginsProvider.future);
  final notifier = ref.watch(metadataPluginsProvider.notifier);
  final out = <PluginSettingDeclaration>[];
  for (final plugin in pluginsState.plugins) {
    final rawSettings = await notifier.readPluginSettings(plugin);
    for (final raw in rawSettings) {
      // Only switch settings have a host-side UI for now; anything else is
      // declared but not rendered.
      if ((raw['type'] ?? 'switch').toString() != 'switch') continue;
      final id = (raw['id'] ?? '').toString();
      if (id.isEmpty) continue;
      out.add(PluginSettingDeclaration.fromJson(plugin, raw));
    }
  }
  return out;
});

Future<bool> readPluginSettingValue(String storageKey) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(storageKey) ??
      (prefs.getString(storageKey) == '1'); // legacy string form
}

Future<void> writePluginSettingValue(String storageKey, bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(storageKey, value);
}
