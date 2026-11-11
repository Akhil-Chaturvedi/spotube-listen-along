import 'dart:async';
import 'dart:typed_data';
import 'package:media_kit/media_kit.dart' hide Track;
import 'package:spotube/services/audio_player/audio_player.dart';

import 'package:auto_route/auto_route.dart';
import 'package:hetu_otp_util/hetu_otp_util.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart' as spotube_plugin;
import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart'
    hide YouTubeEngine;
import 'package:hetu_std/hetu_std.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/collections/routes.dart';
import 'package:spotube/collections/routes.gr.dart';
import 'package:spotube/components/titlebar/titlebar.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/metadata/apis/localstorage.dart';
import 'package:spotube/services/metadata/endpoints/album.dart';
import 'package:spotube/services/metadata/endpoints/artist.dart';
import 'package:spotube/services/metadata/endpoints/audio_source.dart';
import 'package:spotube/services/metadata/endpoints/auth.dart';
import 'package:spotube/services/metadata/endpoints/browse.dart';
import 'package:spotube/services/metadata/endpoints/playlist.dart';
import 'package:spotube/services/metadata/endpoints/search.dart';
import 'package:spotube/services/metadata/endpoints/track.dart';
import 'package:spotube/services/metadata/endpoints/core.dart';
import 'package:spotube/services/metadata/endpoints/listen_along.dart';
import 'package:spotube/services/metadata/endpoints/mirror_telemetry.dart';
import 'package:spotube/services/metadata/endpoints/user.dart';
import 'package:spotube/services/spotify_session/presence_publisher.dart';
import 'package:spotube/services/spotify_session/spotify_session.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';

const defaultMetadataLimit = "20";

class MetadataPlugin {
  static final pluginApiVersion = Version.parse("2.0.0");

  static Future<MetadataPlugin> create(
    YouTubeEngine youtubeEngine,
    PluginConfiguration config,
    Uint8List byteCode, {
    spotube_plugin.Player Function()? createPlayer,
    void Function()? onRequestRefresh,
  }) async {
    final sharedPreferences = await SharedPreferences.getInstance();
    BuildContext? pageContext;

    final hetu = Hetu();
    hetu.init();

    HetuStdLoader.loadBindings(hetu);
    HetuSpotubePluginLoader.loadBindings(
      hetu,
      localStorageImpl: SharedPreferencesLocalStorage(
        sharedPreferences,
        config.slug,
      ),
      onNavigatorPush: (route) {
        return rootNavigatorKey.currentContext?.router
            .pushWidget(Builder(builder: (context) {
          pageContext = context;
          return Scaffold(
            headers: const [
              TitleBar(
                automaticallyImplyLeading: true,
              )
            ],
            child: route,
          );
        }));
      },
      onNavigatorPop: () {
        // `pageContext` is the BuildContext of the pushed widget. It becomes
        // null (or detached) once the route is popped, so guard on both the
        // context and its mounted state before popping to avoid
        // "Null check operator used on a null value" from
        // AutoRouterX.maybePop -> AutoRouter.of(...).
        final context = pageContext;
        if (context != null && context.mounted) {
          context.maybePop();
        }
      },
      onShowForm: (title, fields) async {
        if (rootNavigatorKey.currentContext == null) {
          return [];
        }

        return await rootNavigatorKey.currentContext!.router
            .push<List<Map<String, dynamic>>?>(
          SettingsMetadataProviderFormRoute(
            title: title,
            fields:
                fields.map((e) => MetadataFormFieldObject.fromJson(e)).toList(),
          ),
        );
      },
      createYoutubeEngine: () {
        return spotube_plugin.YouTubeEngine(
          search: (query) async {
            final result = await youtubeEngine.searchVideos(query);
            return result
                .map((video) => {
                      'id': video.id.value,
                      'title': video.title,
                      'author': video.author,
                      'duration': video.duration?.inSeconds,
                      'description': video.description,
                      'uploadDate': video.uploadDate?.toIso8601String(),
                      'viewCount': video.engagement.viewCount,
                      'likeCount': video.engagement.likeCount,
                      'isLive': video.isLive,
                    })
                .toList();
          },
          getVideo: (videoId) async {
            final video = await youtubeEngine.getVideo(videoId);
            return {
              'id': video.id.value,
              'title': video.title,
              'author': video.author,
              'duration': video.duration?.inSeconds,
              'description': video.description,
              'uploadDate': video.uploadDate?.toIso8601String(),
              'viewCount': video.engagement.viewCount,
              'likeCount': video.engagement.likeCount,
              'isLive': video.isLive,
            };
          },
          streamManifest: (videoId) {
            return youtubeEngine.getStreamManifest(videoId).then(
              (manifest) {
                final streams = manifest.audioOnly
                    .map(
                      (stream) => {
                        'url': stream.url.toString(),
                        'quality': stream.qualityLabel,
                        'bitrate': stream.bitrate.bitsPerSecond,
                        'container': stream.container.name,
                        'videoId': stream.videoId,
                      },
                    )
                    .toList();
                return streams;
              },
            );
          },
        );
      },
      createPlayer: createPlayer,
      onRequestRefresh: onRequestRefresh,
    );

    await HetuStdLoader.loadBytecodeFlutter(hetu);
    await HetuOtpUtilLoader.loadBytecodeFlutter(hetu);
    await HetuSpotubePluginLoader.loadBytecodeFlutter(hetu);

    hetu.loadBytecode(bytes: byteCode, moduleName: "plugin");
    hetu.eval("""
      import "module:plugin" as plugin

      var Plugin = plugin.${config.entryPoint}

      var metadataPlugin = Plugin()
      """);

    // Native Spotify session upkeep (login5 StoredCredential -> access token
    // for the Friend Activity data path). Bridges the plugin's LocalStorage
    // (la_blob/la_username -> la_token/la_token_exp) with a native protobuf
    // exchange the Hetu sandbox cannot perform itself. Feed content changes
    // push the same generic refresh `Plugin.requestRefresh()` uses.
    final spotifySession = SpotifySessionService(
      sharedPreferences,
      config.slug,
      onFeedChanged: onRequestRefresh,
    )..start();

    return MetadataPlugin._(
      hetu,
      spotifySession,
      sharedPreferences: sharedPreferences,
      pluginSlug: config.slug,
      createPlayer: createPlayer,
      onRequestRefresh: onRequestRefresh,
    );
  }

