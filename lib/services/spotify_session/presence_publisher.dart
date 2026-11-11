import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hetu_spotube_plugin/hetu_spotube_plugin.dart' as spotube_plugin;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotube/services/metadata/endpoints/mirror_telemetry.dart';

/// Publishes Spotube's playback into Spotify's Friend Activity feed.
///
/// VERIFIED LIVE (2026-11-11, misc/tests/presence_publish_test.dart):
/// a `PUT connect-state/v1/devices/{id}` declaring an ACTIVE device with a
/// PLAYING PlayerState makes Spotify's backend publish your presence to
/// followers - `listening-activity/v1/users-activity` flips to
/// `isPlaying:true` within ~20s and friends' buddy feeds show the track -
/// with ZERO audio streaming. A paused PUT flips it back to `isPlaying:false`
/// (the entry then ages out like a normal "last played").
///
/// Requirements discovered by the same experiment:
/// - the PUT is REJECTED (400) without a live dealer websocket
///   connection-id, so this service owns a dealer WS (+25s heartbeat,
///   reconnect with backoff) while active;
/// - `PutStateReason.BECAME_INACTIVE` PUTs 422 - teardown is a paused PUT
///   and letting the device age out.
///
/// Opt-in: the plugin's Friend Activity section writes
/// `la_publish_enabled` ("1"/"0") to its LocalStorage; this service polls
/// that key (namespaced by plugin slug, same convention as la_blob).
///
/// Track mapping: only tracks whose `id` is a 22-char base62 Spotify track
/// id are publishable (i.e. the active metadata provider is Spotify). Other
/// providers' tracks are skipped (logged once per track) and the published
/// state is paused, so followers never see a stale "playing" entry.
///
/// TEMP: telemetry lines go through [MirrorTelemetry] (tag "Publish") and
/// are removed together with the mirror diagnostics.
class SpotifyPresencePublisher {
  SpotifyPresencePublisher({
    required this.prefs,
    required this.pluginSlug,
    required this.tokenProvider,
    this.createPlayer,
    // Generic Connect-command seam: receives every remote command other
    // Spotify clients send to our virtual device ("play", "pause",
    // "seek_to", "skip_next", ... with the raw command JSON) and returns
    // whether it was handled (drives the dealer reply's success flag and
    // the command-ack fields of the next connect-state PUT).
    this.onCommand,
    // Official clients are event-driven (they ARE the player); 1s polling is
    // the closest cheap approximation. Network only fires on real changes.
    this.pollInterval = const Duration(seconds: 1),
    // Official/librespot clients send NO periodic keepalive PUT (state goes
    // out on transitions only; the server extrapolates position and the
    // dealer WS keeps the cluster entry alive). Our single deliberate
    // deviation: one reconciliation PUT per minute while playing, so a PUT
    // lost on a flaky mobile network self-heals within 60s instead of
    // persisting until the next track transition.
    this.keepaliveInterval = const Duration(seconds: 60),
  });

  final SharedPreferences prefs;
  final String pluginSlug;
  final Future<String?> Function() tokenProvider;
  final spotube_plugin.Player? Function()? createPlayer;
  final Duration pollInterval;
  final Duration keepaliveInterval;
  final Future<bool> Function(String endpoint, Map<String, dynamic> command)?
      onCommand;

  Timer? _timer;
  Timer? _heartbeat;
  bool _tickBusy = false;
  spotube_plugin.Player? _player;

  // Dealer keepalive state. Values mirror librespot-java 1.6.5 exactly
  // (decompiled: DealerClient$ConnectionHolder): ping IMMEDIATELY on open,
  // then every 30s; every ping must be answered by {"type":"pong"} within
  // 3s or the connection is torn down and reconnected; reconnect attempts
  // are spaced 10s apart.
  static const _pingInterval = Duration(seconds: 30);
  static const _pongWatchdog = Duration(seconds: 3);
  DateTime _lastPongAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _pingGeneration = 0;
  WebSocket? _ws;
  String _connectionId = '';
  DateTime _lastConnectAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  String _deviceId = '';

