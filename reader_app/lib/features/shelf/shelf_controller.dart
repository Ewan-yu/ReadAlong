import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/book_pack_importer.dart';
import '../dubbing/dubbing_file_store.dart';
import '../reader/alignment_repository.dart';
import '../reader/original_audio_repository.dart';
import '../reader/reader_repository.dart';
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
  busy,
  imported,
  deleted,
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

final shelfLibraryProvider = FutureProvider<ShelfLibrary>((ref) async {
  final documents = await ref.watch(appDocumentsDirectoryProvider.future);
  final booksDir = p.join(documents.path, 'books');
  final shelfIndex = await ref.watch(shelfIndexProvider.future);
  final databaseFactory = ref.watch(appDatabaseFactoryProvider);
  final importer = BookPackImporter(
    booksDir: booksDir,
    shelfIndex: shelfIndex,
    validationDatabaseFactory: databaseFactory,
  );
  return LocalShelfLibrary(
    importer: importer,
    shelfIndex: shelfIndex,
    recordCleaner: _LocalBookRecordCleaner(
      documentsDirectory: documents,
      shelfIndex: shelfIndex,
      dubbingFileStore: DubbingFileStore(documentsDirectory: documents),
    ),
  );
});

final class _LocalBookRecordCleaner implements BookRecordCleaner {
  _LocalBookRecordCleaner({
    required this.documentsDirectory,
    required this.shelfIndex,
    required this.dubbingFileStore,
  });

  final Directory documentsDirectory;
  final ShelfIndex shelfIndex;
  final DubbingFileStore dubbingFileStore;

  @override
  Future<void> deleteForBook(String libraryId) async {
    await shelfIndex.deleteRecordsForBook(libraryId);
    final directory =
        Directory(p.join(documentsDirectory.path, 'records', libraryId));
    if (await directory.exists()) await directory.delete(recursive: true);

    Object? firstFailure;
    final projects = await shelfIndex.listDubbingProjects(libraryId);
    for (final project in projects) {
      try {
        await shelfIndex.deleteDubbingProject(project.id);
      } catch (error) {
        firstFailure ??= error;
        continue;
      }
      try {
        await dubbingFileStore.deleteProject(
          libraryId: project.libraryId,
          projectId: project.id,
        );
      } catch (error) {
        firstFailure ??= error;
      }
    }
    if (firstFailure != null) throw firstFailure;
  }
}

final bookPackPickerProvider = Provider<BookPackPicker>(
  (_) => const FilePickerBookPackPicker(),
);

final shelfControllerProvider =
    AsyncNotifierProvider<ShelfController, ShelfState>(ShelfController.new);

class ShelfController extends AsyncNotifier<ShelfState> {
  ShelfLibrary? _library;
  bool _isMutationActive = false;

  @override
  Future<ShelfState> build() async {
    final library = await ref.watch(shelfLibraryProvider.future);
    _library = library;
    await library.recoverInterruptedImports();
    return ShelfState(
      books: await library.listBooks(),
      isMutating: _isMutationActive,
    );
  }

  Future<ShelfActionResult> pickAndImport() async {
    final busy = _beginMutation();
    if (busy != null) return busy;
    final library = _library;
    try {
      if (library == null) return _libraryUnavailable();
      final selection = await ref.read(bookPackPickerProvider).pick();
      if (selection == null) {
        return const ShelfActionResult(kind: ShelfActionKind.cancelled);
      }
      final result = await library.importBook(selection.bytes);
      return _handleImportResult(
        library,
        result,
        bytes: selection.bytes,
      );
    } catch (error) {
      return _failed(error);
    } finally {
      _endMutation();
    }
  }

