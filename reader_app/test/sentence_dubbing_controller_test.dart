import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/features/dubbing/dubbing_repository.dart';
import 'package:reader_app/features/dubbing/sentence_dubbing_controller.dart';
import 'package:reader_app/features/dubbing/sentence_dubbing_page.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';
import 'package:reader_app/services/recording/recording_service.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/scoring_provider.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart';

void main() {
  late Directory temporary;
  late _Repository repository;
  late _Player player;
  late _Recorder recorder;
  late List<String> events;
  late ProviderContainer container;
  ProviderSubscription<AsyncValue<SentenceDubbingState>>? subscription;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('sentence_dubbing_');
    repository = _Repository(temporary);
    events = [];
    player = _Player(events);
    recorder = _Recorder(temporary, events);
    container = ProviderContainer(overrides: [
      dubbingRepositoryProvider.overrideWith((_) async => repository),
      recordingServiceProvider.overrideWith((_) async => recorder),
      sentenceDubbingPreparationProtocolProvider
          .overrideWithValue(_ImmediatePreparation()),
      sentenceAudioPlayerProvider.overrideWithValue(player),
      scoringProvider.overrideWithValue(_Scorer()),
      originalAudioBookProvider('book-copy').overrideWith((_) async => _book()),
    ]);
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await pumpEventQueue();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<SentenceDubbingController> ready() async {
    subscription = container.listen(
      sentenceDubbingControllerProvider('book-copy'),
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(sentenceDubbingControllerProvider('book-copy').future);
    return container
        .read(sentenceDubbingControllerProvider('book-copy').notifier);
  }

  SentenceDubbingState current() => container
      .read(sentenceDubbingControllerProvider('book-copy'))
      .requireValue;

  test('单次主操作自动完成示范、准备、录音、评分和选用', () async {
    final controller = await ready();

    await controller.startRecording();
    expect(current().phase, SentenceDubbingPhase.recording);
    expect(player.played.single.path, 'original.ogg');
    expect(player.played.single.start, Duration.zero);
    expect(events.take(2), ['recorder.start', 'player.play']);

    await controller.stopRecording();

    expect(current().phase, SentenceDubbingPhase.result);
    expect(current().completedSentenceCount, 1);
    expect(current().takes.single.isSelected, isTrue);
    expect(current().result?.childScore, 90);

    await controller.continueToNextSentence();
    expect(current().sentenceIndex, 1);
    expect(current().sentence.id, 's2');
  });

  test('Android 切后台会结束并保存正在录制的句子', () async {
    final controller = await ready();
    await controller.startRecording();

    await controller.handleAppBackgrounded();

    expect(current().takes, hasLength(1));
    expect(current().takes.single.isSelected, isTrue);
    expect(current().failure, contains('安全保存'));
  });

  test('非首句示范从首词准确起播，不把句间笑声带入下一句', () async {
    final controller = await ready();
    await controller.nextSentence();

    await controller.startRecording();

    expect(player.played.single.start, const Duration(seconds: 1));
    expect(player.played.single.end, const Duration(seconds: 2));
    expect(current().sentence.start, const Duration(seconds: 1));
    await controller.stopRecording();
  });

  test('删除录音时有剩余就保留结果操作，删空后才显示开始', () async {
    final controller = await ready();
    await controller.startRecording();
    await controller.stopRecording();
    await controller.startRecording();
    await controller.stopRecording();

    expect(current().takes, hasLength(2));
    final selected = current().takes.singleWhere((take) => take.isSelected);
    await controller.deleteTake(selected.id);

    expect(current().takes, hasLength(1));
    expect(current().takes.single.isSelected, isTrue);
    expect(current().phase, SentenceDubbingPhase.result);
    expect(current().result?.stars, 4.5);
    expect(current().completedSentenceCount, 1);

    await controller.deleteTake(current().takes.single.id);

    expect(current().takes, isEmpty);
    expect(current().phase, SentenceDubbingPhase.ready);
    expect(current().result, isNull);
    expect(current().completedSentenceCount, 0);
  });

  test('结果页一次点击进入下一句并自动开始示范和录音', () async {
    final controller = await ready();
    await controller.startRecording();
    await controller.stopRecording();

    await controller.continueAndStartNextSentence();

    expect(current().sentence.id, 's2');
    expect(current().phase, SentenceDubbingPhase.recording);
    expect(player.played, hasLength(2));
    await controller.stopRecording();
  });

  testWidgets('逐句儿童流程适配窄屏和 Android 平板横屏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SentenceDubbingPage(libraryId: 'book-copy'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开始这一句'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1024, 600);
    await tester.pumpAndSettle();

    expect(find.text('开始这一句'), findsOneWidget);
    expect(find.text('下一句'), findsOneWidget);
    expect(tester.getBottomRight(find.text('下一句')).dy, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
  });
}

OriginalAudioBook _book() => OriginalAudioBook(
      libraryId: 'book-copy',
      audioPath: 'original.ogg',
      duration: const Duration(seconds: 2),
      sourceBookId: 'source-book',
      resourceSha256: 'a' * 64,
      timelineSha256: 'b' * 64,
      sentences: [
        OriginalAudioSentence(
          id: 's1',
          sequence: 1,
          text: 'Hello.',
          start: Duration.zero,
          end: const Duration(milliseconds: 800),
          words: const [
            OriginalAudioWord(
              sequence: 1,
              text: 'Hello',
              start: Duration.zero,
              end: Duration(milliseconds: 800),
            ),
          ],
        ),
        OriginalAudioSentence(
          id: 's2',
          sequence: 2,
          text: 'Goodbye.',
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
          words: const [
            OriginalAudioWord(
              sequence: 1,
              text: 'Goodbye',
              start: Duration(seconds: 1),
              end: Duration(seconds: 2),
            ),
          ],
        ),
      ],
    );

