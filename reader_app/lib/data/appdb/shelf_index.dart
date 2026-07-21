import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class ShelfBook {
  final String libraryId;
  final String sourceBookId;
  final String title;
  final int pageCount;
  final String bookDir;
  final String thumbnailPath;
  final String packageSha256;
  final DateTime importedAt;

  const ShelfBook({
    required this.libraryId,
    required this.sourceBookId,
    required this.title,
    required this.pageCount,
    required this.bookDir,
    required this.thumbnailPath,
    required this.packageSha256,
    required this.importedAt,
  });

  @Deprecated('Use libraryId instead')
  String get bookId => libraryId;

  Map<String, Object?> toMap() => {
        'book_id': libraryId,
        'source_book_id': sourceBookId,
        'title': title,
        'page_count': pageCount,
        'book_dir': bookDir,
        'thumbnail_path': thumbnailPath,
        'package_sha256': packageSha256,
        'imported_at': importedAt.toUtc().toIso8601String(),
      };

  factory ShelfBook.fromMap(Map<String, Object?> map) => ShelfBook(
        libraryId: map['book_id']! as String,
        sourceBookId: map['source_book_id']! as String,
        title: map['title']! as String,
        pageCount: map['page_count']! as int,
        bookDir: map['book_dir']! as String,
        thumbnailPath: map['thumbnail_path']! as String,
        packageSha256: map['package_sha256']! as String,
        importedAt: DateTime.parse(map['imported_at']! as String),
      );

  @override
  bool operator ==(Object other) =>
      other is ShelfBook &&
      libraryId == other.libraryId &&
      sourceBookId == other.sourceBookId &&
      title == other.title &&
      pageCount == other.pageCount &&
      bookDir == other.bookDir &&
      thumbnailPath == other.thumbnailPath &&
      packageSha256 == other.packageSha256 &&
      importedAt == other.importedAt;

  @override
  int get hashCode => Object.hash(
        libraryId,
        sourceBookId,
        title,
        pageCount,
        bookDir,
        thumbnailPath,
        packageSha256,
        importedAt,
      );
}

final class ReadingProgress {
  const ReadingProgress({
    required this.libraryId,
    required this.currentPage,
    required this.updatedAt,
  });

  final String libraryId;
  final int currentPage;
  final DateTime updatedAt;
}

enum ReadingRecordStatus { saved, scoring, scored, failed }

final class ReadingRecord {
  const ReadingRecord({
    required this.id,
    required this.libraryId,
    required this.sentenceId,
    required this.referenceText,
    required this.audioPath,
    required this.status,
    required this.provider,
    required this.createdAt,
    required this.updatedAt,
    this.childScore,
    this.detailJson,
  });

  final int id;
  final String libraryId;
  final String sentenceId;
  final String referenceText;
  final String audioPath;
  final ReadingRecordStatus status;
  final double? childScore;
  final String? detailJson;
  final String provider;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ReadingRecord.fromMap(Map<String, Object?> map) => ReadingRecord(
        id: map['id']! as int,
        libraryId: map['library_id']! as String,
        sentenceId: map['sentence_id']! as String,
        referenceText: map['reference_text']! as String,
        audioPath: map['audio_path']! as String,
        status: ReadingRecordStatus.values.byName(map['status']! as String),
        childScore: (map['child_score'] as num?)?.toDouble(),
        detailJson: map['detail_json'] as String?,
        provider: map['provider']! as String,
        createdAt: DateTime.parse(map['created_at']! as String),
        updatedAt: DateTime.parse(map['updated_at']! as String),
      );
}

class ShelfIndex {
  final String databasePath;
  final DatabaseFactory databaseFactory;

  const ShelfIndex({
    required this.databasePath,
    required this.databaseFactory,
  });

  Future<void> add(ShelfBook book) async {
    final db = await _open();
    try {
      await db.insert('shelf_book', book.toMap());
    } finally {
      await db.close();
    }
  }

  Future<ShelfBook?> findById(String bookId) async {
    return findByLibraryId(bookId);
  }

