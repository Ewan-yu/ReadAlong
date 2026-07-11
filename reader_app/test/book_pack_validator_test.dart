import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/bookpack/book_pack_validator.dart';

Uint8List _fixture(String name) {
  final repoRoot = Directory.current.path.endsWith('reader_app')
      ? '${Directory.current.path}/..'
      : Directory.current.path;
  final path = '$repoRoot/shared/fixtures/out/$name';
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('夹具文件不存在: $path\n'
        '请先运行: conda run -n readalong python shared/fixtures/make_fixture_book.py');
  }
  return file.readAsBytesSync();
}

Uint8List _withDifferentContent(Uint8List source) {
  final sourceArchive = ZipDecoder().decodeBytes(source);
  final changedArchive = Archive();
  for (final file in sourceArchive) {
    if (file.name == 'manifest.json') {
      final content = String.fromCharCodes(file.content as List<int>)
          .replaceFirst('Fixture Book', 'Fixture Book Updated')
          .codeUnits;
      changedArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else {
      changedArchive.addFile(file);
    }
  }
  return Uint8List.fromList(ZipEncoder().encode(changedArchive)!);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('BookPackValidator', () {
    test('合法包通过全量校验', () async {
      final result = await BookPackValidator.validateBytes(
        _fixture('fixture_book.readalongbook'),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isTrue, reason: '合法包应通过: ${result.errors}');
    });

    test('坏包：缺 alignment.db 被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
        _fixture('bad_missing_file.readalongbook'),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('align/alignment.db')), isTrue,
          reason: '错误信息应提及缺失文件，实际: ${result.errors}');
    });

    test('坏包：bbox 越界被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
        _fixture('bad_bbox.readalongbook'),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('bbox')), isTrue,
          reason: '错误信息应提及 bbox，实际: ${result.errors}');
    });

    test('坏包：句子文本为空被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
        _fixture('bad_empty_text.readalongbook'),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('text') || e.contains('空')),
          isTrue,
          reason: '错误信息应提及空文本，实际: ${result.errors}');
    });

    test('坏包：路径逃逸被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
        _fixture('bad_path_escape.readalongbook'),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('路径逃逸')), isTrue,
          reason: '错误信息应提及路径逃逸，实际: ${result.errors}');
    });

    test('非法 zip 字节被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
        Uint8List.fromList([0, 1, 2, 3]),
        databaseFactory: databaseFactoryFfi,
      );
      expect(result.ok, isFalse);
    });
  });

  group('BookPackImporter', () {
    late Directory tempDir;
    late ShelfIndex shelfIndex;
    late BookPackImporter importer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('readalong_import_test_');
      shelfIndex = ShelfIndex(
        databasePath: '${tempDir.path}/app.db',
        databaseFactory: databaseFactoryFfi,
      );
      importer = BookPackImporter(
        booksDir: '${tempDir.path}/books',
        shelfIndex: shelfIndex,
        validationDatabaseFactory: databaseFactoryFfi,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('合法包解压到私有目录并写入书架索引', () async {
      final result = await importer.import(
        _fixture('fixture_book.readalongbook'),
      );

      expect(result.ok, isTrue, reason: '${result.errors}');
      final entry = result.entry!;
      expect(File('${entry.bookDir}/manifest.json').existsSync(), isTrue);
      expect(File('${entry.bookDir}/align/alignment.db').existsSync(), isTrue);
      expect(await shelfIndex.findById(entry.bookId), entry);
    });

    test('相同包再次导入返回已导入且不重复写索引', () async {
      final bytes = _fixture('fixture_book.readalongbook');
      expect((await importer.import(bytes)).ok, isTrue);

      final duplicate = await importer.import(bytes);

      expect(duplicate.ok, isFalse);
      expect(duplicate.isAlreadyImported, isTrue);
      expect(await shelfIndex.listBooks(), hasLength(1));
    });

    test('相同 book_id 的不同内容返回冲突', () async {
      final bytes = _fixture('fixture_book.readalongbook');
      expect((await importer.import(bytes)).ok, isTrue);

      final conflict = await importer.import(_withDifferentContent(bytes));

      expect(conflict.ok, isFalse);
      expect(conflict.isConflict, isTrue);
      expect(conflict.isAlreadyImported, isFalse);
    });

    test('坏包不创建书籍目录或书架索引', () async {
      final result = await importer.import(
        _fixture('bad_missing_file.readalongbook'),
      );

      expect(result.ok, isFalse);
      expect(await shelfIndex.listBooks(), isEmpty);
      final booksDir = Directory('${tempDir.path}/books');
      expect(booksDir.existsSync() ? booksDir.listSync() : const [], isEmpty);
    });
  });
}
