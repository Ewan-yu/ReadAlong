import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/features/reader/reader_models.dart';
import 'package:reader_app/features/reader/reader_repository.dart';

void main() {
  sqfliteFfiInit();

  late Directory tempDir;
  late Directory bookDir;
  late ShelfIndex shelfIndex;
  late ShelfBook shelfBook;
  late LocalReaderRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reader_repository_test_');
    bookDir = await Directory(p.join(tempDir.path, 'books', 'story-copy-2'))
        .create(recursive: true);
    shelfIndex = ShelfIndex(
      databasePath: p.join(tempDir.path, 'app.db'),
      databaseFactory: databaseFactoryFfi,
    );
    shelfBook = ShelfBook(
      libraryId: 'story-copy-2',
      sourceBookId: 'story-source',
      title: 'Moon Story',
      pageCount: 2,
      bookDir: bookDir.path,
      thumbnailPath: 'thumbnails/p0001.jpg',
      packageSha256: 'sha256',
      importedAt: DateTime.utc(2026, 7, 12),
    );
    repository = LocalReaderRepository(shelfIndex: shelfIndex);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Map<String, Object?> page(
    int number, {
    String? image,
    String? thumbnail,
    int width = 1200,
    int height = 1600,
  }) =>
      {
        'page_no': number,
        'image': image ?? 'pages/p${number.toString().padLeft(4, '0')}.webp',
        'thumbnail':
            thumbnail ?? 'thumbnails/p${number.toString().padLeft(4, '0')}.jpg',
        'width_px': width,
        'height_px': height,
        'source_region': 'full',
      };

  Future<void> writeManifest({
    String sourceBookId = 'story-source',
    int pageCount = 2,
    List<Map<String, Object?>>? pages,
  }) =>
      File(p.join(bookDir.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'schema_version': 1,
          'book_id': sourceBookId,
          'title': 'Moon Story',
          'language': 'en',
          'created_at': '2026-07-12T00:00:00Z',
          'generator': {'name': 'test', 'version': '1'},
          'page_count': pageCount,
          'page_image': {
            'format': 'webp',
            'max_long_edge_px': 1600,
            'quality': 78,
          },
          'thumbnail': {
            'format': 'jpg',
            'max_long_edge_px': 360,
            'quality': 75,
          },
          'pages': pages ?? [page(1), page(2)],
        }),
      );

  test('按 page_no 排序并解析书籍目录内的绝对路径', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(pages: [page(2), page(1)]);

    final book = await repository.loadBook(shelfBook.libraryId);

    expect(book.libraryId, shelfBook.libraryId);
    expect(book.sourceBookId, shelfBook.sourceBookId);
    expect(book.title, shelfBook.title);
    expect(book.pages.map((item) => item.pageNumber), [1, 2]);
    expect(
      book.pages.first.imagePath,
      p.join(bookDir.path, 'pages', 'p0001.webp'),
    );
    expect(
      book.pages.first.thumbnailPath,
      p.join(bookDir.path, 'thumbnails', 'p0001.jpg'),
    );
    expect(book.pages.first.widthPx, 1200);
    expect(book.pages.first.heightPx, 1600);
  });

  test('未知 libraryId 返回明确的未找到异常', () async {
    expect(
      () => repository.loadBook('missing-book'),
      throwsA(isA<ReaderBookNotFoundException>()),
    );
  });

  test('manifest JSON 损坏时返回清单异常', () async {
    await shelfIndex.add(shelfBook);
    await File(p.join(bookDir.path, 'manifest.json')).writeAsString('{broken');

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('manifest 来源身份和书架 sourceBookId 不一致时拒绝打开', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(sourceBookId: 'different-source');

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('page_count 与页面清单长度不一致时拒绝打开', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(pageCount: 3);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('书架页数与 manifest page_count 不一致时拒绝打开', () async {
    await shelfIndex.add(ShelfBook(
      libraryId: shelfBook.libraryId,
      sourceBookId: shelfBook.sourceBookId,
      title: shelfBook.title,
      pageCount: 3,
      bookDir: shelfBook.bookDir,
      thumbnailPath: shelfBook.thumbnailPath,
      packageSha256: shelfBook.packageSha256,
      importedAt: shelfBook.importedAt,
    ));
    await writeManifest();

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('页码不连续时拒绝打开', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(pages: [page(1), page(3)]);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('页面路径逃出书籍目录时拒绝打开', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(pages: [page(1, image: '../outside.webp'), page(2)]);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });

  test('单页图片缺失不阻止加载其余书籍清单', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest();

    final book = await repository.loadBook(shelfBook.libraryId);

    expect(book.pages, hasLength(2));
    expect(File(book.pages.last.imagePath).existsSync(), isFalse);
  });

  test('页面尺寸不是正整数时拒绝打开', () async {
    await shelfIndex.add(shelfBook);
    await writeManifest(pages: [page(1, width: 0), page(2)]);

    expect(
      () => repository.loadBook(shelfBook.libraryId),
      throwsA(isA<ReaderManifestException>()),
    );
  });
}