final class _ImmediatePreparation implements RecordingPreparationProtocol {
  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    onUpdate(const RecordingPreparationUpdate.countdown(1));
    return Duration.zero;
  }
}

final class _Recorder implements AudioRecordingService {
  _Recorder(this.directory, this.events);
  final Directory directory;
  final List<String> events;
  late String path;

  @override
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  }) async {
    events.add('recorder.start');
    path = p.join(directory.path, 'capture.wav');
    await File(path).writeAsBytes(_wav());
    return RecordingSession(path: path, levels: const Stream.empty());
  }

  @override
  Future<String> stop() async => path;
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}

final class _Player implements SentenceAudioPlayer {
  _Player(this.events);

  final List<String> events;
  final played = <SentenceAudioClip>[];

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) async {
    events.add('player.play');
    played.add(clip);
    onPosition?.call(Duration.zero);
    onPosition?.call(clip.end - clip.start);
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

final class _Scorer implements ScoringProvider {
  @override
  String get name => 'fake';
  @override
  Future<bool> isConfigured() async => true;
  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async =>
      const ScoreResult(childScore: 90, provider: 'fake');
}

final class _Repository implements DubbingRepository {
  _Repository(this.directory);
  final Directory directory;
  final projects = <DubbingProject>[];
  final takes = <DubbingTake>[];

  @override
  Future<DubbingProject> createProject(DubbingProjectDraft draft) async {
    final project = DubbingProject(
      id: 'project',
      libraryId: draft.libraryId,
      sourceBookId: draft.sourceBookId,
      resourceSha256: draft.resourceSha256,
      timelineSha256: draft.timelineSha256,
      mode: draft.mode,
      status: DubbingProjectStatus.draft,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    projects.add(project);
    return project;
  }

  @override
  Future<List<DubbingProject>> listProjects(String libraryId) async => projects;
  @override
  Future<DubbingProject?> findProject(String projectId) async => projects.first;
  @override
  Future<List<DubbingTake>> listTakes(String projectId,
          {String? sentenceId}) async =>
      takes
          .where((take) => sentenceId == null || take.sentenceId == sentenceId)
          .toList(growable: false);

  @override
  Future<DubbingTake> saveTake({
    required String projectId,
    required DubbingTakeKind kind,
    required File sourceAudio,
    required Duration duration,
    Duration contentOffset = Duration.zero,
    String? sentenceId,
  }) async {
    final path = p.join(directory.path, 'durable-${takes.length + 1}.wav');
    await sourceAudio.copy(path);
    final take = DubbingTake(
      id: 'take-${takes.length + 1}',
      projectId: projectId,
      sentenceId: sentenceId,
      takeKind: kind,
      audioRelativePath: p.basename(path),
      duration: duration,
      contentOffset: contentOffset,
      isSelected: false,
      scoreStatus: DubbingTakeScoreStatus.pending,
      createdAt: DateTime.utc(2026),
    );
    takes.add(take);
    return take;
  }

  @override
  Future<void> selectTake(String takeId) async {
    for (var index = 0; index < takes.length; index++) {
      final old = takes[index];
      if (old.sentenceId !=
          takes.firstWhere((take) => take.id == takeId).sentenceId) {
        continue;
      }
      takes[index] = _copyTake(old, selected: old.id == takeId);
    }
  }

  @override
  Future<void> updateTakeScore({
    required String takeId,
    required DubbingTakeScoreStatus status,
    String? scoreJson,
    String? scoreError,
  }) async {
    final index = takes.indexWhere((take) => take.id == takeId);
    takes[index] = _copyTake(
      takes[index],
      scoreStatus: status,
      scoreJson: scoreJson,
      scoreError: scoreError,
    );
  }

  @override
  String resolveAudioPath(DubbingTake take) =>
      p.join(directory.path, take.audioRelativePath);
  @override
  Future<void> deleteTake(String takeId) async =>
      takes.removeWhere((take) => take.id == takeId);
  @override
  Future<void> deleteProject(String projectId) async {}
  @override
  Future<void> updateProjectStatus(
      String projectId, DubbingProjectStatus status) async {}
  @override
  Future<List<DubbingMix>> listMixes(String projectId) async => const [];
  @override
  Future<DubbingMixOutput> prepareMixOutput(String projectId,
          {String extension = '.m4a'}) =>
      throw UnimplementedError();
  @override
  Future<DubbingMix> saveMix({
    required DubbingMixOutput output,
    required DubbingMixVariant variant,
    required String sourceTakeFingerprint,
    required Duration duration,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> deleteMix(String mixId) async {}
  @override
  String resolveMixAudioPath(DubbingMix mix) => '';
}

DubbingTake _copyTake(
  DubbingTake value, {
  bool? selected,
  DubbingTakeScoreStatus? scoreStatus,
  String? scoreJson,
  String? scoreError,
}) =>
    DubbingTake(
      id: value.id,
      projectId: value.projectId,
      sentenceId: value.sentenceId,
      takeKind: value.takeKind,
      audioRelativePath: value.audioRelativePath,
      duration: value.duration,
      contentOffset: value.contentOffset,
      isSelected: selected ?? value.isSelected,
      scoreStatus: scoreStatus ?? value.scoreStatus,
      scoreJson: scoreJson ?? value.scoreJson,
      scoreError: scoreError ?? value.scoreError,
      createdAt: value.createdAt,
    );

Uint8List _wav() {
  final pcm = Uint8List(3200);
  final bytes = Uint8List(44 + pcm.length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 16000, Endian.little);
  view.setUint32(28, 32000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}
