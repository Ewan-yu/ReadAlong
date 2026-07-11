import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class ShelfBook {
  final String bookId;
  final String title;
  final int pageCount;
  final String bookDir;
  final String thumbnailPath;
  final String packageSha256;
  final DateTime importedAt;

  const ShelfBook({
    required this.bookId,
    required this.title,
    required this.pageCount,
    required this.bookDir,
    required this.thumbnailPath,
    required this.packageSha256,
    required this.importedAt,
  });

  Map<String, Object?> toMap() => {
        'book_id': bookId,
        'title': title,
        'page_count': pageCount,
        'book_dir': bookDir,
        'thumbnail_path': thumbnailPath,
        'package_sha256': packageSha256,
        'imported_at': importedAt.toUtc().toIso8601String(),
      };

  factory ShelfBook.fromMap(Map<String, Object?> map) => ShelfBook(
        bookId: map['book_id']! as String,
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
      bookId == other.bookId &&
      title == other.title &&
      pageCount == other.pageCount &&
      bookDir == other.bookDir &&
      thumbnailPath == other.thumbnailPath &&
      packageSha256 == other.packageSha256 &&
      importedAt == other.importedAt;

  @override
  int get hashCode => Object.hash(
        bookId,
        title,
        pageCount,
        bookDir,
        thumbnailPath,
        packageSha256,
        importedAt,
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
    final db = await _open();
    try {
      final rows = await db.query(
        'shelf_book',
        where: 'book_id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      return rows.isEmpty ? null : ShelfBook.fromMap(rows.single);
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

  Future<Database> _open() async {
    await Directory(p.dirname(databasePath)).create(recursive: true);
    return databaseFactory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE shelf_book (
            book_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            page_count INTEGER NOT NULL,
            book_dir TEXT NOT NULL,
            thumbnail_path TEXT NOT NULL,
            package_sha256 TEXT NOT NULL,
            imported_at TEXT NOT NULL
          )
        '''),
      ),
    );
  }
}
