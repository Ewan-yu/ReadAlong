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
  }) =>
      DubbingTake(
        id: id,
        projectId: 'project-1',
        sentenceId: sentenceId,
        takeKind: kind,
        audioRelativePath: 'dubbing/book/project/takes/$sentenceId/$id.wav',
        duration: const Duration(milliseconds: 800),
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
  }) =>
      DubbingMixSentenceTake(
        sentenceId: sentenceId,
        sequence: sequence,
        take: selectedTake(id: id, sentenceId: sentenceId, selected: selected),
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
  });

  test('纯人声不接收背景轨', () {
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
        outputPath: 'C:/app/dubbing/book/project/masters/work.ogg',
        mode: DubbingMixMode.voiceOnly,
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
        confirmedBackgroundPath: 'C:/app/books/copy/music.ogg',
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
    expect(
      () => DubbingMixPlan.create(
        sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
        outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
        mode: DubbingMixMode.withConfirmedBackground,
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
      ),
      throwsA(isA<DubbingMixInputException>()),
    );
  });

  test('默认 feature-gated service 明确报告未提供本地混音器', () async {
    final plan = DubbingMixPlan.create(
      sentenceTakes: [entry(id: 'take-1', sentenceId: 's0001', sequence: 1)],
      outputPath: 'C:/app/dubbing/book/project/masters/work.wav',
      mode: DubbingMixMode.voiceOnly,
    );

    await expectLater(
      const FeatureGatedDubbingMixService(enabled: false).render(plan),
      throwsA(
        isA<DubbingMixUnavailableException>().having(
          (error) => error.message,
          'message',
          contains('未启用'),
        ),
      ),
    );
  });
}
