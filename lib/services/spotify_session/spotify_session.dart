import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

/// Tiny protobuf writer (field-scoped), ported from the verified login5
/// probes (misc/tests/ap_login_test.dart).
class _Pb {
  final BytesBuilder b = BytesBuilder();

  void _varint(int v) {
    while (v >= 0x80) {
      b.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    b.addByte(v);
  }

  void _tag(int field, int wire) => _varint((field << 3) | wire);

  void str(int f, String s) => bytes(f, utf8.encode(s));

  void bytes(int f, List<int> bs) {
    _tag(f, 2);
    _varint(bs.length);
    b.add(bs);
  }

  void msg(int f, void Function(_Pb) build) {
    final inner = _Pb();
    build(inner);
    final m = inner.take();
    _tag(f, 2);
    _varint(m.length);
    b.add(m);
  }

  Uint8List take() => b.takeBytes();
}

class _Field {
  final int number, wire, varint;
  final Uint8List bytes;
  _Field(this.number, this.wire, this.varint, this.bytes);
}

List<_Field> _parse(Uint8List data) {
  final out = <_Field>[];
  var i = 0;
  int readVarint() {
    var v = 0, shift = 0;
    while (true) {
      final b = data[i++];
      v |= (b & 0x7f) << shift;
      if (b < 0x80) return v;
      shift += 7;
    }
  }

  while (i < data.length) {
    final key = readVarint();
    final number = key >> 3, wire = key & 7;
    if (wire == 0) {
      out.add(_Field(number, wire, readVarint(), Uint8List(0)));
    } else if (wire == 2) {
      final len = readVarint();
      out.add(_Field(number, wire, 0, Uint8List.sublistView(data, i, i + len)));
      i += len;
    } else if (wire == 5) {
      i += 4;
    } else if (wire == 1) {
      i += 8;
    } else {
      break;
    }
  }
  return out;
}

/// Native Spotify session for the "Listen Along / Friend Activity" feature.
///
/// Why this exists: Spotify removed friend-feed access from web tokens
/// (sp_dc) entirely (2026-10 crackdown) and dealer WS subscriptions reject
/// third-party sessions with a "Bye" close. The only remaining data path is
/// `POST listening-activity/v1/users-activity`, which requires a NATIVE
/// login5 access token minted from a StoredCredential blob - a protobuf
/// exchange the Hetu plugin sandbox cannot perform (no binary request
/// bodies, no websockets).
///
/// Data flow:
///   1. The user pastes the one-time credentials blob (produced via the
///      librespot-java browser-OAuth procedure) plus their friend usernames
///      into the plugin's setup form. The plugin stores them in LocalStorage
///      as `la_username`, `la_blob`, `la_friends` (comma separated).
///   2. This service (Dart-side) exchanges the blob for an access token via
///      login5, rotates the blob (persisted back), polls
///      users-activity for the configured friends, and publishes a
///      normalized feed JSON to LocalStorage as `la_feed`:
///      `{"username","entityUri","isPlaying","timestampMs","contextUri"}[]`
///   3. The plugin's friend_activity segment simply reads `la_feed`, enriches
///      the track ids via the public API and renders the cards.
///
/// LocalStorage keys are the plugin's SharedPreferences keys:
/// `spotube_plugin.<slug>.<key>` (see SharedPreferencesLocalStorage).
class SpotifySessionService {
  static const clientId = '65b708073fc0480ea92a077233ca87bd';
  static const deviceId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
  static const userAgent = 'Spotify/124200290 Win32/11.0.0 (PC desktop)';
  static const login5Url = 'https://login5.spotify.com/v3/login';
  static const usersActivityUrl =
      'https://spclient.wg.spotify.com/listening-activity/v1/users-activity';

  /// How often the feed is polled and the token freshness checked.
  static const tickInterval = Duration(seconds: 20);

  final SharedPreferences prefs;
  final String pluginSlug;
  Timer? _timer;
  bool _running = false;
  String? _token;
  int _tokenExpMs = 0;

  SpotifySessionService(this.prefs, this.pluginSlug);

  String _key(String key) => 'spotube_plugin.$pluginSlug.$key';