  final Hetu hetu;
  final SpotifySessionService spotifySession;

  /// Opt-in "share my Spotube playback on Spotify" companion of the session
  /// service (dealer WS + connect-state PUTs; see its class doc for the
  /// live-verified protocol). Cheap no-op unless the plugin's
  /// `la_publish_enabled` LocalStorage key is set.
  late final SpotifyPresencePublisher presencePublisher;

  late final MetadataAuthEndpoint auth;

  late final MetadataPluginAudioSourceEndpoint audioSource;
  late final MetadataPluginAlbumEndpoint album;
  late final MetadataPluginArtistEndpoint artist;
  late final MetadataPluginBrowseEndpoint browse;
  late final MetadataPluginSearchEndpoint search;
  late final MetadataPluginPlaylistEndpoint playlist;
  late final MetadataPluginTrackEndpoint track;
  late final MetadataPluginUserEndpoint user;
  late final MetadataPluginCore core;
  late final MetadataPluginListenAlongEndpoint listenAlong;

  MetadataPlugin._(
    this.hetu,
    this.spotifySession, {
    required SharedPreferences sharedPreferences,
    required String pluginSlug,
    spotube_plugin.Player Function()? createPlayer,
    void Function()? onRequestRefresh,
  }) : _playerFactory = createPlayer {
    auth = MetadataAuthEndpoint(hetu);

    audioSource = MetadataPluginAudioSourceEndpoint(hetu);
    artist = MetadataPluginArtistEndpoint(hetu);
    album = MetadataPluginAlbumEndpoint(hetu);
    browse = MetadataPluginBrowseEndpoint(hetu);
    search = MetadataPluginSearchEndpoint(hetu);
    playlist = MetadataPluginPlaylistEndpoint(hetu);
    track = MetadataPluginTrackEndpoint(hetu);
    user = MetadataPluginUserEndpoint(hetu);
    core = MetadataPluginCore(hetu);
    // The mirror POLICY lives host-side (hetu cannot dispatch external
    // instance methods from async callbacks): the plugin only supplies data.
    listenAlong = MetadataPluginListenAlongEndpoint(
      hetu,
      createPlayer: createPlayer,
    );
    // Generic plugin maintenance clock (plugins may use tick() for periodic
    // upkeep like refreshing their own auth token). Must start at plugin load
    // - NOT when some UI first renders - so upkeep never depends on a widget
    // happening to be on screen.
    listenAlong.startKeepAlive();
    // Demand model: keep the Spotify session polling while a Listen-Along
    // mirror is running, even when no friend surface is visible.
    spotifySession.mirroringActive = () => listenAlong.isMirroring;
    // The mirror can demand fresh data immediately (our song is ending and
    // the friend may have skipped ahead).
    listenAlong.onDemandDataRefresh =
        () => unawaited(spotifySession.refreshNow());
    // Feed content changed -> refresh plugin sections AND run the mirror
    // policy immediately (don't wait out the next poll tick). Log analysis
    // showed friend-change -> our-speaker latency was tick-bound; this
    // shaves up to pollInterval off it.
    spotifySession.onFeedChanged = () {
      onRequestRefresh?.call();
      listenAlong.pokeForFeedChange();
    };
    // Broadcast direction (opt-in via Settings -> Playback): declare a
    // virtual Connect device so friends' Friend Activity shows what Spotube
    // plays. Owns its dealer WS + PUTs; idle unless la_publish_enabled.
    presencePublisher = SpotifyPresencePublisher(
      prefs: sharedPreferences,
      pluginSlug: pluginSlug,
      tokenProvider: () async => spotifySession.currentToken,
      createPlayer: createPlayer,
      onCommand: _handleConnectCommand,
    )..start();
  }

