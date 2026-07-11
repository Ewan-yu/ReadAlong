import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/bookpack/book_pack_importer.dart';
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

Future<String> _readManifestTitle(ShelfBook entry) async {
  final manifest = await File('${entry.bookDir}/manifest.json').readAsString();
  return RegExp(r'"title"\s*:\s*"([^"]+)"').firstMatch(manifest)!.group(1)!;
}

Future<String> _readManifestBookId(ShelfBook entry) async {
  final manifest = await File('${entry.bookDir}/manifest.json').readAsString();
  return RegExp(r'"book_id"\s*:\s*"([^"]+)"').firstMatch(manifest)!.group(1)!;
}

class _ReplaceFailingShelfIndex extends ShelfIndex {
  const _ReplaceFailingShelfIndex({
    required super.databasePath,
    required super.databaseFactory,
  });

  @override
  Future<void> replace(ShelfBook book) {
    throw StateError('replace failed');
  }
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
      expect(await shelfIndex.findById(entry.libraryId), entry);
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
      expect(conflict.conflictEntry, isNotNull);
      expect(conflict.conflictEntry!.libraryId, 'fixture-book-0001');
    });

    test('覆盖保留 libraryId 并替换资源和哈希', () async {
      final first =
          await importer.import(_fixture('fixture_book.readalongbook'));
      final result = await importer.import(
        _withDifferentContent(_fixture('fixture_book.readalongbook')),
        resolution: ImportConflictResolution.overwrite,
        targetLibraryId: first.entry!.libraryId,
      );

      expect(result.ok, isTrue, reason: '${result.errors}');
      expect(result.entry!.libraryId, first.entry!.libraryId);
      expect(result.entry!.sourceBookId, 'fixture-book-0001');
      expect(result.entry!.packageSha256, isNot(first.entry!.packageSha256));
      expect(await _readManifestTitle(result.entry!), 'Fixture Book Updated');
      expect(await shelfIndex.findByLibraryId(first.entry!.libraryId),
          result.entry);
    });

    test('存为副本不修改资源 manifest 或 alignment', () async {
      final original = _fixture('fixture_book.readalongbook');
      final changed = _withDifferentContent(original);
      await importer.import(original);
      final sourceArchive = ZipDecoder().decodeBytes(changed);
      final expectedAlignment = sourceArchive
          .firstWhere((file) => file.name == 'align/alignment.db')
          .content as List<int>;

      final copy = await importer.import(
        changed,
        resolution: ImportConflictResolution.saveCopy,
      );

      expect(copy.ok, isTrue, reason: '${copy.errors}');
      expect(copy.entry!.libraryId, 'fixture-book-0001-copy-1');
      expect(copy.entry!.sourceBookId, 'fixture-book-0001');
      expect(await _readManifestBookId(copy.entry!), 'fixture-book-0001');
      expect(
        await File('${copy.entry!.bookDir}/align/alignment.db').readAsBytes(),
        expectedAlignment,
      );
    });

    test('覆盖索引替换失败时恢复旧资源和索引', () async {
      final first =
          await importer.import(_fixture('fixture_book.readalongbook'));
      final failingImporter = BookPackImporter(
        booksDir: '${tempDir.path}/books',
        shelfIndex: _ReplaceFailingShelfIndex(
          databasePath: '${tempDir.path}/app.db',
          databaseFactory: databaseFactoryFfi,
        ),
        validationDatabaseFactory: databaseFactoryFfi,
      );

      final result = await failingImporter.import(
        _withDifferentContent(_fixture('fixture_book.readalongbook')),
        resolution: ImportConflictResolution.overwrite,
        targetLibraryId: first.entry!.libraryId,
      );

      expect(result.ok, isFalse);
      expect(await _readManifestTitle(first.entry!), 'Fixture Book');
      expect(await shelfIndex.findByLibraryId(first.entry!.libraryId),
          first.entry);
      expect(
        Directory('${tempDir.path}/books')
            .listSync()
            .whereType<Directory>()
            .map((directory) =>
                directory.path.split(Platform.pathSeparator).last),
        isNot(contains(startsWith('.backup-'))),
      );
    });

    test('恢复仅处理导入器遗留的直接子目录', () async {
      final booksDir = Directory('${tempDir.path}/books');
      await booksDir.create(recursive: true);
      await Directory('${booksDir.path}/.import-fixture-book-0001-100')
          .create();
      await Directory('${booksDir.path}/.backup-existing-book-101').create();
      await Directory('${booksDir.path}/existing-book').create();
      final restored = Directory('${booksDir.path}/.backup-restored-book-102');
      await restored.create();
      await File('${restored.path}/marker.txt').writeAsString('restore me');
      final nestedImport =
          Directory('${booksDir.path}/unrelated/.import-fixture-book-0001-103');
      await nestedImport.create(recursive: true);

      await importer.recoverInterruptedImports();

      expect(
        Directory('${booksDir.path}/.import-fixture-book-0001-100')
            .existsSync(),
        isFalse,
      );
      expect(
        Directory('${booksDir.path}/.backup-existing-book-101').existsSync(),
        isFalse,
      );
      expect(Directory('${booksDir.path}/restored-book').existsSync(), isTrue);
      expect(File('${booksDir.path}/restored-book/marker.txt').existsSync(),
          isTrue);
      expect(nestedImport.existsSync(), isTrue);
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
