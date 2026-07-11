import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

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

class PartialBookDeleteException implements Exception {
  final ShelfBook book;
  final Object cause;

  const PartialBookDeleteException({required this.book, required this.cause});

  @override
  String toString() => 'PartialBookDeleteException(${book.libraryId}): $cause';
}

class LocalShelfLibrary implements ShelfLibrary {
  final BookPackImporter importer;
  final ShelfIndex shelfIndex;
  final BookRecordCleaner recordCleaner;

  const LocalShelfLibrary({
    required this.importer,
    required this.shelfIndex,
    required this.recordCleaner,
  });

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
    final pendingDelete = Directory(
      p.join(
        source.parent.path,
        '.delete-${book.libraryId}-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );

    await source.rename(pendingDelete.path);
    try {
      await shelfIndex.delete(book.libraryId);
    } catch (_) {
      await pendingDelete.rename(source.path);
      rethrow;
    }

    if (deleteRecordings) {
      try {
        await recordCleaner.deleteForBook(book.libraryId);
      } catch (error) {
        await pendingDelete.delete(recursive: true);
        throw PartialBookDeleteException(book: book, cause: error);
      }
    }
    await pendingDelete.delete(recursive: true);
  }
}
