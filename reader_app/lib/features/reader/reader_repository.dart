import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import 'reader_models.dart';

abstract interface class ReaderRepository {
  Future<ReaderBook> loadBook(String libraryId);
}

final readerRepositoryProvider = FutureProvider<ReaderRepository>((ref) async {
  final shelfIndex = await ref.watch(shelfIndexProvider.future);
  return LocalReaderRepository(shelfIndex: shelfIndex);
});

final readerBookProvider = FutureProvider.family<ReaderBook, String>(
  (ref, libraryId) async {
    final repository = await ref.watch(readerRepositoryProvider.future);
    return repository.loadBook(libraryId);
  },
);

class LocalReaderRepository implements ReaderRepository {
  const LocalReaderRepository({required this.shelfIndex});

  final ShelfIndex shelfIndex;

  @override
  Future<ReaderBook> loadBook(String libraryId) async {
    final shelfBook = await shelfIndex.findByLibraryId(libraryId);
    if (shelfBook == null) throw ReaderBookNotFoundException(libraryId);

    try {
      final manifestFile = File(p.join(shelfBook.bookDir, 'manifest.json'));
      final decoded = jsonDecode(await manifestFile.readAsString());
      if (decoded is! Map<String, dynamic>) {
        throw const ReaderManifestException(
          'Manifest root must be an object',
        );
      }
      if (decoded['book_id'] != shelfBook.sourceBookId) {
        throw const ReaderManifestException(
          'Manifest source identity mismatch',
        );
      }

      final pageCount = decoded['page_count'];
      final rawPages = decoded['pages'];
      if (pageCount is! int ||
          pageCount != shelfBook.pageCount ||
          rawPages is! List ||
          rawPages.length != pageCount) {
        throw const ReaderManifestException('Manifest page count mismatch');
      }

      final pages = rawPages
          .map((raw) => _parsePage(shelfBook.bookDir, raw))
          .toList(growable: false)
        ..sort((left, right) => left.pageNumber.compareTo(right.pageNumber));
      for (var index = 0; index < pages.length; index++) {
        if (pages[index].pageNumber != index + 1) {
          throw const ReaderManifestException(
            'Manifest page numbers are not contiguous',
          );
        }
      }

      return ReaderBook(
        libraryId: shelfBook.libraryId,
        sourceBookId: shelfBook.sourceBookId,
        title: shelfBook.title,
        pages: pages,
      );
    } on ReaderLoadException {
      rethrow;
    } on Object catch (error) {
      throw ReaderManifestException('Manifest could not be loaded: $error');
    }
  }
}

ReaderPageData _parsePage(String bookDir, Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const ReaderManifestException('Manifest page must be an object');
  }
  final pageNumber = raw['page_no'];
  final widthPx = raw['width_px'];
  final heightPx = raw['height_px'];
  if (pageNumber is! int || pageNumber < 1) {
    throw const ReaderManifestException('Manifest page number is invalid');
  }
  if (widthPx is! int || widthPx < 1 || heightPx is! int || heightPx < 1) {
    throw const ReaderManifestException('Manifest page size is invalid');
  }
  return ReaderPageData(
    pageNumber: pageNumber,
    imagePath: _resolveInside(bookDir, raw['image']),
    thumbnailPath: _resolveInside(bookDir, raw['thumbnail']),
    widthPx: widthPx,
    heightPx: heightPx,
  );
}

String _resolveInside(String bookDir, Object? relativePath) {
  if (relativePath is! String ||
      relativePath.isEmpty ||
      p.isAbsolute(relativePath)) {
    throw const ReaderManifestException('Invalid resource path');
  }
  final root = p.normalize(p.absolute(bookDir));
  final resolved = p.normalize(p.absolute(p.join(root, relativePath)));
  if (!p.isWithin(root, resolved)) {
    throw const ReaderManifestException(
      'Resource path escapes book directory',
    );
  }
  return resolved;
}