  /// Starts the upkeep clock (idempotent).
  void start() {
    if (_running) return;
    _running = true;
    // First attempt shortly after startup so the Friend Activity section has
    // data as soon as the user opens Browse.
    Timer(const Duration(seconds: 2), _tick);
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    try {
      final friends = _configuredFriends();
      final needsToken =
          _token == null || DateTime.now().millisecondsSinceEpoch > _tokenExpMs - 10 * 60 * 1000;
      if (needsToken) {
        await _ensureLogin5();
      }
      if (_token == null || friends.isEmpty) return;
      await _refreshFeed(friends);
    } catch (_) {
      // Upkeep is best-effort; a failed tick leaves the previous feed/token
      // intact and the next tick retries.
    }
  }

  List<String> _configuredFriends() {
    final raw = prefs.getString(_key('la_friends')) ?? '';
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _ensureLogin5() async {
    final blobB64 = prefs.getString(_key('la_blob'));
    final username = prefs.getString(_key('la_username'));
    if (blobB64 == null || blobB64.isEmpty || username == null || username.isEmpty) {
      return; // not configured yet
    }

    final blob = base64Decode(blobB64);
    final l5 = _Pb()
      ..msg(1, (ci) {
        ci
          ..str(1, clientId)
          ..str(2, deviceId);
      })
      ..bytes(2, [])
      ..msg(100, (sc) {
        sc
          ..str(1, username)
          ..bytes(2, blob);
      });

    final req = await HttpClient().postUrl(Uri.parse(login5Url));
    req.headers.set('Accept', 'application/x-protobuf');
    req.headers.set('Content-Type', 'application/x-protobuf');
    req.headers.set('User-Agent', userAgent);
    final body = l5.take();
    req.headers.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final resBody = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (bb, d) => bb..add(d),
    ).then((bb) => bb.takeBytes());

    String? access;
    Uint8List? newBlob;
    for (final f in _parse(resBody)) {
      if (f.number == 1) {
        // LoginOk { username=1, access_token=2, stored_credential=3 }
        for (final g in _parse(f.bytes)) {
          if (g.number == 2) access = utf8.decode(g.bytes);
          if (g.number == 3) newBlob = g.bytes;
        }
      }
    }

    if (access == null || access.isEmpty) {
      throw const HttpException('login5 did not return an access token');
    }

    _token = access;
    // login5 access tokens live ~1h; refresh 10 minutes before expiry.
    _tokenExpMs = DateTime.now().millisecondsSinceEpoch + 55 * 60 * 1000;
    await prefs.setString(_key('la_token'), access);
    await prefs.setInt(_key('la_token_exp'), _tokenExpMs);
    if (newBlob != null && newBlob.isNotEmpty) {
      await prefs.setString(_key('la_blob'), base64Encode(newBlob));
    }
  }

  Future<void> _refreshFeed(List<String> friends) async {
    final req = await HttpClient().postUrl(Uri.parse(usersActivityUrl));
    req.headers.set('Authorization', 'Bearer $_token');
    req.headers.set('Accept', 'application/json');
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', userAgent);
    final body = utf8.encode(jsonEncode({'usernames': friends}));
    req.headers.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final resBody = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (bb, d) => bb..add(d),
    ).then((bb) => bb.takeBytes());
    if (res.statusCode != 200) {
      throw const HttpException('users-activity failed');
    }

    final json = jsonDecode(utf8.decode(resBody)) as Map<String, dynamic>;
    final activities = (json['activities'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((entry) {
          final activity = (entry['activity'] ?? {}) as Map<String, dynamic>;
          return {
            'username': entry['username'],
            'entityUri': activity['entityUri'],
            'isPlaying': activity['isPlaying'] == true,
            'timestampMs': _isoToMs(activity['timestamp'] as String?),
            'contextUri': activity['contextUri'],
          };
        })
        .toList();

    await prefs.setString(_key('la_feed'), jsonEncode(activities));
    await prefs.setInt(_key('la_feed_ts'), DateTime.now().millisecondsSinceEpoch);
  }

  /// "2026-11-01T09:59:10.538Z" -> epoch ms.
  static int _isoToMs(String? iso) {
    if (iso == null || iso.length < 19) return 0;
    try {
      final y = int.parse(iso.substring(0, 4));
      final mo = int.parse(iso.substring(5, 7));
      final d = int.parse(iso.substring(8, 10));
      final h = int.parse(iso.substring(11, 13));
      final mi = int.parse(iso.substring(14, 16));
      final se = int.parse(iso.substring(17, 19));
      final ms = iso.length >= 23 ? int.parse(iso.substring(20, 23)) : 0;
      final utc = DateTime.utc(y, mo, d, h, mi, se, ms);
      return utc.millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }
}
