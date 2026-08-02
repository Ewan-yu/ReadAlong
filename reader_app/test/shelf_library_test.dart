import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/appdb/dubbing_models.dart';
import 'package:reader_app/data/bookpack/book_pack_importer.dart';
import 'package:reader_app/features/dubbing/dubbing_file_store.dart';
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

  group('FilePickerBookPackPicker', () {
    test('cancellation returns null', () async {
      final picker = FilePickerBookPackPicker(
        pickFiles: () async => null,
      );

      expect(await picker.pick(), isNull);
    });

    test('returns selected in-memory bytes', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final picker = FilePickerBookPackPicker(
        pickFiles: () async => FilePickerResult([
          PlatformFile(
            name: 'book.readalongbook',
            size: bytes.length,
            bytes: bytes,
          ),
        ]),
      );

      final selection = await picker.pick();

      expect(selection?.name, 'book.readalongbook');
      expect(selection?.bytes, bytes);
    });

    test('loads file bytes when selected bytes are absent', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('readalong_picker_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final selectedFile = File('${tempDir.path}/book.readalongbook');
      await selectedFile.writeAsBytes([4, 5, 6]);
      final picker = FilePickerBookPackPicker(
        pickFiles: () async => FilePickerResult([
          PlatformFile(
            name: 'book.readalongbook',
            size: selectedFile.lengthSync(),
            path: selectedFile.path,
          ),
        ]),
      );

      final selection = await picker.pick();

      expect(selection?.name, 'book.readalongbook');
      expect(selection?.bytes, [4, 5, 6]);
    });
  });

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

    Iterable<Directory> pendingDeleteDirectories() {
      final booksDir = Directory('${tempDir.path}/books');
      return booksDir.listSync().whereType<Directory>().where(
            (directory) => directory.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.delete-'),
          );
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
      expect(pendingDeleteDirectories(), isEmpty);
    });

    test('deleting recordings removes durable dubbing data and files',
        () async {
      final book = await importFixture();
      final fileStore = DubbingFileStore(documentsDirectory: tempDir);
      final project = await index.createDubbingProject(
        id: 'project-1',
        libraryId: book.libraryId,
        sourceBookId: book.sourceBookId,
        resourceSha256: 'resource-sha',
        timelineSha256: 'timeline-sha',
        mode: DubbingMode.sentence,
      );
      final takePath = fileStore.takeRelativePath(
        libraryId: book.libraryId,
        projectId: project.id,
        takeId: 'take-1',
        kind: DubbingTakeKind.sentence,
        sentenceId: 's0001',
      );
      final takeFile = File(fileStore.resolveRelativePath(takePath));
      await takeFile.parent.create(recursive: true);
      await takeFile.writeAsBytes([1, 2, 3]);
      await index.createDubbingTake(
        id: 'take-1',
        projectId: project.id,
        takeKind: DubbingTakeKind.sentence,
        sentenceId: 's0001',
        audioRelativePath: takePath,
        duration: const Duration(milliseconds: 800),
      );
      final mixPath = fileStore.mixRelativePath(
        libraryId: book.libraryId,
        projectId: project.id,
        mixId: 'mix-1',
      );
      final mixFile = File(fileStore.resolveRelativePath(mixPath));
      await mixFile.parent.create(recursive: true);
      await mixFile.writeAsBytes([4, 5, 6]);
      await index.createDubbingMix(
        id: 'mix-1',
        projectId: project.id,
        audioRelativePath: mixPath,
        variant: DubbingMixVariant.voiceOnly,
        sourceTakeFingerprint: 'take-fingerprint',
        duration: const Duration(seconds: 1),
      );

      library = LocalShelfLibrary(
        importer: importer,
        shelfIndex: index,
        recordCleaner: LocalBookRecordCleaner(
          documentsDirectory: tempDir,
          shelfIndex: index,
          dubbingFileStore: fileStore,
        ),
      );

      await library.deleteBook(book, deleteRecordings: true);

      expect(await index.listDubbingProjects(book.libraryId), isEmpty);
      expect(await index.listDubbingTakes(project.id), isEmpty);
      expect(await index.listDubbingMixes(project.id), isEmpty);
      expect(
        Directory(p.join(tempDir.path, 'dubbing', book.libraryId)).existsSync(),
        isFalse,
      );
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

    test('final staged-directory deletion failure is a partial deletion',
        () async {
      final book = await importFixture();
      library = LocalShelfLibrary(
        importer: importer,
        shelfIndex: index,
        recordCleaner: recordCleaner,
        deleteDirectory: (_) async => throw FileSystemException(
          'final delete failed',
        ),
      );

      await expectLater(
        library.deleteBook(book, deleteRecordings: false),
        throwsA(isA<PartialBookDeleteException>()),
      );

      expect(await index.findByLibraryId(book.libraryId), isNull);
      expect(Directory(book.bookDir).existsSync(), isFalse);
      expect(pendingDeleteDirectories(), hasLength(1));
    });

    test('cleaner and staged-directory cleanup are both attempted and reported',
        () async {
      final book = await importFixture();
      recordCleaner.error = StateError('record cleanup failed');
      var deleteAttempts = 0;
      library = LocalShelfLibrary(
        importer: importer,
        shelfIndex: index,
        recordCleaner: recordCleaner,
        deleteDirectory: (_) async {
          deleteAttempts++;
          throw FileSystemException('final delete failed');
        },
      );

      try {
        await library.deleteBook(book, deleteRecordings: true);
        fail('deleteBook should report partial deletion');
      } on PartialBookDeleteException catch (error) {
        expect(error.causes, hasLength(2));
        expect(error.toString(), contains('record cleanup failed'));
        expect(error.toString(), contains('final delete failed'));
      }

      expect(recordCleaner.deletedIds, [book.libraryId]);
      expect(deleteAttempts, 1);
      expect(await index.findByLibraryId(book.libraryId), isNull);
      expect(pendingDeleteDirectories(), hasLength(1));
    });

    test('startup recovery restores indexed direct delete staging directory',
        () async {
      final book = await importFixture();
      final staged = Directory(
        '${tempDir.path}/books/.delete-100-${book.libraryId}',
      );
      await Directory(book.bookDir).rename(staged.path);

      await library.recoverInterruptedImports();

      expect(staged.existsSync(), isFalse);
      expect(Directory(book.bookDir).existsSync(), isTrue);
      expect(await index.findByLibraryId(book.libraryId), book);
    });

    test('startup recovery removes unindexed direct delete staging directory',
        () async {
      final book = await importFixture();
      final staged = Directory(
        '${tempDir.path}/books/.delete-101-${book.libraryId}',
      );
      await Directory(book.bookDir).rename(staged.path);
      await index.delete(book.libraryId);

      await library.recoverInterruptedImports();

      expect(staged.existsSync(), isFalse);
      expect(Directory(book.bookDir).existsSync(), isFalse);
      expect(await index.findByLibraryId(book.libraryId), isNull);
    });

    test('startup recovery ignores non-owned and nested delete paths',
        () async {
      final booksDir = Directory('${tempDir.path}/books');
      await booksDir.create(recursive: true);
      final nonOwned = Directory('${booksDir.path}/.delete-not-owned');
      final nested = Directory(
        '${booksDir.path}/ordinary/.delete-102-fixture-book-0001',
      );
      await nonOwned.create();
      await nested.create(recursive: true);

      await library.recoverInterruptedImports();

      expect(nonOwned.existsSync(), isTrue);
      expect(nested.existsSync(), isTrue);
    });

    test('does not invoke the cleaner when recordings are retained', () async {
      final book = await importFixture();

      await library.deleteBook(book, deleteRecordings: false);

      expect(recordCleaner.deletedIds, isEmpty);
    });
  });
}
