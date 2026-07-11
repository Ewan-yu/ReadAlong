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

  test('书架索引可写入并按导入时间倒序读取', () async {
    final older = ShelfBook(
      bookId: 'book-older',
      title: 'Older Book',
      pageCount: 2,
      bookDir: '${tempDir.path}/books/book-older',
      thumbnailPath: 'thumbnails/p0001.jpg',
      packageSha256: 'hash-older',
      importedAt: DateTime.utc(2026, 7, 10),
    );
    final newer = ShelfBook(
      bookId: 'book-newer',
      title: 'Newer Book',
      pageCount: 3,
      bookDir: '${tempDir.path}/books/book-newer',
      thumbnailPath: 'cover.jpg',
      packageSha256: 'hash-newer',
      importedAt: DateTime.utc(2026, 7, 11),
    );

    await index.add(older);
    await index.add(newer);

    expect(await index.findById('book-older'), older);
    expect(await index.listBooks(), [newer, older]);
  });
}
