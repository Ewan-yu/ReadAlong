import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/features/dubbing/dubbing_file_store.dart';
import 'package:reader_app/features/dubbing/dubbing_repository.dart';

void main() {
  late Directory tempDir;
  late Directory documents;
  late ShelfIndex shelfIndex;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('readalong_dubbing_test_');
    documents = await Directory(p.join(tempDir.path, 'documents')).create();
    shelfIndex = ShelfIndex(
      databasePath: p.join(documents.path, 'app.db'),
      databaseFactory: databaseFactoryFfi,
    );
    await shelfIndex.add(
      ShelfBook(
        libraryId: 'story-copy-1',
        sourceBookId: 'story-source',
        title: 'Story',
        pageCount: 2,
        bookDir: p.join(documents.path, 'books', 'story-copy-1'),
        thumbnailPath: 'thumbnails/p0001.jpg',
        packageSha256: 'resource-sha',
        importedAt: DateTime.utc(2026, 7, 24),
      ),
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LocalDubbingRepository repositoryWithIds(Iterable<String> ids) {
    final sequence = Queue<String>.of(ids);
    return LocalDubbingRepository(
      shelfIndex: shelfIndex,
      fileStore: DubbingFileStore(documentsDirectory: documents),
      idGenerator: () => sequence.removeFirst(),
    );
  }

  Future<DubbingProject> createSentenceProject(
    LocalDubbingRepository repository,
  ) =>
      repository.createProject(
        const DubbingProjectDraft(
          libraryId: 'story-copy-1',
          sourceBookId: 'story-source',
          resourceSha256: 'resource-sha',
          timelineSha256: 'timeline-sha',
          mode: DubbingMode.sentence,
        ),
      );

  Future<File> recording(String name) async {
    final file = File(p.join(tempDir.path, 'recordings', '$name.wav'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3, name.length]);
    return file;
  }

  test('现有 v3 app.db 升级后保留书架并创建配音与作品表', () async {
    final databaseFile = File(p.join(documents.path, 'app.db'));
    await databaseFile.delete();
    final legacy = await databaseFactoryFfi.openDatabase(
      databaseFile.path,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE shelf_book (
              book_id TEXT PRIMARY KEY,
              source_book_id TEXT NOT NULL,
              title TEXT NOT NULL,
              page_count INTEGER NOT NULL,
              book_dir TEXT NOT NULL,
              thumbnail_path TEXT NOT NULL,
              package_sha256 TEXT NOT NULL,
              imported_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE reading_progress (
              library_id TEXT PRIMARY KEY,
              current_page INTEGER NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE record (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              library_id TEXT NOT NULL,
              sentence_id TEXT NOT NULL,
              reference_text TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              status TEXT NOT NULL,
              child_score REAL,
              detail_json TEXT,
              provider TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.insert('shelf_book', {
      'book_id': 'legacy-copy',
      'source_book_id': 'legacy-source',
      'title': 'Legacy',
      'page_count': 1,
      'book_dir': '/books/legacy-copy',
      'thumbnail_path': 'cover.jpg',
      'package_sha256': 'hash',
      'imported_at': '2026-07-24T00:00:00.000Z',
    });
    await legacy.close();

    expect((await shelfIndex.findByLibraryId('legacy-copy'))!.title, 'Legacy');
    final upgraded = await databaseFactoryFfi.openDatabase(databaseFile.path);
    final tableRows = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('dubbing_mix', 'dubbing_project', 'dubbing_take') ORDER BY name",
    );
    await upgraded.close();

    expect(tableRows.map((row) => row['name']),
        ['dubbing_mix', 'dubbing_project', 'dubbing_take']);
  });

  test('现有 v5 Take 升级后内容零点偏移默认为零', () async {
    final databaseFile = File(p.join(documents.path, 'app.db'));
    await databaseFile.delete();
    final legacy = await databaseFactoryFfi.openDatabase(
      databaseFile.path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE dubbing_take (
              id TEXT PRIMARY KEY,
              project_id TEXT NOT NULL,
              sentence_id TEXT,
              take_kind TEXT NOT NULL,
              audio_path TEXT NOT NULL,
              duration_ms INTEGER NOT NULL,
              selected INTEGER NOT NULL,
              score_status TEXT NOT NULL,
              score_json TEXT,
              score_error TEXT,
              created_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.insert('dubbing_take', {
      'id': 'legacy-take',
      'project_id': 'legacy-project',
      'sentence_id': 's1',
      'take_kind': 'sentence',
      'audio_path': 'dubbing/book/project/take.wav',
      'duration_ms': 800,
      'selected': 1,
      'score_status': 'pending',
      'created_at': DateTime.utc(2026).toIso8601String(),
    });
    await legacy.close();

    final upgraded = await shelfIndex.findDubbingTake('legacy-take');

    expect(upgraded, isNotNull);
    expect(upgraded!.contentOffset, Duration.zero);
  });

  test('逐句 Take 以相对路径原子持久化到 App 私有目录', () async {
    final repository = repositoryWithIds(['project-1', 'take-1']);
    final project = await createSentenceProject(repository);

    final take = await repository.saveTake(
      projectId: project.id,
      kind: DubbingTakeKind.sentence,
      sentenceId: 's0001',
      sourceAudio: await recording('first'),
      duration: const Duration(milliseconds: 860),
    );

    expect(
      take.audioRelativePath,
      'dubbing/story-copy-1/project-1/takes/s0001/take-1.wav',
    );
    expect(p.isAbsolute(take.audioRelativePath), isFalse);
    expect(await File(repository.resolveAudioPath(take)).readAsBytes(),
        [1, 2, 3, 5]);
    expect(
      await Directory(p.join(
              documents.path, 'dubbing', 'story-copy-1', 'project-1', '.tmp'))
          .list()
          .toList(),
      isEmpty,
    );
  });

  test('每句最多三条 Take，第四条不会留下文件或数据库行', () async {
    final repository = repositoryWithIds([
      'project-1',
      'take-1',
      'take-2',
      'take-3',
      'take-4',
    ]);
    final project = await createSentenceProject(repository);
    for (var i = 1; i <= ShelfIndex.maxSentenceTakes; i++) {
      await repository.saveTake(
        projectId: project.id,
        kind: DubbingTakeKind.sentence,
        sentenceId: 's0001',
        sourceAudio: await recording('take-$i'),
        duration: const Duration(milliseconds: 800),
      );
    }

    await expectLater(
      repository.saveTake(
        projectId: project.id,
        kind: DubbingTakeKind.sentence,
        sentenceId: 's0001',
        sourceAudio: await recording('take-4'),
        duration: const Duration(milliseconds: 800),
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      await repository.listTakes(project.id, sentenceId: 's0001'),
      hasLength(ShelfIndex.maxSentenceTakes),
    );
    expect(
      await File(
        p.join(
          documents.path,
          'dubbing',
          'story-copy-1',
          'project-1',
          'takes',
          's0001',
          'take-4.wav',
        ),
      ).exists(),
      isFalse,
    );
  });

  test('选用 Take 在同一项目和句子内保持唯一', () async {
    final repository = repositoryWithIds(['project-1', 'take-1', 'take-2']);
    final project = await createSentenceProject(repository);
    final first = await repository.saveTake(
      projectId: project.id,
      kind: DubbingTakeKind.sentence,
      sentenceId: 's0001',
      sourceAudio: await recording('first'),
      duration: const Duration(milliseconds: 800),
    );
    final second = await repository.saveTake(
      projectId: project.id,
      kind: DubbingTakeKind.sentence,
      sentenceId: 's0001',
      sourceAudio: await recording('second'),
      duration: const Duration(milliseconds: 800),
    );

    await repository.selectTake(first.id);
    await repository.selectTake(second.id);

    final takes = await repository.listTakes(project.id, sentenceId: 's0001');
    expect(takes.where((take) => take.isSelected).map((take) => take.id),
        [second.id]);
  });

  test('统一管理删除当前版本后自动选用最新剩余录音', () async {
    final repository = repositoryWithIds(['project-1', 'take-1', 'take-2']);
    final project = await createSentenceProject(repository);
    final first = await repository.saveTake(
      projectId: project.id,
      kind: DubbingTakeKind.sentence,
      sentenceId: 's0001',
      sourceAudio: await recording('first'),
      duration: const Duration(milliseconds: 800),
    );
    final second = await repository.saveTake(
      projectId: project.id,
      kind: DubbingTakeKind.sentence,
      sentenceId: 's0001',
      sourceAudio: await recording('second'),
      duration: const Duration(milliseconds: 900),
    );
    await repository.selectTake(second.id);

    await repository.deleteTake(second.id);

    final remaining = await repository.listTakes(
      project.id,
      sentenceId: 's0001',
    );
    expect(remaining.single.id, first.id);
    expect(remaining.single.isSelected, isTrue);
    expect(File(repository.resolveAudioPath(second)).existsSync(), isFalse);
  });

  test('项目模式、录音类型和私有相对路径严格匹配', () async {
    final repository = repositoryWithIds(['project-1', 'take-1']);
    final project = await createSentenceProject(repository);

    await expectLater(
      repository.saveTake(
        projectId: project.id,
        kind: DubbingTakeKind.full,
        sourceAudio: await recording('full'),
        duration: const Duration(milliseconds: 800),
      ),
      throwsA(isA<StateError>()),
    );
    expect(
      () => shelfIndex.createDubbingTake(
        id: 'bad-take',
        projectId: project.id,
        takeKind: DubbingTakeKind.sentence,
        sentenceId: 's0001',
        audioRelativePath: r'C:\outside.wav',
        duration: const Duration(milliseconds: 800),
      ),
      throwsArgumentError,
    );
  });
}
