import 'package:hetu_script/external/external_class.dart';
import 'package:hetu_script/hetu_script.dart';

/// Exposes a static `Plugin` class to Hetu so a plugin can ask the host to
/// refresh the current metadata provider's Browse sections.
///
/// The host supplies `onRequestRefresh`, which should invalidate whatever
/// provider holds the Browse sections. This lets plugins drive their own
/// refresh cadence instead of the host polling blindly.
class PluginClassBinding extends HTExternalClass {
  final void Function() onRequestRefresh;

  PluginClassBinding({required this.onRequestRefresh}) : super("Plugin");

  @override
  memberGet(String varName, {String? from}) {
    return switch (varName) {
      "Plugin.requestRefresh" => (
        HTEntity entity, {
        positionalArgs,
        namedArgs,
        typeArgs,
      }) {
        onRequestRefresh();
      },
      _ => HTError.undefined(varName),
    };
  }
}
