import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/features/dubbing/dubbing_repository.dart';
import 'package:reader_app/features/dubbing/full_dubbing_controller.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';
import 'package:reader_app/services/recording/recording_service.dart';

void main() {
  late Directory temporary;
  late _MemoryDubbingRepository repository;
  late ProviderContainer container;
  ProviderSubscription<AsyncValue<FullDubbingState>>? subscription;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('full_dubbing_test_');
    repository = _MemoryDubbingRepository(temporary);
    container = ProviderContainer(overrides: [
      dubbingRepositoryProvider.overrideWith((_) async => repository),
      recordingServiceProvider.overrideWith((_) async => _Recorder(temporary)),
      sentenceAudioPlayerProvider.overrideWithValue(_Player()),
      originalAudioBookProvider('book-copy').overrideWith((_) async => _book()),
    ]);
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await temporary.delete(recursive: true);
  });

  Future<FullDubbingController> ready() async {
    subscription = container.listen(
        fullDubbingControllerProvider('book-copy'), (_, __) {},
        fireImmediately: true);
    await container.read(fullDubbingControllerProvider('book-copy').future);
    return container.read(fullDubbingControllerProvider('book-copy').notifier);
  }

  FullDubbingState current() =>
      container.read(fullDubbingControllerProvider('book-copy')).requireValue;

  test('完整配音创建独立 full 项目，并可保存草稿状态', () async {
    final controller = await ready();

    expect(current().project.mode, DubbingMode.full);
    expect(current().project.status, DubbingProjectStatus.draft);
    await controller.saveDraft();

    expect(repository.statuses, [DubbingProjectStatus.draft]);
  });

  test('三秒倒计时可取消，未触发录音', () async {
    final controller = await ready();

    await controller.startCountdown();
    expect(current().phase, FullDubbingPhase.countdown);
    expect(current().countdown, 3);
    await controller.cancelCountdown();

    expect(current().phase, FullDubbingPhase.ready);
    expect(current().countdown, 0);
  });
}

OriginalAudioBook _book() => OriginalAudioBook(
      libraryId: 'book-copy',
      audioPath: 'original.mp3',
      duration: const Duration(minutes: 1),
      sourceBookId: 'source-book',
      resourceSha256: 'a' * 64,
      timelineSha256: 'b' * 64,
      sentences: [
        OriginalAudioSentence(
            id: 's1',
            sequence: 1,
            text: 'Hello.',
            start: Duration.zero,
            end: const Duration(seconds: 1),
            words: [
              const OriginalAudioWord(
                  sequence: 1,
                  text: 'Hello',
                  start: Duration.zero,
                  end: Duration(seconds: 1))
            ])
      ],
    );

final class _Recorder implements AudioRecordingService {
  _Recorder(this.directory);
  final Directory directory;
  @override
  Future<RecordingSession> start(
          {required String libraryId, required String sentenceId}) async =>
      RecordingSession(
          path: p.join(directory.path, 'temporary.wav'),
          levels: const Stream.empty());
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<String> stop() async => p.join(directory.path, 'temporary.wav');
}

final class _Player implements SentenceAudioPlayer {
  @override
  Future<void> dispose() async {}
  @override
  Future<void> play(SentenceAudioClip clip,
      {void Function(Duration elapsed)? onPosition}) async {}
  @override
  Future<void> stop() async {}
}

final class _MemoryDubbingRepository implements DubbingRepository {
  _MemoryDubbingRepository(this.directory);
  final Directory directory;
  final projects = <DubbingProject>[];
  final takes = <DubbingTake>[];
  final statuses = <DubbingProjectStatus>[];

  @override
  Future<DubbingProject> createProject(DubbingProjectDraft draft) async {
    final project = DubbingProject(
        id: 'full-project',
        libraryId: draft.libraryId,
        sourceBookId: draft.sourceBookId,
        resourceSha256: draft.resourceSha256,
        timelineSha256: draft.timelineSha256,
        mode: draft.mode,
        status: DubbingProjectStatus.draft,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026));
    projects.add(project);
    return project;
  }

  @override
  Future<void> deleteProject(String projectId) async {}
  @override
  Future<void> deleteTake(String takeId) async {}
  @override
  Future<DubbingProject?> findProject(String projectId) async =>
      projects.where((value) => value.id == projectId).firstOrNull;
  @override
  Future<List<DubbingProject>> listProjects(String libraryId) async => projects;
  @override
  Future<List<DubbingTake>> listTakes(String projectId,
          {String? sentenceId}) async =>
      takes;
  @override
  String resolveAudioPath(DubbingTake take) =>
      p.join(directory.path, take.audioRelativePath);
  @override
  Future<DubbingTake> saveTake(
          {required String projectId,
          required DubbingTakeKind kind,
          required File sourceAudio,
          required Duration duration,
          String? sentenceId}) =>
      throw UnimplementedError();
  @override
  Future<void> selectTake(String takeId) async {}
  @override
  Future<void> updateProjectStatus(
      String projectId, DubbingProjectStatus status) async {
    statuses.add(status);
    final index = projects.indexWhere((value) => value.id == projectId);
    final old = projects[index];
    projects[index] = DubbingProject(
        id: old.id,
        libraryId: old.libraryId,
        sourceBookId: old.sourceBookId,
        resourceSha256: old.resourceSha256,
        timelineSha256: old.timelineSha256,
        mode: old.mode,
        status: status,
        createdAt: old.createdAt,
        updatedAt: DateTime.utc(2026, 1, 2));
  }

  @override
  Future<void> updateTakeScore(
      {required String takeId,
      required DubbingTakeScoreStatus status,
      String? scoreJson,
      String? scoreError}) async {}
}
