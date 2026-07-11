import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/book_pack_importer.dart';
import 'shelf_library.dart';

class ShelfState {
  final List<ShelfBook> books;
  final bool isMutating;

  ShelfState({required List<ShelfBook> books, this.isMutating = false})
      : books = List.unmodifiable(books);

  ShelfState copyWith({List<ShelfBook>? books, bool? isMutating}) => ShelfState(
        books: books ?? this.books,
        isMutating: isMutating ?? this.isMutating,
      );
}

enum ShelfActionKind {
  cancelled,
  imported,
  alreadyImported,
  conflict,
  validationFailed,
  failed,
  partialDelete,
}

class ShelfActionResult {
  final ShelfActionKind kind;
  final ShelfBook? book;
  final ImportResult? importResult;
  final PendingImport? pendingImport;
  final List<String> errors;

  const ShelfActionResult({
    required this.kind,
    this.book,
    this.importResult,
    this.pendingImport,
    this.errors = const [],
  });
}

class PendingImport {
  final Uint8List bytes;
  final ImportResult conflict;

  const PendingImport({required this.bytes, required this.conflict});
}

final shelfLibraryProvider = FutureProvider<ShelfLibrary>((_) async {
  final documents = await getApplicationDocumentsDirectory();
  final booksDir = p.join(documents.path, 'books');
  final shelfIndex = ShelfIndex(
    databasePath: p.join(documents.path, 'app.db'),
    databaseFactory: sqflite.databaseFactory,
  );
  final importer = BookPackImporter(
    booksDir: booksDir,
    shelfIndex: shelfIndex,
    validationDatabaseFactory: sqflite.databaseFactory,
  );
  return LocalShelfLibrary(
    importer: importer,
    shelfIndex: shelfIndex,
    recordCleaner: const NoopBookRecordCleaner(),
  );
});

final bookPackPickerProvider = Provider<BookPackPicker>(
  (_) => const FilePickerBookPackPicker(),
);

final shelfControllerProvider =
    AsyncNotifierProvider<ShelfController, ShelfState>(ShelfController.new);

class ShelfController extends AsyncNotifier<ShelfState> {
  late final ShelfLibrary _library;

  @override
  Future<ShelfState> build() async {
    _library = await ref.watch(shelfLibraryProvider.future);
    await _library.recoverInterruptedImports();
    return ShelfState(books: await _library.listBooks());
  }

  Future<ShelfActionResult> pickAndImport() async {
    _setMutating(true);
    try {
      final selection = await ref.read(bookPackPickerProvider).pick();
      if (selection == null) {
        return const ShelfActionResult(kind: ShelfActionKind.cancelled);
      }
      final result = await _library.importBook(selection.bytes);
      return _handleImportResult(result, bytes: selection.bytes);
    } catch (error) {
      return _failed(error);
    } finally {
      _setMutating(false);
    }
  }

  Future<ShelfActionResult> resolveConflict(
    PendingImport pending,
    ImportConflictResolution resolution,
  ) async {
    _setMutating(true);
    try {
      final conflictEntry = pending.conflict.conflictEntry;
      if (conflictEntry == null) {
        return const ShelfActionResult(
          kind: ShelfActionKind.failed,
          errors: ['Conflict result has no target book'],
        );
      }
      final result = await _library.importBook(
        pending.bytes,
        resolution: resolution,
        targetLibraryId: conflictEntry.libraryId,
      );
      return _handleImportResult(result, bytes: pending.bytes);
    } catch (error) {
      return _failed(error);
    } finally {
      _setMutating(false);
    }
  }

  Future<ShelfActionResult> deleteBook(
    ShelfBook book, {
    required bool deleteRecordings,
  }) async {
    _setMutating(true);
    try {
      await _library.deleteBook(book, deleteRecordings: deleteRecordings);
      await _reloadBooks();
      return ShelfActionResult(kind: ShelfActionKind.imported, book: book);
    } on PartialBookDeleteException catch (error) {
      return ShelfActionResult(
        kind: ShelfActionKind.partialDelete,
        book: error.book,
        errors: [error.cause.toString()],
      );
    } catch (error) {
      return _failed(error);
    } finally {
      _setMutating(false);
    }
  }

  Future<ShelfActionResult> _handleImportResult(
    ImportResult result, {
    required Uint8List bytes,
  }) async {
    if (result.ok) {
      await _reloadBooks();
      return ShelfActionResult(
        kind: ShelfActionKind.imported,
        book: result.entry,
        importResult: result,
      );
    }
    if (result.isAlreadyImported) {
      return ShelfActionResult(
        kind: ShelfActionKind.alreadyImported,
        book: result.entry,
        importResult: result,
      );
    }
    if (result.isConflict && result.conflictEntry != null) {
      return ShelfActionResult(
        kind: ShelfActionKind.conflict,
        importResult: result,
        pendingImport: PendingImport(bytes: bytes, conflict: result),
      );
    }
    return ShelfActionResult(
      kind: ShelfActionKind.validationFailed,
      importResult: result,
      errors: result.errors,
    );
  }

  Future<void> _reloadBooks() async {
    final books = await _library.listBooks();
    final current = state.valueOrNull;
    state = AsyncData(ShelfState(
      books: books,
      isMutating: current?.isMutating ?? false,
    ));
  }

  void _setMutating(bool isMutating) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncData(current.copyWith(isMutating: isMutating));
  }

  ShelfActionResult _failed(Object error) => ShelfActionResult(
        kind: ShelfActionKind.failed,
        errors: [error.toString()],
      );
}