  int _seq = 0;
  String? _activeTrackId;
  bool _isPlaying = false;
  int _durationMs = 0;
  bool _everPublished = false;
  DateTime _lastPutAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastUnmappedId;
  bool _loggedNoToken = false;
  bool _pendingCommandAck = false;
  String? _lastCommandSender;
  int? _lastCommandMessageId;

  static const _clientId = '65b708073fc0480ea92a077233ca87bd';
  static const _deviceName = 'Spotube';

  String _key(String key) => 'spotube_plugin.$pluginSlug.$key';

  bool get _enabled =>
      prefs.getBool(_key('la_publish_enabled')) ??
      (prefs.getString(_key('la_publish_enabled')) == '1');

  /// Starts the low-frequency supervision loop. Cheap when disabled or
  /// idle: one prefs read + (when enabled) one local player getState per
  /// tick; network only while actually publishing.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => unawaited(_tick()));
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _ws?.close();
    _ws = null;
    _connectionId = '';
  }

  Future<void> _tick() async {
    // Reentrancy guard: with a 1s poll, a tick that is still awaiting its
    // own PUT response must not let the next tick interleave (device logs
    // showed two concurrent first PUTs 120ms apart, both claiming
    // SPIRC_HELLO). Drop the tick instead of queueing; the next tick sees
    // the settled state.
    if (_tickBusy) return;
    _tickBusy = true;
    try {
      await _tickInner();
    } catch (e) {
      _log('tick error: $e');
    } finally {
      _tickBusy = false;
    }
  }

  Future<void> _tickInner() async {
    if (!_enabled) {
      _loggedNoToken = false;
      await _stopPublishing();
      return;
    }
    if (_player == null) {
      final factory = createPlayer;
      if (factory == null) return;
      _player = factory();
    }
    final token = await tokenProvider();
    if (token == null) {
      if (!_loggedNoToken) {
        _loggedNoToken = true;
        _log('no login5 token yet - publish idle (blob missing/rejected?)');
      }
      await _pausePublishing();
      return;
    }
    _loggedNoToken = false;
    await _ensureDealer(token);
    if (_connectionId.isEmpty) return; // dealer not ready; next tick retries

    final state = await _player!.getState();
    final track = state['activeTrack'] as Map<String, dynamic>?;
    final id = track?['id'] as String?;
    final spotifyId =
        (id != null && RegExp(r'^[0-9A-Za-z]{22}$').hasMatch(id)) ? id : null;
    if (spotifyId == null) {
      if (id != _lastUnmappedId) {
        _lastUnmappedId = id;
        _log('track unmappable to Spotify (id=$id) - not publishing');
      }
      await _pausePublishing();
      return;
    }
    final isPlaying = state['isPlaying'] == true;
    var durationMs = (track?['durationMs'] as num?)?.toInt() ?? 0;
    if (durationMs <= 0 && track?['duration'] != null) {
      durationMs = ((track!['duration'] as num) * 1000).round();
    }
    final trackChanged = spotifyId != _activeTrackId;
    final playChanged = isPlaying != _isPlaying;
    final commandAck = _pendingCommandAck;
    if (!isPlaying && !trackChanged && !playChanged && !commandAck) {
      // Paused and already published as paused: nothing to do (no keepalive
      // spam while idle; the feed entry simply ages out like real clients).
      return;
    }
    if (!isPlaying && !_everPublished && !commandAck) {
      return; // idle start, nothing live yet
    }
    final keepaliveDue =
        DateTime.now().difference(_lastPutAt) >= keepaliveInterval;
    if (isPlaying &&
        !trackChanged &&
        !playChanged &&
        !commandAck &&
        !keepaliveDue) {
      return;
    }

    final posMs = (state['positionMs'] as num?)?.toInt() ?? 0;
    await _putState(
      token,
      trackUri: 'spotify:track:$spotifyId',
      positionMs: posMs.clamp(0, 1000 * 60 * 60),
      durationMs: durationMs,
      isPlaying: isPlaying,
      reason: _everPublished ? 4 : 1, // PLAYER_STATE_CHANGED : SPIRC_HELLO
    );
    _activeTrackId = spotifyId;
    _isPlaying = isPlaying;
    _durationMs = durationMs;
    _everPublished = true;
    _lastPutAt = DateTime.now();
    _pendingCommandAck = false;
  }

  /// Publishes one paused state (so followers stop seeing "playing") and
  /// forgets the active track. Keeps the dealer WS - the toggle may still be
  /// on and the next track may be publishable again.
  Future<void> _pausePublishing() async {
    _lastUnmappedId = null;
    if (!_everPublished) return;
    final token = await tokenProvider();
    final lastTrack = _activeTrackId;
    if (token != null && _connectionId.isNotEmpty && lastTrack != null) {
      await _putState(
        token,
        trackUri: 'spotify:track:$lastTrack',
        positionMs: 0,
        durationMs: _durationMs,
        isPlaying: false,
        reason: 4, // PLAYER_STATE_CHANGED
      );
      _lastPutAt = DateTime.now();
    }
    _activeTrackId = null;
    _everPublished = false;
    _isPlaying = false;
  }

  /// Toggle off: pause + tear the dealer WS down completely.
  Future<void> _stopPublishing() async {
    await _pausePublishing();
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _connectionId = '';
  }

  Future<void> _ensureDealer(String token) async {
    final ws = _ws;
    if (ws != null &&
        ws.readyState == WebSocket.open &&
        _connectionId.isNotEmpty) {
      return;
    }
    if (DateTime.now().difference(_lastConnectAttempt) <
        const Duration(seconds: 10)) {
      return; // reconnect backoff
    }
    _lastConnectAttempt = DateTime.now();
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    _connectionId = '';
    try {
      _ws = await WebSocket.connect(
        'wss://dealer.g2.spotify.com/?access_token=$token',
      ).timeout(const Duration(seconds: 10));
      _log('dealer connected');
      _ws!.listen(
        (d) => _scanFrame(d),
        onDone: () {
          _log('dealer closed');
          _ws = null;
          _connectionId = '';
          _heartbeat?.cancel();
          _heartbeat = null;
        },
        onError: (e) {
          _log('dealer error: $e');
          _ws = null;
          _connectionId = '';
          _heartbeat?.cancel();
          _heartbeat = null;
        },
      );
      _heartbeat = Timer.periodic(_pingInterval, (_) => _sendPing());
      _sendPing(); // librespot pings immediately on open, not after 30s
    } catch (e) {
      _log('dealer connect failed: $e');
      _ws = null;
    }
  }

  /// Sends {"type":"ping"} and arms the 3s pong watchdog (librespot parity:
  /// "Did not receive ping in 3 seconds. Reconnecting...").
  void _sendPing() {
    final w = _ws;
    if (w == null || w.readyState != WebSocket.open) return;
    final generation = ++_pingGeneration;
    w.add(jsonEncode({'type': 'ping'}));
    final sentAt = DateTime.now();
    Future.delayed(_pongWatchdog, () {
      if (generation != _pingGeneration) return; // superseded by a newer ping
      final stillOpen = _ws != null && _ws!.readyState == WebSocket.open;
      if (stillOpen && _lastPongAt.isBefore(sentAt)) {
        _log('no pong within ${_pongWatchdog.inSeconds}s - reconnecting');
        _ws = null;
        _connectionId = '';
        _heartbeat?.cancel();
        _heartbeat = null;
        try {
          unawaited(w.close());
        } catch (_) {}
      }
    });
  }

  void _scanFrame(dynamic data) {
    try {
      final j = jsonDecode(data as String) as Map<String, dynamic>;
      switch (j['type']) {
        case 'pong':
          _lastPongAt = DateTime.now();
          break;
        case 'request':
          unawaited(_handleRequest(j));
          break;
        case 'message':
          if (j['headers'] is Map) {
            final headers = j['headers'] as Map<String, dynamic>;
            for (final k in headers.keys) {
              if (k.toLowerCase() == 'spotify-connection-id' &&
                  _connectionId.isEmpty) {
                _connectionId = headers[k] as String;
                _log('connection-id OK');
              }
            }
          }
          break;
      }
    } catch (e) {
      _log('frame parse error: $e');
    }
  }

  /// Spotify Connect commands arrive as dealer `request` frames routed to
  /// `hm://connect-state/v1/<our deviceId>` (librespot-java DealerClient.
  /// handleRequest). Each must be answered with a `reply` frame echoing the
  /// request's `key`, or the controlling client shows an error.
  Future<void> _handleRequest(Map<String, dynamic> frame) async {
    final mid = frame['message_ident'] as String?;
    final key = frame['key'];
    if (mid == null || key == null) {
      _log('request missing mid/key: $mid');
      return;
    }
    if (!mid.startsWith('hm://connect-state/v1/$_deviceId')) {
      _log('request for other target ignored: $mid');
      return;
    }

    // The payload may be gzip-compressed (Transfer-Encoding: gzip +
    // base64 "compressed" body), exactly as librespot handles it.
    var payload = frame['payload'];
    if (payload is Map && payload['compressed'] != null) {
      try {
        final gzipBytes =
            base64Decode((payload['compressed'] as String).trim());
        final decoded = gzip.decode(gzipBytes);
        payload = jsonDecode(utf8.decode(decoded)) as Map<String, dynamic>;
      } catch (e) {
        _log('gzip payload decode failed: $e');
        _sendReply(key as String, false);
        return;
      }
    }
    if (payload is! Map) {
      _log('request payload missing');
      _sendReply(key as String, false);
      return;
    }
    final command = payload['command'];
    if (command is! Map) {
      _log('request command missing');
      _sendReply(key as String, false);
      return;
    }

    final endpoint = (command['endpoint'] ?? '').toString();
    final messageId = (payload['message_id'] as num?)?.toInt();
    final sender = payload['sent_by_device_id'];
    _log(
      'command received: endpoint=$endpoint '
      'value=${command['value']} msgId=$messageId sender=$sender '
      'keys=${command.keys.toList()}',
    );

    var handled = false;
    final callback = onCommand;
    if (callback != null) {
      try {
        handled = await callback(
          endpoint,
          Map<String, dynamic>.from(command),
        );
      } catch (e) {
        _log('command handler error: $e');
        handled = false;
      }
    } else {
      _log('no command handler wired - rejecting');
    }
    _log('command endpoint=$endpoint handled=$handled');
    _sendReply(key as String, handled);
    if (handled) {
      _lastCommandSender = sender is String ? sender : null;
      _lastCommandMessageId = messageId;
      _pendingCommandAck = true;
    }
  }

  void _sendReply(String key, bool success) {
    final w = _ws;
    if (w == null || w.readyState != WebSocket.open) {
      _log('reply skipped - dealer closed');
      return;
    }
    w.add('{"type":"reply", "key": "$key", "payload": {"success": $success}}');
    _log('reply sent: key=$key success=$success');
  }

  Future<void> _putState(
    String token, {
    required String trackUri,
    required int positionMs,
    required int durationMs,
    required bool isPlaying,
    required int reason,
  }) async {
    if (_deviceId.isEmpty) {
      _deviceId = prefs.getString(_key('la_publish_device_id')) ?? '';
      if (_deviceId.isEmpty) {
        final rng = Random.secure();
        _deviceId = List.generate(
          32,
          (_) => '0123456789abcdef'[rng.nextInt(16)],
        ).join();
        await prefs.setString(_key('la_publish_device_id'), _deviceId);
      }
    }
    final now = DateTime.now();
    // connectstate.proto (verified against the librespot-java 1.6.5 jar):
    // PutStateRequest{device=2: Device{device_info=1, player_state=2},
    // member_type=3, is_active=4, put_state_reason=5, message_id=6}
    // PlayerState{timestamp=1, track=7: ProvidedTrack{uri=1, provider=6},
    // position_as_of_timestamp=10, duration=11, is_playing=12, is_paused=13}
    // DeviceInfo{can_play=1, volume=2, name=3, capabilities=4,
    // device_software_version=6, device_type=7, spirc_version=9,
    // device_id=10, is_private_session=11, client_id=13}
    // Capabilities{can_be_player=2, is_observable=7, supported_types=9}
    final body = _Pb()
      ..msg(2, (device) => device
        ..msg(1, (info) => info
          ..enumv(1, 1) // can_play
          ..enumv(2, 65536) // volume
          ..str(3, _deviceName)
          ..msg(4, (caps) => caps
            ..enumv(2, 1) // can_be_player
            ..enumv(7, 1) // is_observable
            ..enumv(8, 64) // volume_steps
            ..str(9, 'audio')
            ..str(9, 'episode')
            ..enumv(10, 1) // command_acks
            ..enumv(16, 1) // is_controllable
            ..enumv(19, 1) // supports_transfer_command
            ..enumv(20, 1) // supports_command_request
            ..enumv(22, 1) // needs_full_player_state
            ..enumv(23, 1)) // supports_gzip_pushes
          ..str(6, '1.2.52.442.g0b8abddf')
          ..enumv(7, 1) // device_type = COMPUTER
          ..str(9, '3.2.6')
          ..str(10, _deviceId)
          ..enumv(11, 0) // is_private_session = false
          ..str(13, _clientId))
        ..msg(2, (player) => player
          ..enumv(1, now.millisecondsSinceEpoch) // timestamp
          ..msg(7, (track) => track
            ..str(1, trackUri)
            ..str(6, 'context'))
          ..enumv(10, positionMs) // position_as_of_timestamp
          ..enumv(11, durationMs) // duration
          ..enumv(12, isPlaying ? 1 : 0) // is_playing
          ..enumv(13, isPlaying ? 0 : 1))) // is_paused
      ..enumv(3, 2) // member_type = CONNECT_STATE
      ..enumv(4, 1) // is_active
      ..enumv(5, reason)
      ..enumv(6, ++_seq)
      // Command acks: which device last commanded us and its message id,
      // so controlling clients see their command as accepted.
      ..str(7, _lastCommandSender ?? '')
      ..enumv(8, _lastCommandMessageId ?? 0);
    try {
      final req = await HttpClient().putUrl(
        Uri.parse(
          'https://spclient.wg.spotify.com/connect-state/v1/devices/$_deviceId',
        ),
      );
      req.headers.set('Authorization', 'Bearer $token');
      req.headers.set('Accept', 'application/x-protobuf');
      req.headers.contentType = ContentType.binary;
      req.headers.set('x-spotify-connection-id', _connectionId);
      final bytes = body.take();
      req.headers.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 12));
      // Drain the body so the socket is reusable.
      await res.drain<void>();
      if (res.statusCode != 200) {
        _log('PUT seq=$_seq reason=$reason -> ${res.statusCode}');
      } else if (_seq == 1 || reason == 1) {
        _log('first PUT OK (device=$_deviceId)');
      }
    } catch (e) {
      _log('PUT seq=$_seq error: $e');
    }
  }

  void _log(String message) => unawaited(MirrorTelemetry.log('Publish', message));
}

/// Minimal protobuf writer (same hand-rolled style as the one in
/// spotify_session.dart; kept private per file on purpose).
class _Pb {
  final BytesBuilder b = BytesBuilder();

  void varint(int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v >>>= 7;
    }
    b.addByte(v);
  }

  void tag(int field, int wire) => varint((field << 3) | wire);

  void str(int f, String s) => bytes(f, utf8.encode(s));

  void bytes(int f, List<int> bs) {
    tag(f, 2);
    varint(bs.length);
    b.add(bs);
  }

  void msg(int f, void Function(_Pb) build) {
    final inner = _Pb();
    build(inner);
    final m = inner.take();
    tag(f, 2);
    varint(m.length);
    b.add(m);
  }

  void enumv(int f, int v) {
    tag(f, 0);
    varint(v);
  }

  Uint8List take() => b.takeBytes();
}
