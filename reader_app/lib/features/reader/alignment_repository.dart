import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import 'point_reading_models.dart';
import 'subtitle_timing.dart';

abstract interface class PointReadingRepository {
  Future<PointReadingBook> loadBook(String libraryId);
}

final pointReadingRepositoryProvider =
    FutureProvider<PointReadingRepository>((ref) async {
  final shelfIndex = await ref.watch(shelfIndexProvider.future);
  final databaseFactory = ref.watch(appDatabaseFactoryProvider);
  return LocalPointReadingRepository(
    shelfIndex: shelfIndex,
    databaseFactory: databaseFactory,
  );
});

final pointReadingBookProvider =
    FutureProvider.family<PointReadingBook, String>(
  (ref, libraryId) async {
    final repository = await ref.watch(pointReadingRepositoryProvider.future);
    return repository.loadBook(libraryId);
  },
);

final class LocalPointReadingRepository implements PointReadingRepository {
  const LocalPointReadingRepository({
    required this.shelfIndex,
    required this.databaseFactory,
  });

  final ShelfIndex shelfIndex;
  final DatabaseFactory databaseFactory;

  @override
  Future<PointReadingBook> loadBook(String libraryId) async {
    final shelfBook = await shelfIndex.findByLibraryId(libraryId);
    if (shelfBook == null) {
      throw const PointReadingLoadException('Shelf book was not found');
    }

    final alignmentPath = p.join(shelfBook.bookDir, 'align', 'alignment.db');
    if (!File(alignmentPath).existsSync()) {
      throw const PointReadingLoadException('Alignment database is missing');
    }

    Database? database;
    try {
      database = await databaseFactory.openDatabase(
        alignmentPath,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final bookRows = await database.query('book', columns: ['id']);
      if (bookRows.length != 1 ||
          bookRows.single['id'] != shelfBook.sourceBookId) {
        throw const PointReadingDataException(
          'Alignment source identity does not match',
        );
      }

      final rows = await database.query(
        'sentence',
        columns: const [
          'id',
          'book_id',
          'page_no',
          'seq',
          'text',
          'bbox_json',
          'shared_bbox',
          'audio_path',
          't_start',
          't_end',
        ],
        orderBy: 'seq ASC',
      );
      final baseSentences = rows
          .map((row) => _parseSentence(shelfBook, row))
          .toList(growable: false);
      final wordTimings = await _loadWordTimings(database, baseSentences);
      final sentences = baseSentences
          .map(
            (sentence) => sentence.withWordTimings(
              wordTimings[sentence.id] ?? const [],
            ),
          )
          .toList(growable: false);
      return PointReadingBook(
        libraryId: shelfBook.libraryId,
        sentences: sentences,
      );
    } on PointReadingLoadException {
      rethrow;
    } on Object {
      throw const PointReadingLoadException(
        'Point reading alignment could not be loaded',
      );
    } finally {
      await database?.close();
    }
  }
}

Future<Map<String, List<ReaderWordTiming>>> _loadWordTimings(
  Database database,
  List<ReaderSentence> sentences,
) async {
  final rows = await _queryWordTimings(database);
  if (rows.isEmpty) return const {};
  final sentencesById = {
    for (final sentence in sentences) sentence.id: sentence
  };
  final grouped = <String, List<ReaderWordTiming>>{};
  final invalidSentenceIds = <String>{};
  final timingOwners = <String, String>{};

  for (final row in rows) {
    final sentenceId = row['sentence_id'];
    if (sentenceId is! String || !sentencesById.containsKey(sentenceId)) {
      continue;
    }
    try {
      final timing = _parseWordTiming(row, sentencesById[sentenceId]!);
      final previousOwner = timingOwners[timing.id];
      if (previousOwner != null) {
        invalidSentenceIds
          ..add(previousOwner)
          ..add(sentenceId);
        continue;
      }
      timingOwners[timing.id] = sentenceId;
      grouped.putIfAbsent(sentenceId, () => []).add(timing);
    } on Object {
      invalidSentenceIds.add(sentenceId);
    }
  }

  final result = <String, List<ReaderWordTiming>>{};
  for (final sentence in sentences) {
    final timings = grouped[sentence.id];
    if (timings == null ||
        timings.isEmpty ||
        invalidSentenceIds.contains(sentence.id)) {
      continue;
    }
    timings.sort((left, right) => left.sequence.compareTo(right.sequence));
    if (_validTimingGroup(sentence, timings)) {
      result[sentence.id] = List.unmodifiable(timings);
    }
  }
  return result;
}

Future<List<Map<String, Object?>>> _queryWordTimings(Database database) async {
  try {
    return await database.query(
      'word_timing',
      columns: const [
        'id',
        'sentence_id',
        'seq',
        'word',
        't_start',
        't_end',
      ],
      orderBy: 'sentence_id ASC, seq ASC',
    );
  } on Object {
    return const [];
  }
}

ReaderWordTiming _parseWordTiming(
  Map<String, Object?> row,
  ReaderSentence sentence,
) {
  final id = row['id'];
  final sequence = row['seq'];
  final word = row['word'];
  final start = row['t_start'];
  final end = row['t_end'];
  if (id is! String ||
      id.isEmpty ||
      sequence is! int ||
      sequence < 1 ||
      word is! String ||
      word.trim().isEmpty ||
      start is! num ||
      end is! num) {
    throw const PointReadingDataException('Word timing fields are invalid');
  }
  final startSeconds = start.toDouble();
  final endSeconds = end.toDouble();
  if (!startSeconds.isFinite || !endSeconds.isFinite) {
    throw const PointReadingDataException('Word timing number is invalid');
  }
  final startDuration = _secondsToDuration(startSeconds);
  final endDuration = _secondsToDuration(endSeconds);
  if (startDuration < sentence.audio.start ||
      endDuration > sentence.audio.end ||
      endDuration <= startDuration) {
    throw const PointReadingDataException('Word timing range is invalid');
  }
  return ReaderWordTiming(
    id: id,
    sequence: sequence,
    word: word,
    start: startDuration,
    end: endDuration,
  );
}

bool _validTimingGroup(
  ReaderSentence sentence,
  List<ReaderWordTiming> timings,
) {
  Duration? previousEnd;
  for (var index = 0; index < timings.length; index++) {
    final timing = timings[index];
    if (timing.sequence != index + 1 ||
        (previousEnd != null && timing.start < previousEnd)) {
      return false;
    }
    previousEnd = timing.end;
  }
  final sentenceWords = normalizedSubtitleWords(sentence.text);
  final timingWords = timings
      .map((timing) => normalizedSubtitleWords(timing.word))
      .toList(growable: false);
  if (sentenceWords.length != timingWords.length) return false;
  for (var index = 0; index < sentenceWords.length; index++) {
    final timingWord = timingWords[index];
    if (timingWord.length != 1 || timingWord.single != sentenceWords[index]) {
      return false;
    }
  }
  return true;
}

ReaderSentence _parseSentence(
  ShelfBook shelfBook,
  Map<String, Object?> row,
) {
  final id = row['id'];
  final bookId = row['book_id'];
  final pageNumber = row['page_no'];
  final sequence = row['seq'];
  final text = row['text'];
  final sharedBbox = row['shared_bbox'];
  final audioPath = row['audio_path'];
  final start = row['t_start'];
  final end = row['t_end'];
  if (id is! String ||
      id.isEmpty ||
      bookId != shelfBook.sourceBookId ||
      pageNumber is! int ||
      pageNumber < 1 ||
      pageNumber > shelfBook.pageCount ||
      sequence is! int ||
      sequence < 1 ||
      text is! String ||
      text.trim().isEmpty ||
      (sharedBbox != 0 && sharedBbox != 1) ||
      start is! num ||
      end is! num) {
    throw const PointReadingDataException('Sentence fields are invalid');
  }
  final startSeconds = start.toDouble();
  final endSeconds = end.toDouble();
  if (!startSeconds.isFinite ||
      !endSeconds.isFinite ||
      startSeconds < 0 ||
      endSeconds <= startSeconds) {
    throw const PointReadingDataException('Sentence audio interval is invalid');
  }

  return ReaderSentence(
    id: id,
    pageNumber: pageNumber,
    sequence: sequence,
    text: text,
    bbox: _parseBbox(row['bbox_json']),
    sharedBbox: sharedBbox == 1,
    audio: SentenceAudioClip(
      path: _resolveInside(shelfBook.bookDir, audioPath),
      start: _secondsToDuration(startSeconds),
      end: _secondsToDuration(endSeconds),
    ),
  );
}

NormalizedRect _parseBbox(Object? raw) {
  if (raw is! String) {
    throw const PointReadingDataException('Sentence bbox is invalid');
  }
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const PointReadingDataException('Sentence bbox is invalid');
  }
  final x = _finiteDouble(decoded['x']);
  final y = _finiteDouble(decoded['y']);
  final width = _finiteDouble(decoded['w']);
  final height = _finiteDouble(decoded['h']);
  if (x < 0 ||
      y < 0 ||
      width <= 0 ||
      height <= 0 ||
      x + width > 1 ||
      y + height > 1) {
    throw const PointReadingDataException('Sentence bbox is out of bounds');
  }
  return NormalizedRect(x: x, y: y, width: width, height: height);
}

double _finiteDouble(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const PointReadingDataException('Sentence number is invalid');
  }
  return value.toDouble();
}

Duration _secondsToDuration(double seconds) =>
    Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());

String _resolveInside(String bookDir, Object? relativePath) {
  if (relativePath is! String ||
      relativePath.isEmpty ||
      p.isAbsolute(relativePath)) {
    throw const PointReadingDataException('Sentence audio path is invalid');
  }
  final root = p.normalize(p.absolute(bookDir));
  final resolved = p.normalize(p.absolute(p.join(root, relativePath)));
  if (!p.isWithin(root, resolved)) {
    throw const PointReadingDataException('Sentence audio path escapes book');
  }
  return resolved;
}
