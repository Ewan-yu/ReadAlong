import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/book_pack_importer.dart';

class BookPackSelection {
  final String name;
  final Uint8List bytes;

  const BookPackSelection({required this.name, required this.bytes});
}

abstract interface class BookPackPicker {
  Future<BookPackSelection?> pick();
}

typedef BookPackFilePicker = Future<FilePickerResult?> Function();

class FilePickerBookPackPicker implements BookPackPicker {
  final BookPackFilePicker _pickFiles;

  const FilePickerBookPackPicker({BookPackFilePicker? pickFiles})
      : _pickFiles = pickFiles ?? _pickFromPlatform;

  @override
  Future<BookPackSelection?> pick() async {
    final result = await _pickFiles();
    if (result == null) return null;

    final file = result.files.single;
    final bytes = file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) {
      throw FileSystemException(
          'Selected book package has no readable data', file.name);
    }
    return BookPackSelection(name: file.name, bytes: bytes);
  }

  static Future<FilePickerResult?> _pickFromPlatform() =>
      FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['readalongbook'],
        withData: true,
      );
}

abstract interface class BookRecordCleaner {
  Future<void> deleteForBook(String libraryId);
}

class NoopBookRecordCleaner implements BookRecordCleaner {
  const NoopBookRecordCleaner();

  @override
  Future<void> deleteForBook(String libraryId) async {}
}

abstract interface class ShelfLibrary {
  Future<void> recoverInterruptedImports();
  Future<List<ShelfBook>> listBooks();
  Future<ImportResult> importBook(
    Uint8List bytes, {
    ImportConflictResolution resolution = ImportConflictResolution.reject,
    String? targetLibraryId,
  });
  Future<void> deleteBook(ShelfBook book, {required bool deleteRecordings});
}

typedef DeleteDirectory = Future<void> Function(Directory directory);

class PartialBookDeleteException implements Exception {
  final ShelfBook book;
  final List<Object> causes;

  PartialBookDeleteException({
    required this.book,
    required List<Object> causes,
  })  : assert(causes.isNotEmpty),
        causes = List.unmodifiable(causes);

  @override
  String toString() =>
      'PartialBookDeleteException(${book.libraryId}): ${causes.join('; ')}';
}

class LocalShelfLibrary implements ShelfLibrary {
  final BookPackImporter importer;
  final ShelfIndex shelfIndex;
  final BookRecordCleaner recordCleaner;
  final DeleteDirectory _deleteDirectory;

  LocalShelfLibrary({
    required this.importer,
    required this.shelfIndex,
    required this.recordCleaner,
    DeleteDirectory? deleteDirectory,
  }) : _deleteDirectory = deleteDirectory ?? _deleteDirectoryRecursively;

  @override
  Future<void> recoverInterruptedImports() =>
      importer.recoverInterruptedImports();

  @override
  Future<List<ShelfBook>> listBooks() => shelfIndex.listBooks();

  @override
  Future<ImportResult> importBook(
    Uint8List bytes, {
    ImportConflictResolution resolution = ImportConflictResolution.reject,
    String? targetLibraryId,
  }) =>
      importer.import(
        bytes,
        resolution: resolution,
        targetLibraryId: targetLibraryId,
      );

  @override
  Future<void> deleteBook(
    ShelfBook book, {
    required bool deleteRecordings,
  }) async {
    final source = Directory(book.bookDir);
    final pendingDelete = Directory(importer.deleteStagingPath(book.libraryId));

    await source.rename(pendingDelete.path);
    try {
      await shelfIndex.delete(book.libraryId);
    } catch (_) {
      await pendingDelete.rename(source.path);
      rethrow;
    }

    final failures = <Object>[];
    if (deleteRecordings) {
      try {
        await recordCleaner.deleteForBook(book.libraryId);
      } catch (error) {
        failures.add(error);
      }
    }
    try {
      await _deleteDirectory(pendingDelete);
    } catch (error) {
      failures.add(error);
    }
    if (failures.isNotEmpty) {
      throw PartialBookDeleteException(book: book, causes: failures);
    }
  }
}

Future<void> _deleteDirectoryRecursively(Directory directory) =>
    directory.delete(recursive: true);
