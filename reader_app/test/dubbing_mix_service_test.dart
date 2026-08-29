import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_app/data/appdb/dubbing_models.dart';
import 'package:reader_app/services/audio/dubbing_mix_service.dart';

void main() {
  DubbingTake selectedTake({
    required String id,
    required String sentenceId,
    bool selected = true,
    DubbingTakeKind kind = DubbingTakeKind.sentence,
    Duration contentOffset = Duration.zero,
    Duration duration = const Duration(milliseconds: 800),
  }) =>
      DubbingTake(
        id: id,
        projectId: 'project-1',
        sentenceId: sentenceId,
        takeKind: kind,
        audioRelativePath: 'dubbing/book/project/takes/$sentenceId/$id.wav',
        duration: duration,
        contentOffset: contentOffset,
        isSelected: selected,
        scoreStatus: DubbingTakeScoreStatus.scored,
        createdAt: DateTime.utc(2026, 8, 1),
      );

  DubbingMixSentenceTake entry({
    required String id,
    required String sentenceId,
    required int sequence,
    String? path,
    bool selected = true,
    Duration duration = const Duration(milliseconds: 800),
  }) =>
      DubbingMixSentenceTake(
        sentenceId: sentenceId,
        sequence: sequence,
        start: Duration(seconds: sequence - 1),
        end: Duration(seconds: sequence),
        take: selectedTake(
          id: id,
          sentenceId: sentenceId,
          selected: selected,
          duration: duration,
        ),
        audioPath:
            path ?? 'C:/app/dubbing/book/project/takes/$sentenceId/$id.wav',
      );

  test('只把已选用的逐句 Take 按句序交给背景混音', () {
    final plan = DubbingMixPlan.create(
      sentenceTakes: [
        entry(id: 'take-2', sentenceId: 's0002', sequence: 2),
        entry(id: 'take-1', sentenceId: 's0001', sequence: 1),
      ],
      outputPath: 'C:/app/dubbing/book/project/masters/work.m4a',
      mode: DubbingMixMode.withConfirmedBackground,
      timelineDuration: const Duration(seconds: 5),
      confirmedBackgroundPath: 'C:/app/books/copy/original/background.ogg',
      originalSourcePath: 'C:/app/books/copy/original/source.mp3',
    );

    expect(plan.usesConfirmedBackground, isTrue);
    expect(
        plan.sentenceTakes.map((take) => take.sentenceId), ['s0001', 's0002']);
    expect(
      plan.backgroundPath,
      endsWith('original${p.separator}background.ogg'),
    );
    expect(plan.backgroundGainDb, defaultDubbingBackgroundGainDb);
    expect(plan.backgroundGainDb, -12);
  });

  test('纯人声不接收背景轨', () {
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
        outputPath: 'C:/app/dubbing/book/project/masters/work.ogg',
        mode: DubbingMixMode.voiceOnly,
        timelineDuration: const Duration(seconds: 5),
        confirmedBackgroundPath: 'C:/app/books/copy/original/background.ogg',
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
  });

  test('拒绝未确认背景、source.mp3 和未选用 Take', () {
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
        outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
        mode: DubbingMixMode.withConfirmedBackground,
        timelineDuration: const Duration(seconds: 5),
        confirmedBackgroundPath: 'C:/app/books/copy/music.ogg',
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
        outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
        mode: DubbingMixMode.withConfirmedBackground,
        timelineDuration: const Duration(seconds: 5),
        confirmedBackgroundPath: 'C:/app/books/copy/original/source.mp3',
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [
          entry(
            id: 'take-1',
            sentenceId: 's0001',
            sequence: 1,
            path: 'C:/app/books/copy/original/source.mp3',
          ),
        ],
        outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
        mode: DubbingMixMode.voiceOnly,
        timelineDuration: const Duration(seconds: 5),
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [
          entry(
            id: 'take-1',
            sentenceId: 's0001',
            sequence: 1,
            selected: false,
          ),
        ],
        outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
        mode: DubbingMixMode.voiceOnly,
        timelineDuration: const Duration(seconds: 5),
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
  });

  test('命令只读取背景和私有 Take，绝不读取原朗读轨', () {
    final plan = DubbingMixPlan.create(
      sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
      outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
      mode: DubbingMixMode.withConfirmedBackground,
      timelineDuration: const Duration(seconds: 5),
      confirmedBackgroundPath: 'C:/app/books/copy/original/background.ogg',
      originalSourcePath: 'C:/app/books/copy/original/source.mp3',
    );
    final command = FfmpegKitDubbingMixService.buildCommandForTest(
      plan,
      'C:/app/dubbing/book/project/mixes/.work.part.wav',
    );
    expect(command, contains('background.ogg'));
    expect(command, isNot(contains('source.mp3')));
    expect(command, contains('adelay=0:all=1'));
    expect(command, contains('volume=0.251188643'));
    expect(command, contains('loudnorm=I=-16:TP=-1'));
  });

  test('混音先裁掉麦克风预热段，再放到原音时间轴', () {
    final take = selectedTake(
      id: 'take-offset',
      sentenceId: 's0001',
      contentOffset: const Duration(milliseconds: 3650),
    );
    final plan = DubbingMixPlan.create(
      sentenceTakes: [
        DubbingMixSentenceTake(
          sentenceId: 's0001',
          sequence: 1,
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 3),
          take: take,
          audioPath: 'C:/app/dubbing/book/project/takes/s0001/take.wav',
        ),
      ],
      outputPath: 'C:/app/dubbing/book/project/mixes/work.wav',
      mode: DubbingMixMode.voiceOnly,
      timelineDuration: const Duration(seconds: 5),
    );

    final command = FfmpegKitDubbingMixService.buildCommandForTest(
      plan,
      'C:/app/dubbing/book/project/mixes/.work.part.wav',
    );

    expect(command, contains('atrim=start=3.650'));
    expect(command, contains('adelay=2000:all=1'));
    expect(plan.sourceTakeFingerprint, contains('+3650'));
  });

  test('儿童录音较慢时顺延后续句，保留自然间隔且不重叠', () {
    final plan = DubbingMixPlan.create(
      sentenceTakes: [
        entry(
          id: 'take-1',
          sentenceId: 's0001',
          sequence: 1,
          duration: const Duration(milliseconds: 1300),
        ),
        entry(id: 'take-2', sentenceId: 's0002', sequence: 2),
        entry(id: 'take-3', sentenceId: 's0003', sequence: 3),
      ],
      outputPath: 'C:/app/dubbing/book/project/mixes/work.wav',
      mode: DubbingMixMode.voiceOnly,
      timelineDuration: const Duration(seconds: 3),
    );

    expect(plan.sentenceTakes.map((entry) => entry.start), [
      Duration.zero,
      const Duration(milliseconds: 1650),
      const Duration(milliseconds: 2800),
    ]);
    expect(plan.renderDuration, const Duration(milliseconds: 3600));

    final command = FfmpegKitDubbingMixService.buildCommandForTest(
      plan,
      'C:/app/dubbing/book/project/mixes/.work.part.wav',
    );
    expect(command, contains('adelay=1650:all=1'));
    expect(command, contains('adelay=2800:all=1'));
  });

  test('成功后才原子发布作品，失败会清理半成品', () async {
    final directory =
        await Directory.systemTemp.createTemp('mix_service_test_');
    addTearDown(() => directory.delete(recursive: true));
    final projectDirectory = Directory(
      p.join(directory.path, 'dubbing', 'book', 'project'),
    );
    await projectDirectory.create(recursive: true);
    final takePath = p.join(
      projectDirectory.path,
      'takes',
      's0001',
      'take.wav',
    );
    await File(takePath).parent.create(recursive: true);
    await File(takePath).writeAsBytes([1, 2, 3]);
    final outputPath = p.join(projectDirectory.path, 'mixes', 'work.wav');
    await File(outputPath).parent.create(recursive: true);
    final plan = DubbingMixPlan.create(
      sentenceTakes: [
        entry(id: 'take-1', sentenceId: 's0001', sequence: 1, path: takePath)
      ],
      outputPath: outputPath,
      mode: DubbingMixMode.voiceOnly,
      timelineDuration: const Duration(seconds: 5),
    );
    final temporary = File(p.join(p.dirname(outputPath), '.work.part.wav'));
    final service = FfmpegKitDubbingMixService(
      executor: _Executor(() async {
        await temporary.writeAsBytes([4, 5, 6]);
        return const DubbingMixCommandResult(success: true);
      }),
    );
    final result = await service.render(plan);
    expect(result.outputPath, outputPath);
    expect(await File(outputPath).readAsBytes(), [4, 5, 6]);
    expect(await temporary.exists(), isFalse);

    final failedOutput = p.join(projectDirectory.path, 'mixes', 'failed.wav');
    final failedTemporary =
        File(p.join(p.dirname(failedOutput), '.failed.part.wav'));
    final failedPlan = DubbingMixPlan.create(
      sentenceTakes: [
        entry(id: 'take-2', sentenceId: 's0001', sequence: 1, path: takePath)
      ],
      outputPath: failedOutput,
      mode: DubbingMixMode.voiceOnly,
      timelineDuration: const Duration(seconds: 5),
    );
    final failing = FfmpegKitDubbingMixService(
      executor: _Executor(() async {
        await failedTemporary.writeAsBytes([7]);
        return const DubbingMixCommandResult(success: false, output: 'failed');
      }),
    );
    await expectLater(
        failing.render(failedPlan), throwsA(isA<DubbingMixRenderException>()));
    expect(await File(failedOutput).exists(), isFalse);
    expect(await failedTemporary.exists(), isFalse);
  });
}

final class _Executor implements DubbingMixCommandExecutor {
  const _Executor(this._run);
  final Future<DubbingMixCommandResult> Function() _run;
  @override
  Future<DubbingMixCommandResult> execute(String command) => _run();
}
