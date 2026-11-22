import 'dart:io';

import 'package:spotube/services/logger/logger.dart';

/// TEMPORARY mirror/feed telemetry. Originally added 2026-11-04 for tuning
/// Listen Along; since 2026-11-22 it is VOLUMETRY-GATED instead of removed:
///
/// - [log]    per-tick diagnostics ("no-change", "feed fetched", dealer
///            lifecycle). Written ONLY when [verbose] is true (diagnosis
///            mode - flip the flag, rebuild, done).
/// - [logAlways] rare state transitions (mirror start/stop, track change,
///            login5 refresh, Connect commands). Kept in normal operation -
///            a few lines per day at most.
/// - [logError]  failures. Always written.
///
/// Every line goes to BOTH the logger console AND the .spotube_logs file,
/// because the in-app Logs page renders the file and release builds only
/// write errors there otherwise.
class MirrorTelemetry {
  /// Diagnosis mode: false = keep the log lean (transitions + failures only).
  static const bool verbose = false;

  static File? _file;
  static bool _fileBroken = false;

  /// Per-tick diagnostics. Only written in [verbose] mode.
  static Future<void> log(String tag, String message) async {
    if (!verbose) return;
    await _write(tag, message);
  }

  /// Rare, high-value state transitions. Always written.
  static Future<void> logAlways(String tag, String message) async {
    await _write(tag, message);
  }

  /// Failures. Always written.
  static Future<void> logError(String tag, String message) async {
    await _write(tag, message);
  }

  static Future<void> _write(String tag, String message) async {
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
