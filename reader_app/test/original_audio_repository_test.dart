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

  test('拒绝结构合法但首词只有 10ms 的不可用逐句时间轴', () async {
    await _writeReadyPackage(bookDir, unreliableTiming: true);

    expect(
      () => repository.loadBook('copy-1'),
      throwsA(isA<OriginalAudioDataException>()),
    );
  });

  test('排版撇号文本与 ASCII 时间线词视为一致，不再误拒导入', () async {
    const sentenceText = '“Don’t worry,” said Frog.';
    await _writeAlignment(bookDir, sentenceText: sentenceText);
    await _writeReadyPackage(
      bookDir,
      sentenceText: sentenceText,
      wordTexts: const ["don't", 'worry', 'said', 'frog'],
    );

    final book = await repository.loadBook('copy-1');

    expect(book.sentences.single.text, sentenceText);
    expect(book.sentences.single.words, hasLength(4));
    expect(book.sentences.single.words.first.text, "don't");
  });

  test('优先使用已校验的兼容 Ogg 播放轨', () async {
    await _writeReadyPackage(bookDir, includePlayback: true);

    final book = await repository.loadBook('copy-1');

    expect(book.audioPath, p.join(bookDir.path, 'original', 'playback.ogg'));
    expect(book.playbackPath, book.audioPath);
  });

  test('只朗读部分绘本文本时，仅将已朗读句作为独立歌词加载', () async {
    await _writeAlignment(bookDir, includeVisualOnlyLine: true);
    await _writeReadyPackage(bookDir, narratedSentenceSequence: 2);

    final book = await repository.loadBook('copy-1');

    expect(book.sentences, hasLength(1));
    expect(book.sentences.single.id, 's0002');
    expect(book.sentences.single.text, 'Good night.');
  });
}

Future<void> _writeAlignment(
  Directory bookDir, {
  bool includeVisualOnlyLine = false,
  String sentenceText = 'Good night.',
}) async {
  final file = File(p.join(bookDir.path, 'align', 'alignment.db'));
  await file.parent.create(recursive: true);
  final db = await databaseFactoryFfi.openDatabase(file.path);
  try {
    await db.execute('CREATE TABLE IF NOT EXISTS book (id TEXT NOT NULL)');
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sentence (id TEXT, page_no INTEGER, seq INTEGER, text TEXT)',
    );
    await db.execute('DELETE FROM book');
    await db.execute('DELETE FROM sentence');
    await db.insert('book', {'id': 'story-1'});
    if (includeVisualOnlyLine) {
      await db.insert('sentence', {
        'id': 's0001',
        'page_no': 1,
        'seq': 1,
        'text': 'Written by Someone.',
      });
    }
    await db.insert('sentence', {
      'id': includeVisualOnlyLine ? 's0002' : 's0001',
      'page_no': 1,
      'seq': includeVisualOnlyLine ? 2 : 1,
      'text': sentenceText,
    });
  } finally {
    await db.close();
  }
}

Future<void> _writeReadyPackage(
  Directory bookDir, {
  String? timelineHash,
  int narratedSentenceSequence = 1,
  bool includePlayback = false,
  bool unreliableTiming = false,
  String sentenceText = 'Good night.',
  List<String>? wordTexts,
}) async {
  final audio = File(p.join(bookDir.path, 'original', 'source.mp3'));
  await audio.parent.create(recursive: true);
  await audio.writeAsBytes([1, 2, 3, 4]);
  const audioHash =
      '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';
  final words = (wordTexts ?? const ['Good', 'night.'])
      .map((text) => {'text': text})
      .toList(growable: false);
  final sentenceStart = unreliableTiming ? 210 : 200;
  final span = (2000 - sentenceStart) ~/ words.length;
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
        'sentence_id': narratedSentenceSequence == 2 ? 's0002' : 's0001',
        'page_no': 1,
        'seq': narratedSentenceSequence,
        'text': sentenceText,
        'start_ms': sentenceStart,
        'end_ms': 2000,
        'words': [
          for (var index = 0; index < words.length; index++)
            {
              'seq': index + 1,
              'text': words[index]['text'],
              'start_ms': sentenceStart + index * span,
              'end_ms': unreliableTiming && index == 0
                  ? sentenceStart + 10
                  : sentenceStart + (index + 1) * span,
            },
        ],
      },
    ],
  };
  final timelineBytes = utf8.encode(jsonEncode(timeline));
  final timelineFile =
      File(p.join(bookDir.path, 'timeline', 'original_timeline.json'));
  await timelineFile.parent.create(recursive: true);
  await timelineFile.writeAsBytes(timelineBytes);
  final playback = File(p.join(bookDir.path, 'original', 'playback.ogg'));
  if (includePlayback) {
    await playback.writeAsBytes([5, 6, 7, 8]);
  }
  final manifest = {
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
  };
  if (includePlayback) {
    final bytes = await playback.readAsBytes();
    (manifest['original_audio'] as Map<String, dynamic>)['playback'] = {
      'path': 'original/playback.ogg',
      'mime_type': 'audio/ogg',
      'size_bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }
  await File(p.join(bookDir.path, 'manifest.json'))
      .writeAsString(jsonEncode(manifest));
}
