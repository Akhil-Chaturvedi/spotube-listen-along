import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:spotube/services/metadata/endpoints/mirror_telemetry.dart';

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
  ///
  /// The official clients are push-first (dealer websocket delivers friend
  /// updates in real time; heartbeat ~25s) and only fall back to polling the
  /// listening-activity endpoints on a remote-configured interval
  /// (`listening-activity:poll_interval_ms`), historically ~30s (the old
  /// buddy-feed cadence). We match that 30s fallback cadence and add small
  /// jitter so our requests don't arrive at machine-regular intervals.
  static const tickInterval = Duration(seconds: 30);
  static const tickJitter = Duration(milliseconds: 2000);

  /// Demand model: polling only happens while something is actually
  /// consuming the data - the Friend Activity surface is visible (a UI
  /// effect calls [markInUse] on mount / app resume, granting a lease) or
  /// Listen-Along mirroring is active. When the lease expires and nothing
  /// mirrors, the loop goes fully dormant (zero requests; the UI simply
  /// keeps showing the last-known data until the surface is opened again).
  static const useLease = Duration(minutes: 3);

  /// How often the (slow-changing) friend list is refreshed.
  static const friendsInterval = Duration(minutes: 30);
  DateTime _friendsFetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final SharedPreferences prefs;
  final String pluginSlug;
  final Random _rng = Random();
  Timer? _timer;
  bool _running = false;
  String? _token;
  int _tokenExpMs = 0;
  String? _me;
  DateTime? _useUntil;

  /// Feed projection we last pushed a refresh for (see [_refreshFeed]).
  String? _notifiedSig;

  /// TEMP (remove with mirror_telemetry.dart): previous per-friend snapshot
  /// `{entityUri, isPlaying, timestampMs}` for fetch-diff logging.
  final Map<String, Map<String, dynamic>> _prevFeed = {};

  /// trackId -> fully mapped track metadata (lifetime of the service).
  /// Steady-state ticks therefore make zero network requests.
  final Map<String, Map<String, dynamic>> _trackCache = {};

  /// Set by the host: is a Listen-Along mirror currently active? Mirroring
  /// needs fresh data even when no friend surface is visible.
  bool Function()? mirroringActive;

  /// Optional generic push: called whenever the published feed content
  /// changed (first publish after setup, or a friend's track changed). The
  /// host wires this to the same callback `Plugin.requestRefresh()` uses, so
  /// plugin sections update within one tick instead of the next heartbeat.
  final void Function()? onFeedChanged;

  SpotifySessionService(this.prefs, this.pluginSlug, {this.onFeedChanged});

  String _key(String key) => 'spotube_plugin.$pluginSlug.$key';

  bool get _inUse =>
      (mirroringActive?.call() ?? false) ||
      (_useUntil != null && DateTime.now().isBefore(_useUntil!));

  /// Marks the data as "being consumed right now". Idempotent; each call
  /// extends the lease. Opens UI surfaces should call this on mount and on
  /// app resume.
  void markInUse({Duration lease = useLease}) {
    _useUntil = DateTime.now().add(lease);
    if (!_running) return;
    if (_timer != null) return; // loop already active
    // Wake immediately if the feed is missing/stale so an opened surface
    // shows fresh data within ~half a second.
    final feedTs = prefs.getInt(_key('la_feed_ts')) ?? 0;
    final stale = DateTime.now().millisecondsSinceEpoch - feedTs > 15000;
    if (stale || _token == null) {
      _timer = Timer(const Duration(milliseconds: 500), () {
        _tick();
        _scheduleNext();
      });
    }
  }

  /// Kept for lifecycle symmetry (the host calls it after plugin load); the
  /// demand model means no polling starts until [markInUse] / mirroring.
  void start() {
    _running = true;
  }

  void _scheduleNext() {
    if (!_running) return;
    if (!_inUse) {
      // Nobody is consuming: go dormant. The next markInUse wakes us.
      _timer = null;
      return;
    }
    final jitter = Duration(milliseconds: _rng.nextInt(2 * tickJitter.inMilliseconds) - tickJitter.inMilliseconds);
    _timer = Timer(tickInterval + jitter, () {
      _tick();
      _scheduleNext();
    });
  }

  /// Immediate one-shot refresh. Used by the Listen-Along mirror when OUR
  /// song is about to end and the friend may already have skipped ahead -
  /// don't wait out the regular interval. Rate-limited by the caller.
  Future<void> refreshNow() async {
    if (!_running || !_inUse) {
      await MirrorTelemetry.log(
          'FriendFeed', 'refreshNow SKIPPED (running=$_running inUse=$_inUse)');
      return;
    }
    if (_ticking) {
      await MirrorTelemetry.log(
          'FriendFeed', 'refreshNow SKIPPED (tick already in flight)');
      return;
    }
    await MirrorTelemetry.log('FriendFeed', 'refreshNow: demand tick');
    _timer?.cancel();
    _timer = null;
    await _tick();
    _scheduleNext();
  }

  bool _ticking = false;

  Future<void> _tick() async {
    if (_ticking) return;
    if (!_inUse) {
      // Lease expired / nothing mirroring: stay dormant.
      _timer = null;
      return;
    }
    _ticking = true;
    try {
      final needsToken =
          _token == null || DateTime.now().millisecondsSinceEpoch > _tokenExpMs - 10 * 60 * 1000;
      if (needsToken) {
        await _ensureLogin5();
      }
      if (_token == null || _me == null) return;

      // Friend list: auto-discovered from the follow graph (user-profile-view
      // v3, the same endpoint the desktop Profile -> Following tab uses).
      // Refreshed rarely; the manual la_friends list is unioned in so users
      // can add people they don't follow.
      if (DateTime.now().difference(_friendsFetchedAt) > friendsInterval) {
        await _refreshFriends();
      }

      final friends = _allFriendUsernames();
      if (friends.isEmpty) return;
      await _refreshFeed(friends);
    } catch (e) {
      // Upkeep is best-effort; a failed tick leaves the previous feed/token
      // intact and the next tick retries.
      await MirrorTelemetry.log('FriendFeed', 'tick error: $e');
    } finally {
      _ticking = false;
    }
  }

  /// Manual additions from the plugin's setup form (comma separated).
  List<String> _manualFriends() {
    final raw = prefs.getString(_key('la_friends')) ?? '';
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Auto (follow graph) + manual usernames.
  List<String> _allFriendUsernames() {
    final out = <String>[];
    final autoRaw = prefs.getString(_key('la_friends_auto'));
    if (autoRaw != null && autoRaw.isNotEmpty) {
      try {
        final list = jsonDecode(autoRaw) as List;
        for (final e in list) {
          if (e is Map && e['username'] is String) {
            out.add(e['username'] as String);
          }
        }
      } catch (_) {}
    }
    for (final u in _manualFriends()) {
      if (!out.contains(u)) out.add(u);
    }
    return out;
  }

  Future<void> _refreshFriends() async {
    final req = await HttpClient().getUrl(Uri.parse(
        'https://spclient.wg.spotify.com/user-profile-view/v3/profile/$_me/following?limit=200'));
    req.headers.set('Authorization', 'Bearer $_token');
    req.headers.set('Accept', 'application/json');
    req.headers.set('User-Agent', userAgent);
    final res = await req.close();
    final resBody = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (bb, d) => bb..add(d),
    ).then((bb) => bb.takeBytes());
    if (res.statusCode != 200) {
      throw const HttpException('user-profile-view following failed');
    }
    final json = jsonDecode(utf8.decode(resBody)) as Map<String, dynamic>;
    final profiles = (json['profiles'] as List? ?? [])
        .where((e) => e is Map)
        .map((e) => Map<String, dynamic>.from(e as Map))
        // The endpoint mixes artists in; the friend feed is user-to-user only.
        .where((p) => (p['uri'] as String? ?? '').startsWith('spotify:user:'))
        .map((p) {
          final uri = p['uri'] as String;
          return {
            'username': uri.substring('spotify:user:'.length),
            'displayName': p['name'],
            'imageUrl': p['image_url'],
          };
        })
        .toList();
    await prefs.setString(_key('la_friends_auto'), jsonEncode(profiles));
    _friendsFetchedAt = DateTime.now();
  }

  Future<void> _ensureLogin5() async {
    final blobB64 = prefs.getString(_key('la_blob'));
    var username = prefs.getString(_key('la_username'));
    if (blobB64 == null || blobB64.isEmpty) {
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
          ..str(1, username ?? '')
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
    String? okUsername;
    Uint8List? newBlob;
    for (final f in _parse(resBody)) {
      if (f.number == 1) {
        // LoginOk { username=1, access_token=2, stored_credential=3 }
        for (final g in _parse(f.bytes)) {
          if (g.number == 1) okUsername = utf8.decode(g.bytes);
          if (g.number == 2) access = utf8.decode(g.bytes);
          if (g.number == 3) newBlob = g.bytes;
        }
      }
    }

    if (access == null || access.isEmpty) {
      throw const HttpException('login5 did not return an access token');
    }

    // The canonical username comes back in LoginOk; an empty StoredCredential
    // username in the request is fine (the blob identifies the account).
    if (okUsername != null && okUsername.isNotEmpty) {
      _me = okUsername;
      unawaited(prefs.setString(_key('la_me'), okUsername));
      if (username == null || username.isEmpty) {
        username = okUsername;
        unawaited(prefs.setString(_key('la_username'), okUsername));
      }
    } else {
      _me = username ?? prefs.getString(_key('la_me'));
    }

    _token = access;
    // login5 access tokens live ~1h; refresh 10 minutes before expiry.
    _tokenExpMs = DateTime.now().millisecondsSinceEpoch + 55 * 60 * 1000;
    await prefs.setString(_key('la_token'), access);
    await prefs.setInt(_key('la_token_exp'), _tokenExpMs);
    if (newBlob != null && newBlob.isNotEmpty) {
      await prefs.setString(_key('la_blob'), base64Encode(newBlob));
    }
    await MirrorTelemetry.log('FriendFeed',
        'login5 token refreshed (me=$_me, blobRotated=${newBlob != null})');
  }

  Future<void> _refreshFeed(List<String> friends) async {
    // TEMP: request latency + per-friend diffs (remove with telemetry).
    final t0 = DateTime.now();
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
      await MirrorTelemetry.log('FriendFeed',
          'fetch FAILED status=${res.statusCode} '
          'after ${DateTime.now().difference(t0).inMilliseconds}ms');
      throw const HttpException('users-activity failed');
    }

    // Attach the auto-discovered display names/avatars to the feed entries so
    // the plugin renders real profiles with zero extra requests.
    final meta = <String, Map<String, dynamic>>{};
    final autoRaw = prefs.getString(_key('la_friends_auto'));
    if (autoRaw != null && autoRaw.isNotEmpty) {
      try {
        final list = jsonDecode(autoRaw) as List;
        for (final e in list) {
          if (e is Map && e['username'] is String) {
            meta[e['username'] as String] = {
              'displayName': e['displayName'],
              'imageUrl': e['imageUrl'],
            };
          }
        }
      } catch (_) {}
    }

    final json = jsonDecode(utf8.decode(resBody)) as Map<String, dynamic>;
    final activities = (json['activities'] as List? ?? [])
        .where((e) => e is Map)
        .map((e) {
          final entry = Map<String, dynamic>.from(e as Map);
          final activity = Map<String, dynamic>.from(
              (entry['activity'] ?? <String, dynamic>{}) as Map);
          final username = entry['username'];
          return {
            'username': username,
            'displayName': meta[username]?['displayName'],
            'imageUrl': meta[username]?['imageUrl'],
            'entityUri': activity['entityUri'],
            'isPlaying': activity['isPlaying'] == true,
            'timestampMs': _isoToMs(activity['timestamp'] as String?),
            'contextUri': activity['contextUri'],
          };
        })
        .toList();

    // TEMP: diff against the previous snapshot - one line per actual change,
    // so the Logs page shows exactly WHAT each fetch brought (track changes,
    // play-state flips, same-track timestamp moves = replay/seek evidence).
    final diffs = _diffFeed(activities);

    // Enrich FIRST, publish ONCE: publishing the thin feed and re-writing it
    // after enrichment made the feed oscillate between enriched and thin
    // (any fetch landing in between rendered "Unknown track").
    final feed = await _enrichFeed(activities);
    await prefs.setString(_key('la_feed'), jsonEncode(feed));
    await prefs.setInt(_key('la_feed_ts'), DateTime.now().millisecondsSinceEpoch);

    // Content-change push (same generic mechanism as Plugin.requestRefresh):
    // fires when the projected content changed - a friend's track changed, or
    // tracks gained/lost metadata (e.g. a thin -> enriched transition).
    final projection = feed
        .map((a) =>
            '${a['username']}|${a['entityUri']}|${a['track'] != null ? 1 : 0}')
        .toList()
      ..sort();
    final projectionStr = projection.join(';');
    final changed = projectionStr != _notifiedSig;
    if (changed) {
      _notifiedSig = projectionStr;
      onFeedChanged?.call();
    }
    // TEMP telemetry: one line per poll summarizing what the UI and the
    // mirror will decide on (see mirror_telemetry.dart).
    final baked = feed.where((a) => a['track'] != null).length;
    await MirrorTelemetry.log('FriendFeed',
        'feed fetched in ${DateTime.now().difference(t0).inMilliseconds}ms '
        'entries=${feed.length} baked=$baked contentChanged=$changed'
        '${diffs.isEmpty ? '' : ' | ${diffs.join(' | ')}'}');
  }

  /// TEMP (remove with mirror_telemetry.dart): builds human-readable diff
  /// lines between the previous and current feed, updating [_prevFeed].
  List<String> _diffFeed(List<Map<String, dynamic>> activities) {
    String shortUri(Object? s) =>
        s == null ? 'none' : s.toString().split(':').last;
    final snap = <String, Map<String, dynamic>>{};
    final out = <String>[];
    for (final a in activities) {
      final u = a['username']?.toString() ?? '?';
      final uri = a['entityUri']?.toString();
      final playing = a['isPlaying'] == true;
      final ts = a['timestampMs'];
      snap[u] = {'entityUri': uri, 'isPlaying': playing, 'timestampMs': ts};
      final p = _prevFeed[u];
      if (p == null) {
        out.add('$u appeared track=${shortUri(uri)} playing=$playing');
        continue;
      }
      if (p['entityUri'] != uri) {
        out.add('$u track ${shortUri(p['entityUri'])}->${shortUri(uri)} '
            'playing=$playing');
      } else if (p['isPlaying'] != playing) {
        out.add('$u playing ${p['isPlaying']}->$playing (same track)');
      } else if (ts is int &&
          p['timestampMs'] is int &&
          (p['timestampMs'] as int) != 0 &&
          ts != p['timestampMs']) {
        // Same track, same state, moved timestamp: replay/loop or seek
        // evidence - the delta shows which (a replay restarts near the
        // track's beginning, a ping is ~30s).
        out.add('$u same-track tsDelta=${ts - (p['timestampMs'] as int)}ms '
            '(replay/seek?) playing=$playing');
      }
    }
    for (final u in _prevFeed.keys) {
      if (!snap.containsKey(u)) out.add('$u disappeared');
    }
    _prevFeed
      ..clear()
      ..addAll(snap);
    return out;
  }

  /// Bakes full track objects (name/artist/album/art) into [activities] via
  /// the pathfinder v2 `getTrack` persisted query. The public REST
  /// `/tracks?ids=` endpoint rate-limits (429) even for native tokens - the
  /// GraphQL gateway accepts the login5 token directly (verified live).
  ///
  /// Results are cached for the service's lifetime, so steady-state ticks
  /// make ZERO requests; only ids never seen before are fetched (deleted or
  /// region-locked tracks are tombstoned in the cache and never retried).
  /// Entries whose fetch fails are left thin - the next tick retries them.
  Future<List<Map<String, dynamic>>> _enrichFeed(
      List<Map<String, dynamic>> activities) async {
    if (_token == null) return activities;

    var fetched = 0;
    var missed = 0;
    for (final a in activities) {
      final uri = a['entityUri'] as String?;
      if (uri == null || !uri.startsWith('spotify:track:')) continue;
      final id = uri.substring('spotify:track:'.length);
      if (_trackCache.containsKey(id)) continue;
      fetched++;
      final t = await _pathfinderTrack(id);
      if (t == null) {
        missed++; // transient failure; retry next tick
        continue;
      }
      _trackCache[id] = _mapRestTrack(t);
    }
    if (fetched > 0) {
      await MirrorTelemetry.log('FriendFeed',
          'enrich fetched=$fetched missed=$missed cacheSize=${_trackCache.length}');
    }

    return activities.map((a) {
      final uri = a['entityUri'] as String?;
      if (uri != null && uri.startsWith('spotify:track:')) {
        final t = _trackCache[uri.substring('spotify:track:'.length)];
        if (t != null) {
          return {...a, 'track': t};
        }
      }
      return a;
    }).toList();
  }

  /// Pathfinder v2 `getTrack` for one track id. Returns a REST-shaped map
  /// (input shape of [_mapRestTrack]), a minimal tombstone map when Spotify
  /// no longer knows the track, or null on transport/HTTP failure.
  static const getTrackHash =
      '612585ae06ba435ad26369870deaae23b5c8800a256cd8a57e08eddc25a37294';

  Future<Map<String, dynamic>?> _pathfinderTrack(String id) async {
    final body = utf8.encode(jsonEncode({
      'variables': {'uri': 'spotify:track:$id'},
      'operationName': 'getTrack',
      'extensions': {
        'persistedQuery': {'version': 1, 'sha256Hash': getTrackHash}
      }
    }));
    final req = await HttpClient().postUrl(
        Uri.parse('https://api-partner.spotify.com/pathfinder/v2/query'));
    req.headers.set('Authorization', 'Bearer $_token');
    req.headers.set('Accept', 'application/json');
    req.headers.set('Content-Type', 'application/json');
    req.headers.set('User-Agent', userAgent);
    req.headers.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final resBody = await res.fold<BytesBuilder>(
      BytesBuilder(),
      (bb, d) => bb..add(d),
    ).then((bb) => bb.takeBytes());
    if (res.statusCode != 200) return null;

    final json = jsonDecode(utf8.decode(resBody)) as Map<String, dynamic>;
    final track = (json['data'] is Map)
        ? (json['data'] as Map)['trackUnion']
        : null;
    if (track is! Map) {
      // Deleted/regional tracks resolve to null: tombstone them so one bad
      // entry can't block the whole pass from being recorded.
      return const {'id': null, 'name': null, 'explicit': false, 'duration_ms': 0};
    }

    final album = (track['albumOfTrack'] ?? {}) as Map;
    final date = (album['date'] ?? {}) as Map;
    final artists = <Map<String, dynamic>>[];
    for (final key in ['firstArtist', 'otherArtists']) {
      final page = (track[key] ?? {}) as Map;
      for (final it in (page['items'] ?? []) as List) {
        if (it is Map) {
          final uri = it['uri'] as String? ?? '';
          artists.add({
            'id': uri.split(':').last,
            'name': ((it['profile'] ?? {}) as Map)['name'],
          });
        }
      }
    }

    return {
      'id': track['id'] ?? id,
      'name': track['name'],
      'explicit': ((track['contentRating'] ?? {}) as Map)['label'] == 'EXPLICIT',
      'duration_ms': ((track['duration'] ?? {}) as Map)['totalMilliseconds'] ?? 0,
      'artists': artists,
      'album': {
        'id': album['id'],
        'name': album['name'],
        'album_type':
            ((album['type'] ?? 'album') as String).toLowerCase(),
        'images': ((album['coverArt'] ?? {}) as Map)['sources'] ?? [],
        'release_date': date['isoString'] ?? '',
        'release_date_precision':
            (date['precision'] ?? '').toString().toLowerCase(),
      },
    };
  }

  /// Public-API track JSON -> the plugin's full-track model shape.
  static Map<String, dynamic> _mapRestTrack(Map<String, dynamic> t) {
    final album = Map<String, dynamic>.from((t['album'] ?? {}) as Map);
    final rawType = album['album_type'] ?? 'album';
    final albumType =
        (rawType == 'single' || rawType == 'compilation') ? rawType : 'album';
    final images = ((album['images'] ?? []) as List)
        .whereType<Map>()
        .map((img) => {
              'url': img['url'],
              'width': img['width'],
              'height': img['height'],
            })
        .toList();
    return {
      'id': t['id'],
      'name': t['name'],
      'externalUri': 'spotify:track:${t['id']}',
      'explicit': t['explicit'] == true,
      'durationMs': t['duration_ms'] ?? 0,
      'isrc':
          ((t['external_ids'] ?? {}) as Map)['isrc'] ?? '',
      'artists': ((t['artists'] ?? []) as List)
          .whereType<Map>()
          .map((a) => {
                'id': a['id'],
                'name': a['name'],
                'externalUri': 'spotify:artist:${a['id']}',
                'images': const [],
              })
          .toList(),
      'album': {
        'id': album['id'],
        'name': album['name'],
        'externalUri': album['id'] != null
            ? 'spotify:album:${album['id']}'
            : '',
        'releaseDate': album['release_date'] ?? '',
        'releaseDatePrecision': album['release_date_precision'] ?? 'year',
        'artists': const [],
        'images': images,
        'albumType': albumType,
      },
    };
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
