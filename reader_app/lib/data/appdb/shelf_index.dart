import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'dubbing_models.dart';

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
  /// Product limit for alternative recordings of one sentence.
  static const maxSentenceTakes = 3;

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

  Future<DubbingProject> createDubbingProject({
    required String id,
    required String libraryId,
    required String sourceBookId,
    required String resourceSha256,
    required String timelineSha256,
    required DubbingMode mode,
  }) async {
    _requireDubbingValue(id, 'id');
    _requireDubbingValue(libraryId, 'libraryId');
    _requireDubbingValue(sourceBookId, 'sourceBookId');
    _requireDubbingValue(resourceSha256, 'resourceSha256');
    _requireDubbingValue(timelineSha256, 'timelineSha256');
    final db = await _open();
    try {
      final now = DateTime.now().toUtc();
      final project = DubbingProject(
        id: id,
        libraryId: libraryId,
        sourceBookId: sourceBookId,
        resourceSha256: resourceSha256,
        timelineSha256: timelineSha256,
        mode: mode,
        status: DubbingProjectStatus.draft,
        createdAt: now,
        updatedAt: now,
      );
      await db.insert('dubbing_project', {
        'id': project.id,
        'library_id': project.libraryId,
        'source_book_id': project.sourceBookId,
        'resource_sha256': project.resourceSha256,
        'timeline_sha256': project.timelineSha256,
        'mode': project.mode.name,
        'status': project.status.name,
        'created_at': project.createdAt.toIso8601String(),
        'updated_at': project.updatedAt.toIso8601String(),
      });
      return project;
    } finally {
      await db.close();
    }
  }

  Future<DubbingProject?> findDubbingProject(String projectId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_project',
        where: 'id = ?',
        whereArgs: [projectId],
        limit: 1,
      );
      return rows.isEmpty ? null : DubbingProject.fromMap(rows.single);
    } finally {
      await db.close();
    }
  }

  Future<List<DubbingProject>> listDubbingProjects(String libraryId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_project',
        where: 'library_id = ?',
        whereArgs: [libraryId],
        orderBy: 'updated_at DESC, id ASC',
      );
      return rows.map(DubbingProject.fromMap).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<void> updateDubbingProjectStatus(
    String projectId,
    DubbingProjectStatus status,
  ) async {
    final db = await _open();
    try {
      await db.update(
        'dubbing_project',
        {
          'status': status.name,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [projectId],
      );
    } finally {
      await db.close();
    }
  }

  Future<DubbingTake> createDubbingTake({
    required String id,
    required String projectId,
    required DubbingTakeKind takeKind,
    required String audioRelativePath,
    required Duration duration,
    String? sentenceId,
  }) async {
    _requireDubbingValue(id, 'id');
    _requireDubbingValue(projectId, 'projectId');
    _requireDubbingRelativePath(audioRelativePath);
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', '必须大于零');
    }
    if (takeKind == DubbingTakeKind.sentence &&
        (sentenceId == null || sentenceId.isEmpty)) {
      throw ArgumentError.value(sentenceId, 'sentenceId', '逐句 Take 必须关联句子');
    }
    if (takeKind == DubbingTakeKind.full && sentenceId != null) {
      throw ArgumentError.value(sentenceId, 'sentenceId', '完整 Take 不能关联句子');
    }
    final db = await _open();
    try {
      final now = DateTime.now().toUtc();
      final take = DubbingTake(
        id: id,
        projectId: projectId,
        sentenceId: sentenceId,
        takeKind: takeKind,
        audioRelativePath: audioRelativePath,
        duration: duration,
        isSelected: false,
        scoreStatus: DubbingTakeScoreStatus.pending,
        createdAt: now,
      );
      await db.transaction((transaction) async {
        final projectRows = await transaction.query(
          'dubbing_project',
          columns: const ['id'],
          where: 'id = ?',
          whereArgs: [projectId],
          limit: 1,
        );
        if (projectRows.isEmpty) throw StateError('配音项目不存在');

        // A child may keep three alternatives for one sentence. Count inside
        // this transaction so concurrent save requests cannot make the fourth
        // recording visible.
        if (takeKind == DubbingTakeKind.sentence) {
          final countRows = await transaction.rawQuery(
            'SELECT COUNT(*) AS count FROM dubbing_take '
            'WHERE project_id = ? AND take_kind = ? AND sentence_id = ?',
            [projectId, takeKind.name, sentenceId],
          );
          final count = countRows.single['count']! as int;
          if (count >= maxSentenceTakes) {
            throw StateError('每句最多保留 $maxSentenceTakes 个 Take，请先替换一个');
          }
        }

        await transaction.insert('dubbing_take', {
          'id': take.id,
          'project_id': take.projectId,
          'sentence_id': take.sentenceId,
          'take_kind': take.takeKind.name,
          'audio_path': take.audioRelativePath,
          'duration_ms': take.duration.inMilliseconds,
          'selected': 0,
          'score_status': take.scoreStatus.name,
          'created_at': take.createdAt.toIso8601String(),
        });
        await _touchDubbingProject(transaction, projectId, now);
      });
      return take;
    } finally {
      await db.close();
    }
  }

  Future<DubbingTake?> findDubbingTake(String takeId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_take',
        where: 'id = ?',
        whereArgs: [takeId],
        limit: 1,
      );
      return rows.isEmpty ? null : DubbingTake.fromMap(rows.single);
    } finally {
      await db.close();
    }
  }

  Future<List<DubbingTake>> listDubbingTakes(
    String projectId, {
    String? sentenceId,
  }) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_take',
        where: sentenceId == null
            ? 'project_id = ?'
            : 'project_id = ? AND sentence_id = ?',
        whereArgs: sentenceId == null ? [projectId] : [projectId, sentenceId],
        orderBy: 'created_at DESC, id ASC',
      );
      return rows.map(DubbingTake.fromMap).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<void> selectDubbingTake(String takeId) async {
    final db = await _open();
    try {
      await db.transaction((transaction) async {
        final rows = await transaction.query(
          'dubbing_take',
          where: 'id = ?',
          whereArgs: [takeId],
          limit: 1,
        );
        if (rows.isEmpty) throw StateError('配音 Take 不存在');
        final take = DubbingTake.fromMap(rows.single);
        final where = take.takeKind == DubbingTakeKind.sentence
            ? 'project_id = ? AND take_kind = ? AND sentence_id = ?'
            : 'project_id = ? AND take_kind = ?';
        final arguments = take.takeKind == DubbingTakeKind.sentence
            ? [take.projectId, take.takeKind.name, take.sentenceId]
            : [take.projectId, take.takeKind.name];
        await transaction.update(
          'dubbing_take',
          {'selected': 0},
          where: where,
          whereArgs: arguments,
        );
        await transaction.update(
          'dubbing_take',
          {'selected': 1},
          where: 'id = ?',
          whereArgs: [takeId],
        );
        await _touchDubbingProject(
            transaction, take.projectId, DateTime.now().toUtc());
      });
    } finally {
      await db.close();
    }
  }

  Future<void> updateDubbingTakeScore({
    required String takeId,
    required DubbingTakeScoreStatus status,
    String? scoreJson,
    String? scoreError,
  }) async {
    if (status == DubbingTakeScoreStatus.scored && scoreJson == null) {
      throw ArgumentError('已评分 Take 必须包含评分详情');
    }
    final db = await _open();
    try {
      await db.update(
        'dubbing_take',
        {
          'score_status': status.name,
          'score_json': scoreJson,
          'score_error': scoreError,
        },
        where: 'id = ?',
        whereArgs: [takeId],
      );
    } finally {
      await db.close();
    }
  }

  Future<void> deleteDubbingTake(String takeId) async {
    final db = await _open();
    try {
      await db.transaction((transaction) async {
        final rows = await transaction.query(
          'dubbing_take',
          columns: const ['project_id'],
          where: 'id = ?',
          whereArgs: [takeId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final projectId = rows.single['project_id']! as String;
        await transaction
            .delete('dubbing_take', where: 'id = ?', whereArgs: [takeId]);
        await _touchDubbingProject(
            transaction, projectId, DateTime.now().toUtc());
      });
    } finally {
      await db.close();
    }
  }

  Future<void> deleteDubbingProject(String projectId) async {
    final db = await _open();
    try {
      await db.transaction((transaction) async {
        await transaction.delete(
          'dubbing_take',
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        await transaction.delete(
          'dubbing_mix',
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        await transaction.delete(
          'dubbing_project',
          where: 'id = ?',
          whereArgs: [projectId],
        );
      });
    } finally {
      await db.close();
    }
  }

  Future<DubbingMix> createDubbingMix({
    required String id,
    required String projectId,
    required String audioRelativePath,
    required DubbingMixVariant variant,
    required String sourceTakeFingerprint,
    required Duration duration,
  }) async {
    _requireDubbingValue(id, 'id');
    _requireDubbingValue(projectId, 'projectId');
    _requireDubbingRelativePath(audioRelativePath);
    _requireDubbingValue(sourceTakeFingerprint, 'sourceTakeFingerprint');
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', '必须大于零');
    }
    final db = await _open();
    try {
      final now = DateTime.now().toUtc();
      final mix = DubbingMix(
        id: id,
        projectId: projectId,
        audioRelativePath: audioRelativePath,
        variant: variant,
        sourceTakeFingerprint: sourceTakeFingerprint,
        duration: duration,
        createdAt: now,
      );
      await db.transaction((transaction) async {
        final projects = await transaction.query(
          'dubbing_project',
          columns: const ['id'],
          where: 'id = ?',
          whereArgs: [projectId],
          limit: 1,
        );
        if (projects.isEmpty) throw StateError('配音项目不存在');
        await transaction.insert('dubbing_mix', {
          'id': mix.id,
          'project_id': mix.projectId,
          'audio_path': mix.audioRelativePath,
          'variant': mix.variant.name,
          'source_take_fingerprint': mix.sourceTakeFingerprint,
          'duration_ms': mix.duration.inMilliseconds,
          'created_at': mix.createdAt.toIso8601String(),
        });
        await _touchDubbingProject(transaction, projectId, now);
      });
      return mix;
    } finally {
      await db.close();
    }
  }

  Future<List<DubbingMix>> listDubbingMixes(String projectId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_mix',
        where: 'project_id = ?',
        whereArgs: [projectId],
        orderBy: 'created_at DESC, id ASC',
      );
      return rows.map(DubbingMix.fromMap).toList(growable: false);
    } finally {
      await db.close();
    }
  }

  Future<DubbingMix?> findDubbingMix(String mixId) async {
    final db = await _open();
    try {
      final rows = await db.query(
        'dubbing_mix',
        where: 'id = ?',
        whereArgs: [mixId],
        limit: 1,
      );
      return rows.isEmpty ? null : DubbingMix.fromMap(rows.single);
    } finally {
      await db.close();
    }
  }

  Future<void> deleteDubbingMix(String mixId) async {
    final db = await _open();
    try {
      await db.transaction((transaction) async {
        final rows = await transaction.query(
          'dubbing_mix',
          columns: const ['project_id'],
          where: 'id = ?',
          whereArgs: [mixId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final projectId = rows.single['project_id']! as String;
        await transaction
            .delete('dubbing_mix', where: 'id = ?', whereArgs: [mixId]);
        await _touchDubbingProject(
            transaction, projectId, DateTime.now().toUtc());
      });
    } finally {
      await db.close();
    }
  }

  Future<Database> _open() async {
    await Directory(p.dirname(databasePath)).create(recursive: true);
    return databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 5,
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
          await _createDubbingTables(db);
          await _createDubbingMixTable(db);
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
          if (oldVersion < 4) await _createDubbingTables(db);
          if (oldVersion < 5) await _createDubbingMixTable(db);
        },
      ),
    );
  }
}