  Future<ShelfBook?> findByLibraryId(String libraryId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'shelf_book',
        where: 'book_id = ?',
        whereArgs: [libraryId],
        limit: 1,
      );
      return rows.isEmpty ? null : ShelfBook.fromMap(rows.single);
    } finally {
      await db.close();
    }
  }

  Future<List<ShelfBook>> findBySourceBookId(String sourceBookId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'shelf_book',
        where: 'source_book_id = ?',
        whereArgs: [sourceBookId],
        orderBy: 'book_id ASC',
      );
      return rows.map(ShelfBook.fromMap).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<int> nextCopyNumber(String sourceBookId) async {
    final books = await findBySourceBookId(sourceBookId);
    final pattern = RegExp('^${RegExp.escape(sourceBookId)}-copy-(\\d+)' r'$');
    final used = <int>{};
    for (final book in books) {
      final match = pattern.firstMatch(book.libraryId);
      if (match == null) continue;
      final number = int.tryParse(match.group(1)!);
      if (number != null && number > 0) used.add(number);
    }
    var next = 1;
    while (used.contains(next)) {
      next++;
    }
    return next;
  }

  Future<void> replace(ShelfBook book) async {
    final db = await _open();
    try {
      await db.insert(
        'shelf_book',
        book.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } finally {
      await db.close();
    }
  }

  Future<void> delete(String libraryId) async {
    final db = await _open();
    try {
      await db.delete(
        'shelf_book',
        where: 'book_id = ?',
        whereArgs: [libraryId],
      );
    } finally {
      await db.close();
    }
  }

  Future<List<ShelfBook>> listBooks() async {
    final db = await _open();
    try {
      final rows = await db.query(
        'shelf_book',
        orderBy: 'imported_at DESC, book_id ASC',
      );
      return rows.map(ShelfBook.fromMap).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<ReadingProgress?> loadProgress(String libraryId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'reading_progress',
        where: 'library_id = ?',
        whereArgs: [libraryId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return ReadingProgress(
        libraryId: row['library_id']! as String,
        currentPage: row['current_page']! as int,
        updatedAt: DateTime.parse(row['updated_at']! as String),
      );
    } finally {
      await db.close();
    }
  }

  Future<void> saveProgress({
    required String libraryId,
    required int currentPage,
  }) async {
    final db = await _open();
    try {
      await db.insert(
        'reading_progress',
        {
          'library_id': libraryId,
          'current_page': currentPage,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } finally {
      await db.close();
    }
  }

  Future<ReadingRecord> createRecord({
    required String libraryId,
    required String sentenceId,
    required String referenceText,
    required String audioPath,
    required String provider,
  }) async {
    final db = await _open();
    try {
      final now = DateTime.now().toUtc();
      final id = await db.insert('record', {
        'library_id': libraryId,
        'sentence_id': sentenceId,
        'reference_text': referenceText,
        'audio_path': audioPath,
        'status': ReadingRecordStatus.saved.name,
        'provider': provider,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      return ReadingRecord(
        id: id,
        libraryId: libraryId,
        sentenceId: sentenceId,
        referenceText: referenceText,
        audioPath: audioPath,
        status: ReadingRecordStatus.saved,
        provider: provider,
        createdAt: now,
        updatedAt: now,
      );
    } finally {
      await db.close();
    }
  }

  Future<void> updateRecord({
    required int id,
    required ReadingRecordStatus status,
    double? childScore,
    String? detailJson,
  }) async {
    final db = await _open();
    try {
      await db.update(
        'record',
        {
          'status': status.name,
          'child_score': childScore,
          'detail_json': detailJson,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } finally {
      await db.close();
    }
  }

  Future<void> deleteRecordsForBook(String libraryId) async {
    final db = await _open();
    try {
      await db
          .delete('record', where: 'library_id = ?', whereArgs: [libraryId]);
      await db.delete(
        'reading_progress',
        where: 'library_id = ?',
        whereArgs: [libraryId],
      );
    } finally {
      await db.close();
    }
  }

  /// Clears legacy follow-reading score rows after practice recordings became
  /// transient. Reading progress and imported books remain untouched.
  Future<void> deleteAllReadingRecords() async {
    final db = await _open();
    try {
      await db.delete('record');
    } finally {
      await db.close();
    }
  }

  Future<Database> _open() async {
    await Directory(p.dirname(databasePath)).create(recursive: true);
    return databaseFactory.openDatabase(
      databasePath,
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
          await _createRuntimeTables(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE shelf_book ADD COLUMN source_book_id TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              'UPDATE shelf_book SET source_book_id = book_id WHERE source_book_id = ?',
              [''],
            );
          }
          if (oldVersion < 3) await _createRuntimeTables(db);
        },
      ),
    );
  }
}

Future<void> _createRuntimeTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS reading_progress (
      library_id TEXT PRIMARY KEY,
      current_page INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS record (
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
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_record_library_sentence
    ON record(library_id, sentence_id, created_at DESC)
  ''');
}
