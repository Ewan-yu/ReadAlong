import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/stage_trace.dart';

void main() {
  test('阶段一次成功时直接返回', () async {
    var attempts = 0;

    final result = await traceStage(
      'test',
      'fast_stage',
      () async {
        attempts += 1;
        return 'value';
      },
      timeout: const Duration(milliseconds: 200),
    );

    expect(result, 'value');
    expect(attempts, 1);
  });

  test('偶发停顿超过预算时重试一次并成功', () async {
    var attempts = 0;

    final result = await traceStage(
      'test',
      'stalled_stage',
      () async {
        attempts += 1;
        if (attempts == 1) {
          // Simulates a transient sqflite stall past the stage budget.
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        return 'recovered';
      },
      timeout: const Duration(milliseconds: 50),
    );

    expect(result, 'recovered');
    expect(attempts, 2);
  });

  test('连续两次超时才放弃并保留 TimeoutException', () async {
    var attempts = 0;

    await expectLater(
      traceStage(
        'test',
        'dead_stage',
        () async {
          attempts += 1;
          await Future<void>.delayed(const Duration(milliseconds: 150));
          return 'never';
        },
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(attempts, 2);
  });
}
