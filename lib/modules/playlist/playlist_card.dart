import 'package:auto_route/auto_route.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter_extension.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/components/dialogs/select_device_dialog.dart';
import 'package:spotube/components/playbutton_view/playbutton_card.dart';
import 'package:spotube/components/playbutton_view/playbutton_tile.dart';
import 'package:spotube/extensions/context.dart';
import 'package:spotube/models/connect/connect.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/audio_player/querying_track_info.dart';
import 'package:spotube/provider/connect/connect.dart';
import 'package:spotube/provider/history/history.dart';
import 'package:spotube/provider/audio_player/audio_player.dart';
import 'package:spotube/provider/listen_along/listen_along.dart';
import 'package:spotube/provider/metadata_plugin/metadata_plugin_provider.dart';
import 'package:spotube/provider/metadata_plugin/library/tracks.dart';
import 'package:spotube/provider/metadata_plugin/tracks/playlist.dart';
import 'package:spotube/provider/metadata_plugin/core/user.dart';
import 'package:spotube/services/audio_player/audio_player.dart';

class PlaylistCard extends HookConsumerWidget {
  final SpotubeSimplePlaylistObject playlist;
  final bool _isTile;

  const PlaylistCard(
    this.playlist, {
    super.key,
  }) : _isTile = false;

  const PlaylistCard.tile(
    this.playlist, {
    super.key,
  }) : _isTile = true;

