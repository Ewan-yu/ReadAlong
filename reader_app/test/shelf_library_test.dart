import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/bookpack/book_pack_importer.dart';
import 'package:reader_app/features/shelf/shelf_library.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Uint8List _fixture(String name) {
  final repoRoot = Directory.current.path.endsWith('reader_app')
      ? '${Directory.current.path}/..'
      : Directory.current.path;
  return File('$repoRoot/shared/fixtures/out/$name').readAsBytesSync();
}

class _FailingDeleteShelfIndex extends ShelfIndex {
  _FailingDeleteShelfIndex({
    required super.databasePath,
    required super.databaseFactory,
  });

  var failNextDelete = false;

  @override
  Future<void> delete(String libraryId) {
    if (failNextDelete) {
      failNextDelete = false;
      throw FileSystemException('index delete failed');
    }
    return super.delete(libraryId);
  }
}

class _RecordingCleaner implements BookRecordCleaner {
  final deletedIds = <String>[];
  Object? error;

  @override
  Future<void> deleteForBook(String libraryId) async {
    deletedIds.add(libraryId);
    if (error != null) throw error!;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('LocalShelfLibrary', () {
    late Directory tempDir;
    late _FailingDeleteShelfIndex index;
    late BookPackImporter importer;
    late _RecordingCleaner recordCleaner;
    late LocalShelfLibrary library;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('readalong_library_test_');
      index = _FailingDeleteShelfIndex(
        databasePath: '${tempDir.path}/app.db',
        databaseFactory: databaseFactoryFfi,
      );
      importer = BookPackImporter(
        booksDir: '${tempDir.path}/books',
        shelfIndex: index,
        validationDatabaseFactory: databaseFactoryFfi,
      );
      recordCleaner = _RecordingCleaner();
      library = LocalShelfLibrary(
        importer: importer,
        shelfIndex: index,
        recordCleaner: recordCleaner,
      );
    });

    tearDown(() => tempDir.delete(recursive: true));

    Future<ShelfBook> importFixture() async {
      final result =
          await library.importBook(_fixture('fixture_book.readalongbook'));
      expect(result.ok, isTrue, reason: '${result.errors}');
      return result.entry!;
    }

    test('forwards import, list, and interrupted-import recovery', () async {
      final book = await importFixture();

      expect(await library.listBooks(), [book]);
      await library.recoverInterruptedImports();
    });

    test('index deletion failure restores the book directory', () async {
      final book = await importFixture();
      index.failNextDelete = true;

      await expectLater(
        library.deleteBook(book, deleteRecordings: false),
        throwsA(isA<FileSystemException>()),
      );

      expect(Directory(book.bookDir).existsSync(), isTrue);
      expect(await index.findByLibraryId(book.libraryId), book);
    });

    test('deleting recordings passes the library ID to the cleaner', () async {
      final book = await importFixture();

      await library.deleteBook(book, deleteRecordings: true);

      expect(recordCleaner.deletedIds, [book.libraryId]);
      expect(Directory(book.bookDir).existsSync(), isFalse);
      expect(await index.findByLibraryId(book.libraryId), isNull);
    });

    test('cleaner failure after shelf deletion surfaces partial deletion',
        () async {
      final book = await importFixture();
      recordCleaner.error = StateError('record cleanup failed');

      await expectLater(
        library.deleteBook(book, deleteRecordings: true),
        throwsA(isA<PartialBookDeleteException>()),
      );

      expect(Directory(book.bookDir).existsSync(), isFalse);
      expect(await index.findByLibraryId(book.libraryId), isNull);
    });

    test('does not invoke the cleaner when recordings are retained', () async {
      final book = await importFixture();

      await library.deleteBook(book, deleteRecordings: false);

      expect(recordCleaner.deletedIds, isEmpty);
    });
  });
}
