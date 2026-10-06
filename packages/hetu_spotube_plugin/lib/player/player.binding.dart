import 'package:hetu_script/binding.dart';
import 'package:hetu_script/hetu_script.dart';
import 'package:hetu_spotube_plugin/player/player.dart';

/// Hetu-side instance members for [Player].
///
/// The plugin gets a single `Player` instance (see [PlayerClassBinding]) and
/// calls these methods on it. Track arguments are plain maps in the same shape
/// as `MetadataTrack`.
extension PlayerBinding on Player {
  dynamic htFetch(String id) {
    return switch (id) {
      "loadTracks" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        final tracks = (positionalArgs[0] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        return loadTracks(
          tracks,
          autoPlay: (namedArgs["autoPlay"] as bool?) ?? false,
          initialIndex: (namedArgs["initialIndex"] as int?) ?? 0,
        );
      },
      "playTrack" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return playTrack(
          Map<String, dynamic>.from(positionalArgs[0] as Map),
        );
      },
      "addToQueue" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return addToQueue(
          Map<String, dynamic>.from(positionalArgs[0] as Map),
        );
      },
      "play" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return play();
      },
      "pause" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return pause();
      },
      "next" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return next();
      },
      "previous" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return previous();
      },
      "seek" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return seek(positionalArgs[0] as int);
      },
      "getState" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return getState();
      },
      _ => throw HTError.undefined(id),
    };
  }
}

/// Exposes a `Player` class to Hetu. The host supplies a factory that returns
/// a [SpotubePlayer] wired to the real audio player.
class PlayerClassBinding extends HTExternalClass {
  final Player Function() createPlayer;

  PlayerClassBinding({required this.createPlayer}) : super("Player");

  @override
  dynamic memberGet(String varName, {String? from}) {
    return switch (varName) {
      "Player" => (
        HTEntity entity, {
        List<dynamic> positionalArgs = const [],
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) {
        return createPlayer();
      },
      _ => HTError.undefined(varName),
    };
  }

  @override
  instanceMemberGet(object, String varName) =>
      (object as Player).htFetch(varName);
}