  @override
  Widget build(BuildContext context, ref) {
    final playlistQueue = ref.watch(audioPlayerProvider);
    final playlistNotifier = ref.watch(audioPlayerProvider.notifier);
    final isFetchingActiveTrack = ref.watch(queryingTrackInfoProvider);
    final historyNotifier = ref.read(playbackHistoryActionsProvider);

    final playing =
        useStream(audioPlayer.playingStream).data ?? audioPlayer.isPlaying;

    final isPlaylistPlaying = useMemoized<bool>(
      () => playlistQueue.containsCollection(playlist.id),
      [playlistQueue, playlist.id],
    );

    final updating = useState(false);
    final me = ref.watch(metadataPluginUserProvider);

    final fetchInitialTracks = useCallback(() async {
      if (playlist.id == 'user-liked-tracks') {
        final tracks = await ref.read(metadataPluginSavedTracksProvider.future);
        return tracks.items;
      }

      final result = await ref
          .read(metadataPluginPlaylistTracksProvider(playlist.id).future);

      return result.items;
    }, [playlist.id, ref]);

    final fetchAllTracks = useCallback(() async {
      await fetchInitialTracks();

      if (playlist.id == 'user-liked-tracks') {
        return ref.read(metadataPluginSavedTracksProvider.notifier).fetchAll();
      }

      return ref
          .read(metadataPluginPlaylistTracksProvider(playlist.id).notifier)
          .fetchAll();
    }, [playlist.id, ref, fetchInitialTracks]);

    final onTap = useCallback(() {
      context.navigateTo(PlaylistRoute(id: playlist.id, playlist: playlist));
    }, [context, playlist]);

    final onPlaybuttonPressed = useCallback(() async {
      try {
        updating.value = true;
        if (isPlaylistPlaying && playing) {
          return audioPlayer.pause();
        } else if (isPlaylistPlaying && !playing) {
          return audioPlayer.resume();
        }

        final fetchedInitialTracks = await fetchInitialTracks();

        if (fetchedInitialTracks.isEmpty || !context.mounted) return;

        final isRemoteDevice = await showSelectDeviceDialog(context, ref);
        if (isRemoteDevice == null) return;
        if (isRemoteDevice) {
          final remotePlayback = ref.read(connectProvider.notifier);
          final allTracks = await fetchAllTracks();
          await remotePlayback.load(
            WebSocketLoadEventData.playlist(
              tracks: allTracks,
              collection: playlist,
            ),
          );
        } else {
          await playlistNotifier.load(fetchedInitialTracks, autoPlay: true);
          playlistNotifier.addCollection(playlist.id);
          historyNotifier.addPlaylists([playlist]);

          final allTracks = await fetchAllTracks();

          await playlistNotifier
              .addTracks(allTracks.sublist(fetchedInitialTracks.length));
        }
      } finally {
        if (context.mounted) {
          updating.value = false;
        }
      }
    }, [
      isPlaylistPlaying,
      playing,
      fetchInitialTracks,
      context,
      showSelectDeviceDialog,
      ref,
      connectProvider,
      fetchAllTracks,
      playlistNotifier,
      playlist.id,
      historyNotifier,
      playlist,
      updating
    ]);

    final onAddToQueuePressed = useCallback(() async {
      updating.value = true;
      try {
        if (isPlaylistPlaying) return;

        final fetchedInitialTracks = await fetchAllTracks();

        if (fetchedInitialTracks.isEmpty) return;

        playlistNotifier.addTracks(fetchedInitialTracks);
        playlistNotifier.addCollection(playlist.id);
        historyNotifier.addPlaylists([playlist]);
        if (context.mounted) {
          showToast(
            context: context,
            builder: (context, overlay) {
              return SurfaceCard(
                child: Basic(
                  content: Text(
                    context.l10n
                        .added_num_tracks_to_queue(fetchedInitialTracks.length),
                  ),
                  trailing: Button.outline(
                    child: Text(context.l10n.undo),
                    onPressed: () {
                      playlistNotifier
                          .removeTracks(fetchedInitialTracks.map((e) => e.id));
                    },
                  ),
                ),
              );
            },
          );
        }
      } finally {
        updating.value = false;
      }
    }, [
      isPlaylistPlaying,
      fetchAllTracks,
      playlistNotifier,
      playlist.id,
      historyNotifier,
      playlist,
      context,
      updating
    ]);

    final imageUrl = useMemoized(
      () => playlist.images.from200PxTo300PxOrSmallestImage(
        ImagePlaceholder.collection,
      ),
      [playlist.images],
    );

    final isLoading =
        (isPlaylistPlaying && isFetchingActiveTrack) || updating.value;
    final isOwner = playlist.owner.id == me.asData?.value?.id &&
        me.asData?.value?.id != null;

    // "Live" cards are marked by the metadata plugin (`isLive: true`) and
    // represent an entity that is playing elsewhere (e.g. a friend's session).
    // When the plugin also exposes Listen Along, the play button toggles
    // mirroring of that entity instead of a one-shot play. The card itself can
    // still be tapped to open the entity's page and play its tracks normally.
    final listenAlongId = ref.watch(listenAlongControllerProvider);
    final listenAlongSupported =
        ref.watch(metadataPluginProvider).asData?.value?.listenAlong
                .isSupported ??
            false;
    final isLiveCard = playlist.isLive && listenAlongSupported;
    final isMirroring = isLiveCard && listenAlongId == playlist.id;

    final onMirrorPressed = useCallback(() {
      ref
          .read(listenAlongControllerProvider.notifier)
          .toggle(playlist.id);
    }, [playlist.id, ref]);

    final effectiveOnPlaybuttonPressed =
        isLiveCard ? onMirrorPressed : onPlaybuttonPressed;

    // Compact label for the title row's end: "Now" while the entity is active
    // (matching Spotify's 15-minute window), otherwise a short relative time.
    // "Now" inherits the title style (it sits in the title row); the relative
    // time is styled like the subtitle/description line.
    Widget? trailing;
    if (playlist.lastActiveAt != null) {
      final elapsed =
          DateTime.now().millisecondsSinceEpoch - playlist.lastActiveAt!;
      trailing = elapsed >= 0 && elapsed <= 15 * 60 * 1000
          ? const Text('Now')
          : Text(
              _shortRelativeTime(elapsed),
              style: context.theme.typography.small.copyWith(
                color: context.theme.colorScheme.mutedForeground,
              ),
            );
    }

    if (_isTile) {
      return PlaybuttonTile(
        title: playlist.name,
        description: playlist.description,
        image: null,
        imageUrl: imageUrl,
        isPlaying: isPlaylistPlaying,
        isLoading: isLoading,
        isOwner: isOwner,
        onTap: onTap,
        onPlaybuttonPressed: effectiveOnPlaybuttonPressed,
        onAddToQueuePressed: onAddToQueuePressed,
      );
    }

    return PlaybuttonCard(
      title: playlist.name,
      description: playlist.description,
      image: null,
      imageUrl: imageUrl,
      isPlaying: isPlaylistPlaying || isMirroring,
      isLoading: isLoading,
      isOwner: isOwner,
      trailing: trailing,
      onTap: onTap,
      onPlaybuttonPressed: effectiveOnPlaybuttonPressed,
      onAddToQueuePressed: onAddToQueuePressed,
    );
  }
}

/// Compact relative time in Spotify's buddy-feed style: "23m", "2h", "3d",
/// "1w". Inputs over a week keep counting weeks.
String _shortRelativeTime(int elapsedMs) {
  final minutes = elapsedMs ~/ 60000;
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h';
  final days = hours ~/ 24;
  if (days < 7) return '${days}d';
  final weeks = days ~/ 7;
  return '${weeks}w';
}
