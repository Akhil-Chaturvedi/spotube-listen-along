import 'package:flutter/material.dart' show ListTile;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:spotube/provider/metadata_plugin/plugin_settings.dart';

/// Renders every switch a plugin declared in its plugin.json under
/// Settings -> Playback, styled exactly like the host's own switches.
/// Generic: nothing here knows about any specific plugin.
class PluginSettingsTiles extends HookConsumerWidget {
  const PluginSettingsTiles({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final declarations = ref.watch(pluginSettingsProvider);

    return declarations.when(
      data: (list) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final declaration in list)
            _PluginSwitchTile(declaration: declaration),
        ],
      ),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _PluginSwitchTile extends HookWidget {
  final PluginSettingDeclaration declaration;

  const _PluginSwitchTile({required this.declaration});

  @override
  Widget build(BuildContext context) {
    final value = useState(false);
    final loaded = useState(false);

    useEffect(() {
      readPluginSettingValue(declaration.storageKey).then((v) {
        value.value = v;
        loaded.value = true;
      });
      return null;
    }, [declaration.storageKey]);

    return ListTile(
      title: Text(declaration.title),
      subtitle:
          declaration.description == null ? null : Text(declaration.description!),
      trailing: Switch(
        value: loaded.value ? value.value : declaration.defaultValue,
        onChanged: (v) async {
          value.value = v;
          await writePluginSettingValue(declaration.storageKey, v);
        },
      ),
    );
  }
}
