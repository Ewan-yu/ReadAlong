import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import 'point_reading_models.dart';

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
      final sentences = rows
          .map((row) => _parseSentence(shelfBook, row))
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
