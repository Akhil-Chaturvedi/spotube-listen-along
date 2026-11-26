import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:spotube/services/metadata/endpoints/mirror_telemetry.dart';
import 'package:spotube/services/youtube_engine/youtube_engine.dart';
// import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'dart:async';
import 'dart:io';

/// It contains methods that are computationally expensive
class IsolatedYoutubeExplode {
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;

  IsolatedYoutubeExplode._(
    Isolate isolate,
    ReceivePort receivePort,
    SendPort sendPort,
  )   : _isolate = isolate,
        _receivePort = receivePort,
        _sendPort = sendPort;

  static IsolatedYoutubeExplode? _instance;

  static IsolatedYoutubeExplode get instance => _instance!;

  static bool get isInitialized => _instance != null;

  static Future<void> initialize() async {
    if (_instance != null) {
      return;
    }

    final completer = Completer<SendPort>();

    final receivePort = ReceivePort();

    /// Listen for the main isolate to set the main port
    final subscription = receivePort.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      }
    });

    final isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort);

    _instance = IsolatedYoutubeExplode._(
      isolate,
      receivePort,
      await completer.future,
    );

    if (completer.isCompleted) {
      subscription.cancel();
    }
  }

  static Future<void> _isolateEntry(SendPort mainSendPort) async {
    final receivePort = ReceivePort();
    // final solver = await DenoEJSSolver.init();
    final youtubeExplode = YoutubeExplode();
    final stopWatch = kDebugMode ? Stopwatch() : null;

    /// Send the main port to the main isolate
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) async {
      final SendPort replyPort = message[0];
      final String methodName = message[1];
      final List<dynamic> arguments = message[2];

      if (stopWatch != null) {
        if (stopWatch.isRunning) {
          stopWatch.stop();
          final symbol = stopWatch.elapsedMilliseconds < 1000 ? "⚠️" : "⏱️";
          debugPrint(
            "$symbol YoutubeExplode operation gap ${stopWatch.elapsedMilliseconds} ms",
          );
          stopWatch.reset();
        } else {
          stopWatch.start();
        }
      }

      // Run the requested method on YoutubeExplode
      var result = switch (methodName) {
        "search" => youtubeExplode.search
            .search(
              arguments[0] as String,
              filter: arguments.elementAtOrNull(1) ?? TypeFilters.video,
            )
            .then((s) => s.toList()),
        "video" => youtubeExplode.videos.get(arguments[0] as String),
        "manifest" => youtubeExplode.videos.streamsClient.getManifest(
            arguments[0] as String,
            requireWatchPage: arguments.elementAtOrNull(1) ?? true,
            ytClients: arguments.elementAtOrNull(2) as List<YoutubeApiClient>?,
          ),
        // Per-client resolve with a HEAD check on the exact audio URL we will
        // hand out. The package's own getManifest only validates
        // `streams.first` (often an HLS fragment) before accepting a client,
        // while adaptive audio itags can still 403 at play time (device log
        // 2026-11-25: every track "Failed to open .../stream/<id>"). Returns
        // [StreamManifest(single validated stream), diagString].
        "manifestVerified" => _manifestVerified(
            youtubeExplode,
            arguments[0] as String,
            arguments[1] as List<YoutubeApiClient>,
          ),
        _ => throw ArgumentError('Invalid method name: $methodName'),
      };

      replyPort.send(await result);
    });
  }

  static Future<int> _headStatus(String url, String? userAgent) async {
    final client = HttpClient();
    if (userAgent != null) {
      client.userAgent = userAgent;
    }
    try {
      final req = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      final res = await req.close().timeout(const Duration(seconds: 15));
      final code = res.statusCode;
      await res.drain<void>();
      return code;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  static String? _clientUserAgent(YoutubeApiClient client) {
    final context = client.payload['context'];
    final clientCtx =
        context is Map<String, dynamic> ? context['client'] : null;
    final ua = clientCtx is Map<String, dynamic> ? clientCtx['userAgent'] : null;
    return ua is String ? ua : null;
  }

  static Future<List<dynamic>> _manifestVerified(
    YoutubeExplode youtubeExplode,
    String videoId,
    List<YoutubeApiClient> clients,
  ) async {
    final tried = <String>[];

    for (final client in clients) {
      final name =
          client.payload['context']['client']['clientName'] as String? ??
              'unknown';

      final StreamManifest manifest;
      try {
        manifest = await youtubeExplode.videos.streamsClient.getManifest(
          videoId,
          requireWatchPage: false,
          ytClients: [client],
        );
      } catch (e) {
        tried.add('$name:manifest-fail');
        continue;
      }

      final audio = manifest.audioOnly
          .where((stream) => stream.bitrate.bitsPerSecond >= 40960)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (audio.isEmpty) {
        tried.add('$name:no-audio');
        continue;
      }

      for (final stream in audio.take(6)) {
        final code = await _headStatus(
          stream.url.toString(),
          _clientUserAgent(client),
        );
        if (code == 200) {
          return [
            StreamManifest([stream]),
            'video=$videoId client=$name itag=${stream.tag} '
                '${stream.bitrate.kiloBitsPerSecond.toInt()}kbps HEAD=200',
          ];
        }
        tried.add('$name:itag${stream.tag}:$code');
      }
    }

    throw 'all ${clients.length} clients failed to yield a playable audio URL '
        'for $videoId [${tried.join(", ")}]';
  }

  Future<T> _runMethod<T>(String methodName, List<dynamic> args) {
    final completer = Completer<T>();
    final responsePort = ReceivePort();

    responsePort.listen((message) {
      completer.complete(message as T);
      responsePort.close();
    });

    _sendPort.send([responsePort.sendPort, methodName, args]);
    return completer.future;
  }

  Future<List<Video>> search(
    String query, {
    SearchFilter? filter,
  }) async {
    return _runMethod<List<Video>>("search", [query]);
  }

  Future<Video> video(String videoId) async {
    return _runMethod<Video>("video", [videoId]);
  }

  Future<StreamManifest> manifest(
    String videoId, {
    bool requireWatchPage = false,
    List<YoutubeApiClient>? ytClients,
  }) async {
    return _runMethod<StreamManifest>("manifest", [
      videoId,
      requireWatchPage,
      ytClients,
    ]);
  }

  /// Returns `[StreamManifest, diag]` where the manifest contains exactly the
  /// audio stream whose URL was HEAD-validated as playable (HTTP 200) from
  /// this network. See the "manifestVerified" case in [_isolateEntry].
  Future<List<dynamic>> manifestVerified(
    String videoId,
    List<YoutubeApiClient> ytClients,
  ) async {
    return _runMethod<List<dynamic>>("manifestVerified", [
      videoId,
      ytClients,
    ]);
  }

  void dispose() {
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

class YouTubeExplodeEngine implements YouTubeEngine {
  static final _youtubeExplode = IsolatedYoutubeExplode.instance;

  /// Client preference order. First one whose audio URL actually returns 200
  /// in [_manifestVerified] wins, so the chain self-heals whenever YouTube
  /// tightens PO-token enforcement for one of them (that's exactly what
  /// happened to ios/android/androidVr on ~2026-11-21 - their adaptive audio
  /// URLs 403 while the player request still succeeds).
  ///
  /// `androidSdkless` = ANDROID client without the `androidSdkVersion` field
  /// (yt-dlp's "android_sdkless"); doesn't require a PO token. Copied verbatim
  /// from youtube_explode_dart (also present in the 3.1.0 release).
  static const androidSdkless = YoutubeApiClient({
    'context': {
      'client': {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'userAgent':
            'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
        'hl': 'en',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
        'osName': 'Android',
        'osVersion': '11',
      },
    },
  }, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  static bool get isAvailableForPlatform => true;

  static Future<bool> isInstalled() async {
    return true;
  }

  @override
  Future<StreamManifest> getStreamManifest(String videoId) async {
    await IsolatedYoutubeExplode.initialize();

    final List<dynamic> verified;
    try {
      verified = await _youtubeExplode.manifestVerified(videoId, [
        androidSdkless,
        YoutubeApiClient.androidVr,
        YoutubeApiClient.ios,
        YoutubeApiClient.android,
      ]);
    } catch (e) {
      unawaited(MirrorTelemetry.logError(
        'YT',
        'no playable audio URL for $videoId: $e',
      ));
      rethrow;
    }

    final streamManifest = verified[0] as StreamManifest;
    unawaited(MirrorTelemetry.logAlways('YT', verified[1] as String));

    final audioStreams = streamManifest.audioOnly.where(
      (stream) => stream.bitrate.bitsPerSecond >= 40960,
    );

    return StreamManifest(
      audioStreams.map(
        (stream) => AudioOnlyStreamInfo(
          stream.videoId,
          stream.tag,
          stream.url,
          stream.container,
          stream.size,
          stream.bitrate,
          stream.audioCodec,
          switch (stream.bitrate.bitsPerSecond) {
            > 130 * 1024 => "high",
            > 64 * 1024 => "medium",
            _ => "low",
          },
          stream.fragments,
          stream.codec,
          stream.audioTrack,
        ),
      ),
    );
  }

  @override
  Future<Video> getVideo(String videoId) async {
    await IsolatedYoutubeExplode.initialize();
    return _youtubeExplode.video(videoId);
  }

  @override
  Future<(Video, StreamManifest)> getVideoWithStreamInfo(String videoId) async {
    await IsolatedYoutubeExplode.initialize();

    final video = await getVideo(videoId);
    final streamManifest = await getStreamManifest(videoId);

    return (video, streamManifest);
  }

  @override
  Future<List<Video>> searchVideos(String query) async {
    await IsolatedYoutubeExplode.initialize();

    return _youtubeExplode
        .search(
          query,
          filter: TypeFilters.video,
        )
        .then((searchList) => searchList.toList());
  }

  @override
  void dispose() {
    IsolatedYoutubeExplode.instance.dispose();
  }
}
