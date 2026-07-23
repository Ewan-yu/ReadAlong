import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Directory bookDir;
  late ShelfIndex shelfIndex;
  late LocalOriginalAudioRepository repository;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('original_audio_repository_');
    bookDir = await Directory(p.join(tempDir.path, 'book')).create();
    shelfIndex = ShelfIndex(
      databasePath: p.join(tempDir.path, 'app.db'),
      databaseFactory: databaseFactoryFfi,
    );
    await shelfIndex.add(
      ShelfBook(
        libraryId: 'copy-1',
        sourceBookId: 'story-1',
        title: 'Moon Story',
        pageCount: 1,
        bookDir: bookDir.path,
        thumbnailPath: 'thumbnails/p0001.jpg',
        packageSha256: 'package-hash',
        importedAt: DateTime.utc(2026, 7, 23),
      ),
    );
    repository = LocalOriginalAudioRepository(
      shelfIndex: shelfIndex,
      databaseFactory: databaseFactoryFfi,
    );
    await _writeAlignment(bookDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('ready 时间轴必须同时通过音频、JSON 和 alignment 身份门禁', () async {
    await _writeReadyPackage(bookDir);

    final book = await repository.loadBook('copy-1');

    expect(book.audioPath, p.join(bookDir.path, 'original', 'source.mp3'));
    expect(book.duration, const Duration(seconds: 4));
    expect(book.sentences.single.id, 's0001');
    expect(book.sentences.single.start, const Duration(milliseconds: 200));
    expect(book.sentences.single.words.last.end, const Duration(seconds: 2));
  });

  test('raw 原音不暴露为可播放歌词能力', () async {
    await File(p.join(bookDir.path, 'manifest.json')).writeAsString(jsonEncode({
      'book_id': 'story-1',
      'original_audio': {'alignment_status': 'raw'},
    }));

    expect(
      () => repository.loadBook('copy-1'),
      throwsA(isA<OriginalAudioUnavailableException>()),
    );
  });

  test('timeline 文件哈希不一致时拒绝入口', () async {
    await _writeReadyPackage(bookDir, timelineHash: '0' * 64);

    expect(
      () => repository.loadBook('copy-1'),
      throwsA(isA<OriginalAudioDataException>()),
    );
  });
}

Future<void> _writeAlignment(Directory bookDir) async {
  final file = File(p.join(bookDir.path, 'align', 'alignment.db'));
  await file.parent.create(recursive: true);
  final db = await databaseFactoryFfi.openDatabase(file.path);
  try {
    await db.execute('CREATE TABLE book (id TEXT NOT NULL)');
    await db.execute(
      'CREATE TABLE sentence (id TEXT, page_no INTEGER, seq INTEGER, text TEXT)',
    );
    await db.insert('book', {'id': 'story-1'});
    await db.insert('sentence', {
      'id': 's0001',
      'page_no': 1,
      'seq': 1,
      'text': 'Good night.',
    });
  } finally {
    await db.close();
  }
}

Future<void> _writeReadyPackage(
  Directory bookDir, {
  String? timelineHash,
}) async {
  final audio = File(p.join(bookDir.path, 'original', 'source.mp3'));
  await audio.parent.create(recursive: true);
  await audio.writeAsBytes([1, 2, 3, 4]);
  const audioHash =
      '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';
  final timeline = {
    'schema_version': 1,
    'source': {
      'proofread_revision': 'r-12345678',
      'original_audio_revision': 'r-12345678',
      'original_audio_sha256': audioHash,
      'vocal_path': 'preview/vocals.ogg',
      'vocal_sha256': '1' * 64,
    },
    'sentences': [
      {
        'sentence_id': 's0001',
        'page_no': 1,
        'seq': 1,
        'text': 'Good night.',
        'start_ms': 200,
        'end_ms': 2000,
        'words': [
          {'seq': 1, 'text': 'Good', 'start_ms': 200, 'end_ms': 1000},
          {'seq': 2, 'text': 'night.', 'start_ms': 1000, 'end_ms': 2000},
        ],
      },
    ],
  };
  final timelineBytes = utf8.encode(jsonEncode(timeline));
  final timelineFile =
      File(p.join(bookDir.path, 'timeline', 'original_timeline.json'));
  await timelineFile.parent.create(recursive: true);
  await timelineFile.writeAsBytes(timelineBytes);
  await File(p.join(bookDir.path, 'manifest.json')).writeAsString(jsonEncode({
    'book_id': 'story-1',
    'original_audio': {
      'path': 'original/source.mp3',
      'duration_ms': 4000,
      'sha256': audioHash,
      'alignment_status': 'ready',
      'timeline_path': 'timeline/original_timeline.json',
      'timeline_sha256':
          timelineHash ?? sha256.convert(timelineBytes).toString(),
      'timeline_sentence_count': 1,
      'vocal_sha256': '1' * 64,
    },
  }));
}