  Future<ShelfActionResult> resolveConflict(
    PendingImport pending,
    ImportConflictResolution resolution,
  ) async {
    final busy = _beginMutation();
    if (busy != null) return busy;
    final library = _library;
    try {
      if (library == null) return _libraryUnavailable();
      final conflictEntry = pending.conflict.conflictEntry;
      if (conflictEntry == null) {
        return const ShelfActionResult(
          kind: ShelfActionKind.failed,
          errors: ['Conflict result has no target book'],
        );
      }
      final result = await library.importBook(
        pending.bytes,
        resolution: resolution,
        targetLibraryId: conflictEntry.libraryId,
      );
      return _handleImportResult(library, result, bytes: pending.bytes);
    } catch (error) {
      return _failed(error);
    } finally {
      _endMutation();
    }
  }

  Future<ShelfActionResult> deleteBook(
    ShelfBook book, {
    required bool deleteRecordings,
  }) async {
    final busy = _beginMutation();
    if (busy != null) return busy;
    final library = _library;
    try {
      if (library == null) return _libraryUnavailable();
      await library.deleteBook(book, deleteRecordings: deleteRecordings);
      _invalidateBookResources(book.libraryId);
      await _reloadBooks(library);
      return ShelfActionResult(kind: ShelfActionKind.deleted, book: book);
    } on PartialBookDeleteException catch (error) {
      await _reloadAfterPartialDelete(library, error.book);
      return ShelfActionResult(
        kind: ShelfActionKind.partialDelete,
        book: error.book,
        errors: error.causes.map((cause) => cause.toString()).toList(),
      );
    } catch (error) {
      return _failed(error);
    } finally {
      _endMutation();
    }
  }

  Future<ShelfActionResult> _handleImportResult(
    ShelfLibrary library,
    ImportResult result, {
    required Uint8List bytes,
  }) async {
    if (result.ok) {
      final book = result.entry;
      if (book != null) _invalidateBookResources(book.libraryId);
      await _reloadBooks(library);
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
      kind: result.failureCategory == ImportFailureCategory.validation
          ? ShelfActionKind.validationFailed
          : ShelfActionKind.failed,
      importResult: result,
      errors: result.errors,
    );
  }

  Future<void> _reloadBooks(ShelfLibrary library) async {
    final books = await library.listBooks();
    final current = state.valueOrNull;
    state = AsyncData(ShelfState(
      books: books,
      isMutating: current?.isMutating ?? false,
    ));
  }

  /// A resource overwrite preserves its library ID. The reader and original
  /// audio providers are intentionally cached for quick route re-entry, so
  /// they must be invalidated once the on-disk package changes. Otherwise a
  /// reopened book can retain the old page manifest or subtitle timeline.
  void _invalidateBookResources(String libraryId) {
    ref.invalidate(readerBookProvider(libraryId));
    ref.invalidate(pointReadingBookProvider(libraryId));
    ref.invalidate(originalAudioReadyProvider(libraryId));
    ref.invalidate(originalAudioBookProvider(libraryId));
  }

  Future<void> _reloadAfterPartialDelete(
    ShelfLibrary? library,
    ShelfBook deletedBook,
  ) async {
    try {
      if (library == null) throw StateError('Shelf library is unavailable');
      await _reloadBooks(library);
    } catch (_) {
      final current = state.valueOrNull;
      if (current == null) return;
      state = AsyncData(ShelfState(
        books: current.books
            .where((book) => book.libraryId != deletedBook.libraryId)
            .toList(growable: false),
        isMutating: current.isMutating,
      ));
    }
  }

  ShelfActionResult? _beginMutation() {
    if (_isMutationActive) {
      return const ShelfActionResult(
        kind: ShelfActionKind.busy,
        errors: ['Another shelf action is already in progress'],
      );
    }
    _isMutationActive = true;
    _setMutating(true);
    return null;
  }

  void _endMutation() {
    _isMutationActive = false;
    _setMutating(false);
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

  ShelfActionResult _libraryUnavailable() => const ShelfActionResult(
        kind: ShelfActionKind.failed,
        errors: ['Shelf library is unavailable'],
      );
}
