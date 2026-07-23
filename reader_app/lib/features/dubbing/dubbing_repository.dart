import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/dubbing_models.dart';
import '../../data/appdb/shelf_index.dart';
import 'dubbing_file_store.dart';

export '../../data/appdb/dubbing_models.dart';

final dubbingRepositoryProvider =
    FutureProvider<DubbingRepository>((ref) async {
  final documents = await ref.watch(appDocumentsDirectoryProvider.future);
  final shelfIndex = await ref.watch(shelfIndexProvider.future);
  return LocalDubbingRepository(
    shelfIndex: shelfIndex,
    fileStore: DubbingFileStore(documentsDirectory: documents),
  );
});

final class DubbingProjectDraft {
  const DubbingProjectDraft({
    required this.libraryId,
    required this.sourceBookId,
    required this.resourceSha256,
    required this.timelineSha256,
    required this.mode,
  });

  final String libraryId;
  final String sourceBookId;
  final String resourceSha256;
  final String timelineSha256;
  final DubbingMode mode;
}

abstract interface class DubbingRepository {
  Future<DubbingProject> createProject(DubbingProjectDraft draft);
  Future<DubbingProject?> findProject(String projectId);
  Future<List<DubbingProject>> listProjects(String libraryId);
  Future<void> updateProjectStatus(
      String projectId, DubbingProjectStatus status);
  Future<List<DubbingTake>> listTakes(String projectId, {String? sentenceId});
  Future<DubbingTake> saveTake({
    required String projectId,
    required DubbingTakeKind kind,
    required File sourceAudio,
    required Duration duration,
    String? sentenceId,
  });
  Future<void> selectTake(String takeId);
  Future<void> updateTakeScore({
    required String takeId,
    required DubbingTakeScoreStatus status,
    String? scoreJson,
    String? scoreError,
  });
  Future<void> deleteTake(String takeId);
  Future<void> deleteProject(String projectId);
  String resolveAudioPath(DubbingTake take);
}

/// Coordinates app-db rows and files without ever writing to an imported pack.
final class LocalDubbingRepository implements DubbingRepository {
  LocalDubbingRepository({
    required ShelfIndex shelfIndex,
    required DubbingFileStore fileStore,
    String Function()? idGenerator,
  })  : _shelfIndex = shelfIndex,
        _fileStore = fileStore,
        _idGenerator = idGenerator ?? _newId;

  final ShelfIndex _shelfIndex;
  final DubbingFileStore _fileStore;
  final String Function() _idGenerator;

  @override
  Future<DubbingProject> createProject(DubbingProjectDraft draft) async {
    final shelfBook = await _shelfIndex.findByLibraryId(draft.libraryId);
    if (shelfBook == null || shelfBook.sourceBookId != draft.sourceBookId) {
      throw StateError('绘本已不存在或来源不匹配');
    }
    return _shelfIndex.createDubbingProject(
      id: _idGenerator(),
      libraryId: draft.libraryId,
      sourceBookId: draft.sourceBookId,
      resourceSha256: draft.resourceSha256,
      timelineSha256: draft.timelineSha256,
      mode: draft.mode,
    );
  }

  @override
  Future<DubbingProject?> findProject(String projectId) =>
      _shelfIndex.findDubbingProject(projectId);

  @override
  Future<List<DubbingProject>> listProjects(String libraryId) =>
      _shelfIndex.listDubbingProjects(libraryId);

  @override
  Future<void> updateProjectStatus(
          String projectId, DubbingProjectStatus status) =>
      _shelfIndex.updateDubbingProjectStatus(projectId, status);

  @override
  Future<List<DubbingTake>> listTakes(String projectId, {String? sentenceId}) =>
      _shelfIndex.listDubbingTakes(projectId, sentenceId: sentenceId);

  @override
  Future<DubbingTake> saveTake({
    required String projectId,
    required DubbingTakeKind kind,
    required File sourceAudio,
    required Duration duration,
    String? sentenceId,
  }) async {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', '录音时长必须大于零');
    }
    final project = await _requireProject(projectId);
    if (project.mode == DubbingMode.sentence &&
            kind != DubbingTakeKind.sentence ||
        project.mode == DubbingMode.full && kind != DubbingTakeKind.full) {
      throw StateError('录音类型与项目模式不匹配');
    }
    final takeId = _idGenerator();
    String? relativePath;
    try {
      relativePath = await _fileStore.persistTake(
        source: sourceAudio,
        libraryId: project.libraryId,
        projectId: project.id,
        takeId: takeId,
        kind: kind,
        sentenceId: sentenceId,
      );
      return await _shelfIndex.createDubbingTake(
        id: takeId,
        projectId: project.id,
        sentenceId: sentenceId,
        takeKind: kind,
        audioRelativePath: relativePath,
        duration: duration,
      );
    } catch (_) {
      if (relativePath != null) {
        await _fileStore.deleteRelativeFile(relativePath);
      }
      rethrow;
    }
  }

  @override
  Future<void> selectTake(String takeId) =>
      _shelfIndex.selectDubbingTake(takeId);

  @override
  Future<void> updateTakeScore({
    required String takeId,
    required DubbingTakeScoreStatus status,
    String? scoreJson,
    String? scoreError,
  }) =>
      _shelfIndex.updateDubbingTakeScore(
        takeId: takeId,
        status: status,
        scoreJson: scoreJson,
        scoreError: scoreError,
      );

  @override
  Future<void> deleteTake(String takeId) async {
    final take = await _shelfIndex.findDubbingTake(takeId);
    if (take == null) return;
    await _shelfIndex.deleteDubbingTake(takeId);
    await _fileStore.deleteRelativeFile(take.audioRelativePath);
  }

  @override
  Future<void> deleteProject(String projectId) async {
    final project = await _shelfIndex.findDubbingProject(projectId);
    if (project == null) return;
    await _shelfIndex.deleteDubbingProject(projectId);
    await _fileStore.deleteProject(
      libraryId: project.libraryId,
      projectId: project.id,
    );
  }

  @override
  String resolveAudioPath(DubbingTake take) =>
      _fileStore.resolveRelativePath(take.audioRelativePath);

  Future<DubbingProject> _requireProject(String id) async {
    final project = await _shelfIndex.findDubbingProject(id);
    if (project == null) throw StateError('配音项目不存在');
    return project;
  }
}

String _newId() {
  final random = Random.secure();
  final entropy = List<int>.generate(10, (_) => random.nextInt(256));
  final hex =
      entropy.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}-$hex';
}
