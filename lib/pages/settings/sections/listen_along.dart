import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter/material.dart' show ListTile;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/modules/settings/section_card_with_heading.dart';
import 'package:spotube/provider/listen_along/listen_along.dart';
import 'package:spotube/provider/metadata_plugin/browse/sections.dart';

/// Settings section that lists the friends currently sharing their listening
/// (from the metadata plugin's "Friend Activity" browse section) and lets the
/// user mirror one of them.
///
/// When "Listen along" is switched on for a friend, the host polls that friend's
/// current track every 10s and, whenever it changes, replaces the queue with the
/// new track and starts playing it. See [ListenAlongNotifier].
class SettingsListenAlongSection extends HookConsumerWidget {
  const SettingsListenAlongSection({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final listenAlong = ref.watch(listenAlongProvider);
    final listenAlongNotifier = ref.watch(listenAlongProvider.notifier);
    final sections = ref.watch(metadataPluginBrowseSectionsProvider);

    // Find the plugin's "Friend Activity" section and pull out its items. Each
    // item is a synthetic playlist whose id is `friend-<userId>`.
    final friends = sections.asData?.value.items
            .whereType<SpotubeBrowseSectionObject<Object>>()
            .firstWhere(
              (section) => section.id == 'friend-activity',
              orElse: () => SpotubeBrowseSectionObject<Object>(
                id: '',
                title: '',
                externalUri: '',
                browseMore: false,
                items: <Object>[],
              ),
            )
            .items
            .whereType<SpotubeSimplePlaylistObject>()
            .toList() ??
        const <SpotubeSimplePlaylistObject>[];

    return SectionCardWithHeading(
      heading: "Listen Along",
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            friends.isEmpty
                ? "No friends are sharing their listening right now. "
                    "Open Browse -> Friend Activity, then come back."
                : "Mirror a friend's current track. When their song changes, "
                    "yours will follow (polled every 10s).",
          ),
        ),
        for (final friend in friends)
          _FriendListenAlongTile(
            friend: friend,
            isActive: listenAlong.friendId == _userId(friend.id),
            onChanged: (value) {
              if (value) {
                listenAlongNotifier.start(_userId(friend.id), friend.name);
              } else {
                listenAlongNotifier.stop();
              }
            },
          ),
      ],
    );
  }

  static String _userId(String playlistId) =>
      playlistId.replaceFirst('friend-', '');
}

class _FriendListenAlongTile extends StatelessWidget {
  final SpotubeSimplePlaylistObject friend;
  final bool isActive;
  final ValueChanged<bool> onChanged;

  const _FriendListenAlongTile({
    required this.friend,
    required this.isActive,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: friend.images.isNotEmpty
          ? ClipOval(
              child: Image.network(
                friend.images.first.url,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const SizedBox(width: 40, height: 40),
              ),
            )
          : const SizedBox(width: 40, height: 40),
      title: Text(friend.name),
      subtitle: Text(friend.description),
      trailing: Switch(
        value: isActive,
        onChanged: onChanged,
      ),
    );
  }
}
