import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/app_database_providers.dart';
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/features/reader/alignment_repository.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';

class _RecordingPointReadingRepository implements PointReadingRepository {
  _RecordingPointReadingRepository(this.book);

  final PointReadingBook book;
  final requestedLibraryIds = <String>[];

  @override
  Future<PointReadingBook> loadBook(String libraryId) async {
    requestedLibraryIds.add(libraryId);
    return book;
  }
}

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Directory bookDir;
  late File alignmentFile;
  late ShelfIndex shelfIndex;
  late ShelfBook shelfBook;
  late LocalPointReadingRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('alignment_repository_');
    bookDir = await Directory(p.join(tempDir.path, 'books', 'copy-2'))
        .create(recursive: true);
    alignmentFile = File(p.join(bookDir.path, 'align', 'alignment.db'));
    await alignmentFile.parent.create(recursive: true);
    shelfIndex = ShelfIndex(
      databasePath: p.join(tempDir.path, 'app.db'),
      databaseFactory: databaseFactoryFfi,
    );
    shelfBook = ShelfBook(
      libraryId: 'copy-2',
      sourceBookId: 'source-book',
      title: 'Moon Story',
      pageCount: 2,
      bookDir: bookDir.path,
      thumbnailPath: 'thumbnails/p0001.jpg',
      packageSha256: 'sha256',
      importedAt: DateTime.utc(2026, 7, 13),
    );
    repository = LocalPointReadingRepository(
      shelfIndex: shelfIndex,
      databaseFactory: databaseFactoryFfi,
    );
    await shelfIndex.add(shelfBook);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Map<String, Object?> sentence({
    String id = 's0001',
    String bookId = 'source-book',
    int pageNumber = 1,
    int sequence = 1,
    String text = 'Good night.',
    Object? bbox,
    Object? sharedBbox = 0,
    Object? audioPath = 'tts/story.ogg',
    Object? start = 0.0,
    Object? end = 1.2,
  }) =>
      {
        'id': id,
        'book_id': bookId,
        'page_no': pageNumber,
        'seq': sequence,
        'text': text,
        'bbox_json': bbox ?? {'x': 0.1, 'y': 0.2, 'w': 0.3, 'h': 0.1},
        'shared_bbox': sharedBbox,
        'audio_path': audioPath,
        't_start': start,
        't_end': end,
      };

  Map<String, Object?> wordTiming({
    required String id,
    required String sentenceId,
    required int sequence,
    required String word,
    required double start,
    required double end,
  }) =>
      {
        'id': id,
        'sentence_id': sentenceId,
        'seq': sequence,
        'word': word,
        't_start': start,
        't_end': end,
      };

  Future<void> writeAlignment({
    String sourceBookId = 'source-book',
    List<Map<String, Object?>>? sentences,
    List<Map<String, Object?>>? wordTimings,
  }) async {
    final db = await databaseFactoryFfi.openDatabase(
      alignmentFile.path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await db.execute('''
        CREATE TABLE book (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          language TEXT NOT NULL,
          schema_version INTEGER NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE sentence (
          id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          page_no INTEGER NOT NULL,
          seq INTEGER NOT NULL,
          text TEXT NOT NULL,
          bbox_json TEXT NOT NULL,
          shared_bbox INTEGER NOT NULL,
          audio_path TEXT NOT NULL,
          t_start REAL NOT NULL,
          t_end REAL NOT NULL,
          audio_source TEXT NOT NULL
        )
      ''');
      if (wordTimings != null) {
        await db.execute('''
          CREATE TABLE word_timing (
            id TEXT PRIMARY KEY,
            sentence_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            word TEXT NOT NULL,
            t_start REAL NOT NULL,
            t_end REAL NOT NULL
          )
        ''');
      }
      await db.insert('book', {
        'id': sourceBookId,
        'title': 'Moon Story',
        'language': 'en',
        'schema_version': 1,
        'created_at': '2026-07-13T00:00:00Z',
      });
      for (final row in sentences ?? [sentence()]) {
        await db.insert('sentence', {
          ...row,
          'bbox_json': jsonEncode(row['bbox_json']),
          'audio_source': 'tts',
        });
      }
      for (final row in wordTimings ?? const <Map<String, Object?>>[]) {
        await db.insert('word_timing', row);
      }
    } finally {
      await db.close();
    }
  }

  test('只读加载、按 seq 分页排序且不依赖 word_timing 表', () async {
    await writeAlignment(sentences: [
      sentence(id: 's0003', pageNumber: 2, sequence: 3),
      sentence(id: 's0002', sequence: 2, text: 'Sleep tight.'),
      sentence(id: 's0001', sequence: 1),
    ]);
    final before = sha256.convert(await alignmentFile.readAsBytes());

    final book = await repository.loadBook(shelfBook.libraryId);

    final after = sha256.convert(await alignmentFile.readAsBytes());
    expect(after, before);
    expect(book.libraryId, shelfBook.libraryId);
    expect(book.sentencesByPage.keys, [1, 2]);
    expect(
      book.sentencesByPage[1]!.map((item) => item.id),
      ['s0001', 's0002'],
    );
    final first = book.sentencesByPage[1]!.first;
    expect(first.text, 'Good night.');
    expect(first.bbox,
        const NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1));
    expect(first.audio.path, p.join(bookDir.path, 'tts', 'story.ogg'));
    expect(first.audio.start, Duration.zero);
    expect(first.audio.end, const Duration(milliseconds: 1200));
  });

  test('alignment book.id 与 sourceBookId 不一致时拒绝加载', () async {
    await writeAlignment(sourceBookId: 'different-source', sentences: const []);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<PointReadingLoadException>()),
    );
  });

  test('未知 libraryId 返回点读加载异常', () async {
    expect(
      () => repository.loadBook('missing-copy'),
      throwsA(isA<PointReadingLoadException>()),
    );
  });

  test('缺失 alignment.db 返回点读加载异常', () async {
    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<PointReadingLoadException>()),
    );
  });

  test('bbox 越界、非有限值或字段类型错误时拒绝整本索引', () async {
    for (final invalid in [
      {'x': 0.9, 'y': 0.2, 'w': 0.2, 'h': 0.1},
      {'x': '0.1', 'y': 0.2, 'w': 0.3, 'h': 0.1},
    ]) {
      if (alignmentFile.existsSync()) await alignmentFile.delete();
      await writeAlignment(sentences: [sentence(bbox: invalid)]);

      expect(
        () => repository.loadBook(shelfBook.libraryId),
        throwsA(isA<PointReadingLoadException>()),
      );
    }
  });

  test('非法时间区间和 shared_bbox 值被拒绝', () async {
    await writeAlignment(sentences: [
      sentence(start: 1.0, end: 1.0, sharedBbox: 2),
    ]);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<PointReadingLoadException>()),
    );
  });

  test('重复全书 seq 被拒绝', () async {
    await writeAlignment(sentences: [
      sentence(id: 's0001', sequence: 1),
      sentence(id: 's0002', sequence: 1),
    ]);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<PointReadingLoadException>()),
    );
  });

  test('绝对音频路径和目录逃逸被拒绝', () async {
    for (final invalidPath in ['../outside.ogg', p.absolute('outside.ogg')]) {
      if (alignmentFile.existsSync()) await alignmentFile.delete();
      await writeAlignment(sentences: [sentence(audioPath: invalidPath)]);

      expect(
        () => repository.loadBook(shelfBook.libraryId),
        throwsA(isA<PointReadingLoadException>()),
      );
    }
  });

  test('单句音频缺失不阻止加载其他点读数据', () async {
    await writeAlignment();

    final book = await repository.loadBook(shelfBook.libraryId);

    expect(book.sentencesByPage[1], hasLength(1));
    expect(
        File(book.sentencesByPage[1]!.single.audio.path).existsSync(), isFalse);
  });

  test('合法 word_timing 按 seq 解析为不可变绝对时间列表', () async {
    await writeAlignment(
      sentences: [
        sentence(text: 'Good night.', start: 0.5, end: 2.0),
      ],
      wordTimings: [
        wordTiming(
          id: 'w2',
          sentenceId: 's0001',
          sequence: 2,
          word: 'night.',
          start: 1.1,
          end: 2.0,
        ),
        wordTiming(
          id: 'w1',
          sentenceId: 's0001',
          sequence: 1,
          word: 'Good',
          start: 0.5,
          end: 1.0,
        ),
      ],
    );

    final loaded = await repository.loadBook(shelfBook.libraryId);
    final timings = loaded.sentencesByPage[1]!.single.wordTimings;

    expect(timings.map((timing) => timing.word), ['Good', 'night.']);
    expect(timings.first.start, const Duration(milliseconds: 500));
    expect(timings.last.end, const Duration(seconds: 2));
    expect(() => timings.add(timings.first), throwsUnsupportedError);
  });

  test('非法词时间只降级对应句且保留其他句点读和词高亮', () async {
    await writeAlignment(
      sentences: [
        sentence(text: 'Good night.'),
        sentence(id: 's0002', sequence: 2, text: 'Sleep tight.'),
      ],
      wordTimings: [
        wordTiming(
          id: 'bad-1',
          sentenceId: 's0001',
          sequence: 1,
          word: 'Wrong',
          start: 0,
          end: 0.6,
        ),
        wordTiming(
          id: 'bad-2',
          sentenceId: 's0001',
          sequence: 2,
          word: 'night.',
          start: 0.5,
          end: 1.2,
        ),
        wordTiming(
          id: 'good-1',
          sentenceId: 's0002',
          sequence: 1,
          word: 'Sleep',
          start: 0,
          end: 0.5,
        ),
        wordTiming(
          id: 'good-2',
          sentenceId: 's0002',
          sequence: 2,
          word: 'tight.',
          start: 0.5,
          end: 1.2,
        ),
      ],
    );

    final loaded = await repository.loadBook(shelfBook.libraryId);

    expect(loaded.sentencesByPage[1]![0].wordTimings, isEmpty);
    expect(
      loaded.sentencesByPage[1]![1].wordTimings.map((timing) => timing.word),
      ['Sleep', 'tight.'],
    );
  });

  test('孤儿 timing 行被忽略且不影响合法句子', () async {
    await writeAlignment(
      wordTimings: [
        wordTiming(
          id: 'orphan',
          sentenceId: 'missing',
          sequence: 1,
          word: 'Ghost',
          start: 0,
          end: 0.5,
        ),
      ],
    );

    final loaded = await repository.loadBook(shelfBook.libraryId);

    expect(loaded.sentencesByPage[1]!.single.wordTimings, isEmpty);
  });

  test('pointReadingBookProvider 转发精确 libraryId', () async {
    final expected = PointReadingBook(
      libraryId: 'copy-2',
      sentences: const [],
    );
    final fake = _RecordingPointReadingRepository(expected);
    final container = ProviderContainer(
      overrides: [
        pointReadingRepositoryProvider.overrideWith((_) async => fake),
        appDatabaseFactoryProvider.overrideWithValue(databaseFactoryFfi),
      ],
    );
    addTearDown(container.dispose);

    final loaded =
        await container.read(pointReadingBookProvider('copy-2').future);

    expect(loaded, same(expected));
    expect(fake.requestedLibraryIds, ['copy-2']);
  });
}
