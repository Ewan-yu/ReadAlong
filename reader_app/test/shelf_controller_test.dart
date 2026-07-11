import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/bookpack/book_pack_importer.dart';
import 'package:reader_app/features/shelf/shelf_controller.dart';
import 'package:reader_app/features/shelf/shelf_library.dart';

class _FakeBookPackPicker implements BookPackPicker {
  BookPackSelection? selection;

  @override
  Future<BookPackSelection?> pick() async => selection;
}

class _ImportCall {
  final Uint8List bytes;
  final ImportConflictResolution resolution;
  final String? targetLibraryId;

  const _ImportCall({
    required this.bytes,
    required this.resolution,
    required this.targetLibraryId,
  });
}

class _FakeShelfLibrary implements ShelfLibrary {
  List<ShelfBook> books;
  ImportResult importResult;
  Completer<ImportResult>? importCompleter;
  Object? importError;
  Object? deleteError;
  final importCalls = <_ImportCall>[];
  final deletedBooks = <ShelfBook>[];
  final deleteRecordingsValues = <bool>[];

  _FakeShelfLibrary({
    required this.books,
    required this.importResult,
  });

  @override
  Future<void> recoverInterruptedImports() async {}

  @override
  Future<List<ShelfBook>> listBooks() async => List.of(books);

  @override
  Future<ImportResult> importBook(
    Uint8List bytes, {
    ImportConflictResolution resolution = ImportConflictResolution.reject,
    String? targetLibraryId,
  }) async {
    importCalls.add(_ImportCall(
      bytes: bytes,
      resolution: resolution,
      targetLibraryId: targetLibraryId,
    ));
    if (importError != null) throw importError!;
    final pending = importCompleter;
    if (pending != null) return pending.future;
    return importResult;
  }

  @override
  Future<void> deleteBook(
    ShelfBook book, {
    required bool deleteRecordings,
  }) async {
    deletedBooks.add(book);
    deleteRecordingsValues.add(deleteRecordings);
    if (deleteError != null) throw deleteError!;
    books.remove(book);
  }
}

ShelfBook _book(String libraryId) => ShelfBook(
      libraryId: libraryId,
      sourceBookId: 'source-$libraryId',
      title: 'Book $libraryId',
      pageCount: 2,
      bookDir: '/books/$libraryId',
      thumbnailPath: 'cover.jpg',
      packageSha256: 'hash-$libraryId',
      importedAt: DateTime.utc(2026, 7, 11),
    );

