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
    final seenPaths = <String, String>{};

    for (final rawPath in archivePaths ?? archive.map((file) => file.name)) {
      final canonicalPath = canonicalArchivePath(rawPath);
      if (canonicalPath == null) {
        errors.add('路径逃逸: $rawPath');
        continue;
      }
      final comparisonKey = archivePathComparisonKey(canonicalPath);
      final existingPath = seenPaths[comparisonKey];
      if (existingPath == null) {
        seenPaths[comparisonKey] = canonicalPath;
      } else if (existingPath == canonicalPath) {
        errors.add('压缩包包含重复路径: $canonicalPath');
      } else {
        errors.add('压缩包包含重复路径: $existingPath 与 $canonicalPath');
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

/// Uses ASCII case-folding only so package collision detection is portable
/// across common case-insensitive and case-sensitive filesystems.
String archivePathComparisonKey(String canonicalPath) {
  final buffer = StringBuffer();
  for (final codeUnit in canonicalPath.codeUnits) {
    buffer.writeCharCode(
      codeUnit >= 0x41 && codeUnit <= 0x5a ? codeUnit + 0x20 : codeUnit,
    );
  }
  return buffer.toString();
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
