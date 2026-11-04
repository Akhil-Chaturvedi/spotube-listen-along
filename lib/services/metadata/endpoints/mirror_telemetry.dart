import 'dart:io';

import 'package:spotube/services/logger/logger.dart';

/// TEMPORARY mirror/feed telemetry (added 2026-11-04 for tuning Listen
/// Along). REMOVE THIS FILE and its call sites once the policies are
/// verified.
///
/// Every line goes to BOTH the logger console AND the .spotube_logs file,
/// because the in-app Logs page renders the file and release builds only
/// write errors there otherwise. Filter lines by the [tag] ("ListenAlong" /
/// "FriendFeed").
class MirrorTelemetry {
  static File? _file;
  static bool _fileBroken = false;

  static Future<void> log(String tag, String message) async {
    final line = '[${DateTime.now().toIso8601String()}] [$tag] $message';
    AppLogger.log.i(line);
    if (_fileBroken) return;
    try {
      _file ??= await AppLogger.getLogsPath();
      await _file!.writeAsString('$line\n', mode: FileMode.writeOnlyAppend);
    } catch (_) {
      _fileBroken = true;
    }
  }
}
