import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Per-stage budget for opening and querying immutable package databases.
const Duration stageTimeout = Duration(seconds: 10);

/// Runs one pipeline stage with tracing and a single timeout retry.
///
/// Right after an import, sqflite on low-end tablets can stall one stage past
/// its budget (observed as a 10 s `TimeoutException` with no plugin reply).
/// One fresh attempt self-heals that transient stall; a second timeout is a
/// real problem and is rethrown for the caller's error surface.
Future<T> traceStage<T>(
  String name,
  String stage,
  Future<T> Function() operation, {
  Duration timeout = stageTimeout,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await operation().timeout(timeout);
    developer.log('$stage:done:${stopwatch.elapsedMilliseconds}ms', name: name);
    return result;
  } on TimeoutException {
    developer.log('$stage:timeout-retry', name: name);
    final retryStopwatch = Stopwatch()..start();
    try {
      final result = await operation().timeout(timeout);
      developer.log(
        '$stage:retry-done:${retryStopwatch.elapsedMilliseconds}ms',
        name: name,
      );
      return result;
    } on TimeoutException catch (error, stackTrace) {
      developer.log(
        '$stage:timeout:${retryStopwatch.elapsedMilliseconds}ms',
        name: name,
        error: error,
        stackTrace: stackTrace,
      );
      debugPrint('readalong.$name $stage timed out twice; giving up');
      rethrow;
    }
  }
}