  final spotube_plugin.Player? Function()? _playerFactory;
  spotube_plugin.Player? _connectPlayer;

  spotube_plugin.Player get _connectPlayerInstance {
    final factory = _playerFactory;
    if (factory == null) {
      throw StateError('no player factory - Connect commands unavailable');
    }
    return _connectPlayer ??= factory();
  }

  /// Commands remote Spotify clients send to our virtual device (dealer
  /// `request` frames). Returns true when applied - that drives the dealer
  /// reply's success flag, which is what makes the official client's button
  /// stop spinning.
  Future<bool> _handleConnectCommand(
    String endpoint,
    Map<String, dynamic> command,
  ) async {
    final value = command['value'];
    final valueInt = (value is num) ? value.toInt() : int.tryParse('$value');
    final valueDouble =
        (value is num) ? value.toDouble() : double.tryParse('$value');
    final valueBool =
        value == true || value == 'true' || value == 1 || value == '1';
    final contextUri = (command['context_uri'] ?? value ?? '').toString();
    unawaited(
      MirrorTelemetry.log(
        'Publish',
        'handling endpoint=$endpoint value=$value context=$contextUri',
      ),
    );
    try {
      switch (endpoint) {
        case 'pause':
          await _connectPlayerInstance.pause();
          return true;
        case 'resume':
          await _connectPlayerInstance.play();
          return true;
        case 'seek_to':
          if (valueInt == null || valueInt < 0) return false;
          await _connectPlayerInstance.seek(valueInt);
          return true;
        case 'skip_next':
          await _connectPlayerInstance.next();
          return true;
        case 'skip_prev':
          await _connectPlayerInstance.previous();
          return true;
        case 'set_volume':
          final sv = _connectPlayerInstance.setVolume;
          if (sv == null || valueDouble == null) return false;
          await sv((valueDouble / 65536).clamp(0.0, 1.0));
          return true;
        case 'play':
        case 'transfer':
          final tracks = await _resolveConnectContext(contextUri);
          if (tracks.isEmpty) {
            unawaited(
              MirrorTelemetry.log(
                'Publish',
                'play/transfer: context "$contextUri" resolved to no tracks',
              ),
            );
            return false;
          }
          presencePublisher.setActiveContext(contextUri);
          await _connectPlayerInstance.loadTracks(
            tracks,
            autoPlay: true,
            initialIndex: 0,
          );
          return true;
        case 'add_to_queue':
          final tracks = await _resolveConnectContext(contextUri);
          if (tracks.isEmpty) return false;
          await _connectPlayerInstance.addToQueue(tracks.first);
          return true;
        case 'set_shuffling_context':
          await audioPlayer.setShuffle(valueBool);
          return true;
        case 'set_repeating_context':
          await audioPlayer.setLoopMode(
            valueBool ? PlaylistMode.loop : PlaylistMode.none,
          );
          return true;
        case 'set_repeating_track':
          await audioPlayer.setLoopMode(
            valueBool ? PlaylistMode.single : PlaylistMode.none,
          );
          return true;
        default:
          // Shuffle/repeat/queue-style commands: accepted so controlling
          // clients don't show errors, but Spotube's player has no
          // primitives for them yet.
          unawaited(
            MirrorTelemetry.log(
              'Publish',
              'endpoint=$endpoint acked without effect (no host primitive)',
            ),
          );
          return true;
      }
    } catch (e) {
      unawaited(
        MirrorTelemetry.log('Publish', 'command endpoint=$endpoint failed: $e'),
      );
      return false;
    }
  }

  /// Resolves a Spotify context URI (track/playlist/album) to player track
  /// maps through the active metadata plugin. Generic: whatever plugin is
  /// active supplies the data.
  Future<List<Map<String, dynamic>>> _resolveConnectContext(String uri) async {
    try {
      if (uri.startsWith('spotify:track:')) {
        final t = await track.getTrack(uri.split(':').last);
        return [t.toJson()];
      }
      if (uri.startsWith('spotify:playlist:')) {
        final page = await playlist.tracks(
          uri.split(':').last,
          offset: 0,
          limit: 50,
        );
        return page.items.map((t) => t.toJson()).toList();
      }
      if (uri.startsWith('spotify:album:')) {
        final page = await album.tracks(
          uri.split(':').last,
          offset: 0,
          limit: 50,
        );
        return page.items.map((t) => t.toJson()).toList();
      }
      unawaited(
        MirrorTelemetry.log('Publish', 'context "$uri" type not supported'),
      );
    } catch (e) {
      unawaited(
        MirrorTelemetry.log('Publish', 'context resolve "$uri" failed: $e'),
      );
    }
    return [];
  }
}
