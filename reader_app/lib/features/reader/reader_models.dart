class ReaderPageData {
  const ReaderPageData({
    required this.pageNumber,
    required this.imagePath,
    required this.thumbnailPath,
    required this.widthPx,
    required this.heightPx,
  });

  final int pageNumber;
  final String imagePath;
  final String thumbnailPath;
  final int widthPx;
  final int heightPx;
}

class ReaderBook {
  ReaderBook({
    required this.libraryId,
    required this.sourceBookId,
    required this.title,
    required List<ReaderPageData> pages,
  }) : pages = List.unmodifiable(pages);

  final String libraryId;
  final String sourceBookId;
  final String title;
  final List<ReaderPageData> pages;
}

abstract class ReaderLoadException implements Exception {
  const ReaderLoadException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class ReaderBookNotFoundException extends ReaderLoadException {
  const ReaderBookNotFoundException(String libraryId)
      : super('Shelf book not found: $libraryId');
}

class ReaderManifestException extends ReaderLoadException {
  const ReaderManifestException(super.message);
}
