import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';

void main() {
  late Directory tempDir;
  late ShelfIndex index;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('readalong_shelf_test_');
    index = ShelfIndex(
      databasePath: '${tempDir.path}/app.db',
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Map<String, Object?> legacyBookMap(String bookId) => {
        'book_id': bookId,
        'title': 'Legacy Book',
        'page_count': 2,
        'book_dir': '${tempDir.path}/books/$bookId',
        'thumbnail_path': 'cover.jpg',
        'package_sha256': 'legacy-hash',
        'imported_at': '2026-07-10T00:00:00.000Z',
      };

  Future<void> createV1ShelfTable(Database db, int version) => db.execute('''
        CREATE TABLE shelf_book (
          book_id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          page_count INTEGER NOT NULL,
          book_dir TEXT NOT NULL,
          thumbnail_path TEXT NOT NULL,
          package_sha256 TEXT NOT NULL,
          imported_at TEXT NOT NULL
        )
      ''');

  ShelfBook book({
    required String libraryId,
    required String sourceBookId,
  }) =>
      ShelfBook(
        libraryId: libraryId,
        sourceBookId: sourceBookId,
        title: 'Book $libraryId',
        pageCount: 1,
        bookDir: '${tempDir.path}/books/$libraryId',
        thumbnailPath: 'cover.jpg',
        packageSha256: 'hash-$libraryId',
        importedAt: DateTime.utc(2026, 7, 10),
      );

  test('v1 索引升级后 sourceBookId 等于原 book_id', () async {
    final db = await databaseFactoryFfi.openDatabase(
      index.databasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: createV1ShelfTable),
    );
    await db.insert('shelf_book', legacyBookMap('fixture-book-0001'));
    await db.close();

    final migrated = await index.findByLibraryId('fixture-book-0001');
    expect(migrated!.libraryId, 'fixture-book-0001');
    expect(migrated.sourceBookId, 'fixture-book-0001');
  });

  test('deprecated bookId aliases libraryId', () {
    final entry = book(
      libraryId: 'library-id',
      sourceBookId: 'source-id',
    );

    // ignore: deprecated_member_use_from_same_package
    expect(entry.bookId, entry.libraryId);
  });

  test('按 sourceBookId 查询所有副本', () async {
    await index.add(book(libraryId: 'source-copy-1', sourceBookId: 'source'));
    await index.add(book(libraryId: 'other-book', sourceBookId: 'other'));
    await index.add(book(libraryId: 'source-copy-2', sourceBookId: 'source'));

    expect(await index.findBySourceBookId('source'), hasLength(2));
  });

  test('副本编号使用最小可用正整数', () async {
    await index.add(book(libraryId: 'source-copy-1', sourceBookId: 'source'));
    await index.add(book(libraryId: 'source-copy-3', sourceBookId: 'source'));

    expect(await index.nextCopyNumber('source'), 2);
  });

  test('副本编号匹配时会转义 sourceBookId', () async {
    await index.add(book(
      libraryId: 'source.v1-copy-1',
      sourceBookId: 'source.v1',
    ));
    await index.add(book(
      libraryId: 'sourceXv1-copy-2',
      sourceBookId: 'source.v1',
    ));

    expect(await index.nextCopyNumber('source.v1'), 2);
  });

  test('replace replaces a book with the same libraryId', () async {
    await index.add(book(libraryId: 'library', sourceBookId: 'source'));
    final replacement = book(
      libraryId: 'library',
      sourceBookId: 'new-source',
    );

    await index.replace(replacement);

    expect(await index.findByLibraryId('library'), replacement);
  });

  test('delete removes a book by libraryId', () async {
    await index.add(book(libraryId: 'library', sourceBookId: 'source'));

    await index.delete('library');

    expect(await index.findByLibraryId('library'), isNull);
  });

  test('书架索引可写入并按导入时间倒序读取', () async {
    final older = ShelfBook(
      libraryId: 'book-older',
      sourceBookId: 'book-older',
      title: 'Older Book',
      pageCount: 2,
      bookDir: '${tempDir.path}/books/book-older',
      thumbnailPath: 'thumbnails/p0001.jpg',
      packageSha256: 'hash-older',
      importedAt: DateTime.utc(2026, 7, 10),
    );
    final newer = ShelfBook(
      libraryId: 'book-newer',
      sourceBookId: 'book-newer',
      title: 'Newer Book',
      pageCount: 3,
      bookDir: '${tempDir.path}/books/book-newer',
      thumbnailPath: 'cover.jpg',
      packageSha256: 'hash-newer',
      importedAt: DateTime.utc(2026, 7, 11),
    );

    await index.add(older);
    await index.add(newer);

    expect(await index.findByLibraryId('book-older'), older);
    expect(await index.listBooks(), [newer, older]);
  });
}