void main() {
  late _FakeShelfLibrary library;
  late _FakeBookPackPicker picker;
  late ProviderContainer container;
  late ShelfController controller;

  setUp(() async {
    library = _FakeShelfLibrary(
      books: [_book('existing')],
      importResult: ImportResult.failed(['not configured']),
    );
    picker = _FakeBookPackPicker();
    container = ProviderContainer(overrides: [
      shelfLibraryProvider.overrideWith((_) async => library),
      bookPackPickerProvider.overrideWith((_) => picker),
    ]);
    addTearDown(container.dispose);
    await container.read(shelfControllerProvider.future);
    controller = container.read(shelfControllerProvider.notifier);
  });

  test('pick cancellation returns cancelled without changing shelf state',
      () async {
    final result = await controller.pickAndImport();

    expect(result.kind, ShelfActionKind.cancelled);
    expect(library.importCalls, isEmpty);
    expect(container.read(shelfControllerProvider).value!.books,
        [_book('existing')]);
  });

  test('import keeps existing books visible while busy and reloads on success',
      () async {
    final existingBook = library.books.single;
    final importedBook = _book('imported');
    final completer = Completer<ImportResult>();
    library.importCompleter = completer;
    picker.selection = BookPackSelection(
      name: 'new.readalongbook',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    final future = controller.pickAndImport();
    await Future<void>.delayed(Duration.zero);

    expect(
        container.read(shelfControllerProvider).value!.books, [existingBook]);
    expect(container.read(shelfControllerProvider).value!.isMutating, isTrue);

    library.books = [importedBook, existingBook];
    completer.complete(ImportResult.success(entry: importedBook));
    final result = await future;

    expect(result.kind, ShelfActionKind.imported);
    expect(result.book, importedBook);
    expect(container.read(shelfControllerProvider).value!.books,
        [importedBook, existingBook]);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);
  });

  test('duplicate import returns alreadyImported without reloading shelf',
      () async {
    final existingBook = library.books.single;
    picker.selection = BookPackSelection(
      name: 'duplicate.readalongbook',
      bytes: Uint8List.fromList([1]),
    );
    library.importResult = ImportResult.alreadyImported(entry: existingBook);

    final result = await controller.pickAndImport();

    expect(result.kind, ShelfActionKind.alreadyImported);
    expect(result.book, existingBook);
    expect(
        container.read(shelfControllerProvider).value!.books, [existingBook]);
  });

  test('conflict returns pending bytes only in the action result', () async {
    final conflictBook = library.books.single;
    final bytes = Uint8List.fromList([4, 5, 6]);
    picker.selection =
        BookPackSelection(name: 'changed.readalongbook', bytes: bytes);
    library.importResult = ImportResult.conflict(conflictEntry: conflictBook);

    final result = await controller.pickAndImport();

    expect(result.kind, ShelfActionKind.conflict);
    expect(result.pendingImport!.bytes, bytes);
    expect(result.pendingImport!.conflict.conflictEntry, conflictBook);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);
  });

  test('validation failure returns all errors and retains the shelf', () async {
    picker.selection = BookPackSelection(
      name: 'invalid.readalongbook',
      bytes: Uint8List.fromList([0]),
    );
    library.importResult =
        ImportResult.failed(['missing manifest', 'bad audio']);

    final result = await controller.pickAndImport();

    expect(result.kind, ShelfActionKind.validationFailed);
    expect(result.errors, ['missing manifest', 'bad audio']);
    expect(container.read(shelfControllerProvider).value!.books,
        [_book('existing')]);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);
  });

  test('resolves overwrite using the pending conflict target', () async {
    final conflictBook = library.books.single;
    final updatedBook = _book('existing');
    library.importResult = ImportResult.success(entry: updatedBook);
    library.books = [updatedBook];
    final pending = PendingImport(
      bytes: Uint8List.fromList([7, 8]),
      conflict: ImportResult.conflict(conflictEntry: conflictBook),
    );

    final result = await controller.resolveConflict(
      pending,
      ImportConflictResolution.overwrite,
    );

    expect(result.kind, ShelfActionKind.imported);
    expect(library.importCalls.single.resolution,
        ImportConflictResolution.overwrite);
    expect(library.importCalls.single.targetLibraryId, conflictBook.libraryId);
    expect(library.importCalls.single.bytes, pending.bytes);
  });

  test('resolves save-copy using the pending conflict target', () async {
    final conflictBook = library.books.single;
    final copiedBook = _book('existing-copy-1');
    library.importResult = ImportResult.success(entry: copiedBook);
    library.books = [copiedBook, conflictBook];
    final pending = PendingImport(
      bytes: Uint8List.fromList([9]),
      conflict: ImportResult.conflict(conflictEntry: conflictBook),
    );

    final result = await controller.resolveConflict(
      pending,
      ImportConflictResolution.saveCopy,
    );

    expect(result.kind, ShelfActionKind.imported);
    expect(library.importCalls.single.resolution,
        ImportConflictResolution.saveCopy);
    expect(library.importCalls.single.targetLibraryId, conflictBook.libraryId);
    expect(container.read(shelfControllerProvider).value!.books,
        [copiedBook, conflictBook]);
  });

  test('deletes a book and refreshes the shelf', () async {
    final book = library.books.single;

    final result = await controller.deleteBook(book, deleteRecordings: true);

    expect(result.kind, ShelfActionKind.imported);
    expect(result.book, book);
    expect(library.deletedBooks, [book]);
    expect(library.deleteRecordingsValues, [isTrue]);
    expect(container.read(shelfControllerProvider).value!.books, isEmpty);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);
  });

  test('maps partial and unexpected delete errors to typed results', () async {
    final book = library.books.single;
    library.deleteError = PartialBookDeleteException(
      book: book,
      cause: StateError('record cleanup failed'),
    );

    final partial = await controller.deleteBook(book, deleteRecordings: true);

    expect(partial.kind, ShelfActionKind.partialDelete);
    expect(partial.book, book);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);

    library.deleteError = StateError('disk failed');
    final failed = await controller.deleteBook(book, deleteRecordings: false);

    expect(failed.kind, ShelfActionKind.failed);
    expect(container.read(shelfControllerProvider).value!.isMutating, isFalse);
  });
}
