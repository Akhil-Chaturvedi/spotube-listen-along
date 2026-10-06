import 'dart:convert';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/services/logger/logger.dart';

final logsProvider = StreamProvider.autoDispose((ref) async* {
  final file = await AppLogger.getLogsPath();
  // The file may not exist yet (no logs written this session) or be empty.
  // Yield nothing instead of throwing so the UI can show an empty state.
  if (!await file.exists() || await file.length() == 0) {
    return;
  }

  final stream = file.openRead().transform(utf8.decoder);

  await for (final line in stream) {
    yield line;
  }
});
