import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class CanonicalArchiveEntries {
  final Map<String, ArchiveFile> entries;
  final List<String> errors;

  CanonicalArchiveEntries._(this.entries, this.errors);

  factory CanonicalArchiveEntries.fromArchive(
    Archive archive, {
    Iterable<String>? archivePaths,
  }) {
    final errors = <String>[];
    final seenPaths = <String>{};

    for (final rawPath in archivePaths ?? archive.map((file) => file.name)) {
      final canonicalPath = canonicalArchivePath(rawPath);
      if (canonicalPath == null) {
        errors.add('路径逃逸: $rawPath');
        continue;
      }
      if (!seenPaths.add(canonicalPath)) {
        errors.add('压缩包包含重复路径: $canonicalPath');
      }
    }

    final entries = <String, ArchiveFile>{};
    for (final file in archive) {
      final canonicalPath = canonicalArchivePath(file.name);
      if (canonicalPath != null) entries[canonicalPath] = file;
    }

    return CanonicalArchiveEntries._(
      Map.unmodifiable(entries),
      List.unmodifiable(errors),
    );
  }
}

String? canonicalArchivePath(String rawPath) {
  final slashPath = rawPath.replaceAll('\\', '/');
  if (rawPath.isEmpty ||
      rawPath.contains('..') ||
      p.posix.isAbsolute(slashPath) ||
      p.windows.isAbsolute(rawPath)) {
    return null;
  }

  final normalized = p.posix.normalize(slashPath);
  if (normalized == '.' || normalized == '..' || normalized.startsWith('../')) {
    return null;
  }
  return normalized;
}
