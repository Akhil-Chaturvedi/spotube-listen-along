import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter/material.dart' show ListTile;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/modules/settings/section_card_with_heading.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';

/// Friends the current metadata plugin can mirror, from its optional
/// `listenAlong.availableFriends()`. Empty when the plugin doesn't support it.
final _listenAlongFriendsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final plugin = await ref.watch(metadataPluginProvider.future);
  if (plugin == null || !plugin.listenAlong.isSupported) {
    return const [];
  }
  return plugin.listenAlong.availableFriends();
});

/// Generic "Listen Along" settings section.
///
/// This contains NO provider-specific logic: it lists whatever friends the
/// current metadata plugin reports via `listenAlong.availableFriends()` and
/// toggles `listenAlong.start(userId)` / `stop()`. Any plugin implementing that
/// optional member gets this UI for free.
class SettingsListenAlongSection extends ConsumerWidget {
  const SettingsListenAlongSection({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final friends = ref.watch(_listenAlongFriendsProvider);

    // If the plugin doesn't support listen-along, hide the whole section.
    if (friends.asData?.value.isEmpty ?? true) {
      if (friends.isLoading) return const SizedBox.shrink();
      return const SizedBox.shrink();
    }

    return SectionCardWithHeading(
      heading: "Listen Along",
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            "Mirror a friend's current track. When their song changes, yours "
            "follows (polled every 10s).",
          ),
        ),
        for (final friend in friends.asData!.value)
          _FriendTile(
            friend: friend,
            onChanged: (value) async {
              final plugin = await ref.read(metadataPluginProvider.future);
              if (plugin == null) return;
              if (value) {
                await plugin.listenAlong.start(friend["userId"] as String);
              } else {
                await plugin.listenAlong.stop();
              }
            },
          ),
      ],
    );
  }
}

class _FriendTile extends StatelessWidget {
  final Map<String, dynamic> friend;
  final ValueChanged<bool> onChanged;

  const _FriendTile({required this.friend, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final image = friend["image"] as String?;
    return ListTile(
      leading: image != null
          ? ClipOval(
              child: Image.network(
                image,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const SizedBox(width: 40, height: 40),
              ),
            )
          : const SizedBox(width: 40, height: 40),
      title: Text(friend["name"] as String? ?? ""),
      subtitle: Text(friend["description"] as String? ?? ""),
      trailing: Switch(value: false, onChanged: onChanged),
    );
  }
}