void _requireDubbingValue(String value, String name) {
  if (value.isEmpty) throw ArgumentError.value(value, name, '不能为空');
}

void _requireDubbingRelativePath(String value) {
  final normalized = p.posix.normalize(value);
  if (value.isEmpty ||
      value.contains('\\') ||
      p.isAbsolute(value) ||
      p.posix.isAbsolute(value) ||
      normalized == '.' ||
      normalized == '..' ||
      normalized.startsWith('../') ||
      !normalized.startsWith('dubbing/')) {
    throw ArgumentError.value(value, 'audioRelativePath', '必须是配音目录内的相对路径');
  }
}

Future<void> _touchDubbingProject(
  DatabaseExecutor database,
  String projectId,
  DateTime now,
) =>
    database.update(
      'dubbing_project',
      {'updated_at': now.toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [projectId],
    );

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

Future<void> _createDubbingTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS dubbing_project (
      id TEXT PRIMARY KEY,
      library_id TEXT NOT NULL,
      source_book_id TEXT NOT NULL,
      resource_sha256 TEXT NOT NULL,
      timeline_sha256 TEXT NOT NULL,
      mode TEXT NOT NULL CHECK (mode IN ('sentence', 'full')),
      status TEXT NOT NULL CHECK (status IN ('draft', 'complete', 'incompatible')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_dubbing_project_library_updated
    ON dubbing_project(library_id, updated_at DESC, id ASC)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS dubbing_take (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      sentence_id TEXT,
      take_kind TEXT NOT NULL CHECK (take_kind IN ('sentence', 'full')),
      audio_path TEXT NOT NULL,
      duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
      selected INTEGER NOT NULL DEFAULT 0 CHECK (selected IN (0, 1)),
      score_status TEXT NOT NULL CHECK (score_status IN ('pending', 'scored', 'failed')),
      score_json TEXT,
      score_error TEXT,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_dubbing_take_project_sentence
    ON dubbing_take(project_id, sentence_id, created_at DESC, id ASC)
  ''');
}

Future<void> _createDubbingMixTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS dubbing_mix (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      audio_path TEXT NOT NULL,
      variant TEXT NOT NULL,
      source_take_fingerprint TEXT NOT NULL,
      duration_ms INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_dubbing_mix_project_created
    ON dubbing_mix(project_id, created_at DESC, id ASC)
  ''');
}
