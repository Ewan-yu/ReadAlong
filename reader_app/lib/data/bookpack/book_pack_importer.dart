import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../appdb/shelf_index.dart';
import 'book_pack_validator.dart';

enum ImportConflictResolution { reject, overwrite, saveCopy }

class ImportResult {
  final bool ok;
  final bool isConflict;
  final bool isAlreadyImported;
  final ShelfBook? entry;
  final ShelfBook? conflictEntry;
  final List<String> errors;

  const ImportResult._({
    required this.ok,
    required this.isConflict,
    required this.isAlreadyImported,
    this.entry,
    this.conflictEntry,
    this.errors = const [],
  });

  factory ImportResult.success({required ShelfBook entry}) => ImportResult._(
        ok: true,
        isConflict: false,
        isAlreadyImported: false,
        entry: entry,
      );

  factory ImportResult.alreadyImported({required ShelfBook entry}) =>
      ImportResult._(
        ok: false,
        isConflict: false,
        isAlreadyImported: true,
        entry: entry,
      );

  factory ImportResult.conflict({required ShelfBook conflictEntry}) =>
      ImportResult._(
        ok: false,
        isConflict: true,
        isAlreadyImported: false,
        conflictEntry: conflictEntry,
      );

  factory ImportResult.failed(List<String> errors) => ImportResult._(
        ok: false,
        isConflict: false,
        isAlreadyImported: false,
        errors: List.unmodifiable(errors),
      );
}

/// 校验、解包，并将资源目录与书架索引一起提交。
class BookPackImporter {
  final String booksDir;
  final ShelfIndex shelfIndex;
  final sqflite.DatabaseFactory? validationDatabaseFactory;

  const BookPackImporter({
    required this.booksDir,
    required this.shelfIndex,
    this.validationDatabaseFactory,
  });

  Future<ImportResult> import(
    Uint8List zipBytes, {
    ImportConflictResolution resolution = ImportConflictResolution.reject,
    String? targetLibraryId,
  }) async {
    final validation = await BookPackValidator.validateBytes(
      zipBytes,
      databaseFactory: validationDatabaseFactory,
    );
    if (!validation.ok) return ImportResult.failed(validation.errors);

    final archive = ZipDecoder().decodeBytes(zipBytes);
    final manifest = _readManifest(archive);
    final sourceBookId = manifest['book_id'] as String;
    final packageSha256 = sha256.convert(zipBytes).toString();
    final sourceEntries = await shelfIndex.findBySourceBookId(sourceBookId);

    switch (resolution) {
      case ImportConflictResolution.reject:
        final identical = sourceEntries.where(
          (entry) => entry.packageSha256 == packageSha256,
        );
        if (identical.isNotEmpty) {
          return ImportResult.alreadyImported(entry: identical.first);
        }
        if (sourceEntries.isNotEmpty) {
          return ImportResult.conflict(
            conflictEntry: _preferredConflict(sourceEntries, sourceBookId),
          );
        }
        final bookDir = p.join(booksDir, sourceBookId);
        if (await Directory(bookDir).exists()) {
          return ImportResult.failed(['书籍目录已存在但未被书架索引管理: $bookDir']);
        }
        return _installNew(
          archive: archive,
          manifest: manifest,
          libraryId: sourceBookId,
          packageSha256: packageSha256,
        );
      case ImportConflictResolution.overwrite:
        final target = _overwriteTarget(
          entries: sourceEntries,
          sourceBookId: sourceBookId,
          targetLibraryId: targetLibraryId,
        );
        if (target == null) {
          return ImportResult.failed(['未找到可覆盖的本地书籍']);
        }
        return _overwrite(
          archive: archive,
          manifest: manifest,
          existing: target,
          packageSha256: packageSha256,
        );
      case ImportConflictResolution.saveCopy:
        return _saveCopy(
          archive: archive,
          manifest: manifest,
          sourceBookId: sourceBookId,
          packageSha256: packageSha256,
        );
    }
  }

  Future<void> recoverInterruptedImports() async {
    final root = Directory(booksDir);
    if (!await root.exists()) return;

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (_importDirectoryPattern.hasMatch(name)) {
        await entity.delete(recursive: true);
        continue;
      }

      final backupMatch = _backupDirectoryPattern.firstMatch(name);
      if (backupMatch == null) continue;
      final targetPath = p.join(booksDir, backupMatch.group(1)!);
      if (await FileSystemEntity.type(targetPath, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await entity.rename(targetPath);
      } else {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<ImportResult> _installNew({
    required Archive archive,
    required Map<String, dynamic> manifest,
    required String libraryId,
    required String packageSha256,
  }) async {
    final bookDir = p.join(booksDir, libraryId);
    final stagingDir = _stagingPath(libraryId);
    var movedToBookDir = false;
    try {
      await _extract(archive, stagingDir);
      await Directory(stagingDir).rename(bookDir);
      movedToBookDir = true;
      final entry = _entryFromManifest(
        manifest: manifest,
        archive: archive,
        libraryId: libraryId,
        bookDir: bookDir,
        packageSha256: packageSha256,
      );
      await shelfIndex.add(entry);
      return ImportResult.success(entry: entry);
    } catch (error) {
      await _deleteIfExists(movedToBookDir ? bookDir : stagingDir);
      return ImportResult.failed(['导入资源包失败: $error']);
    }
  }

  Future<ImportResult> _saveCopy({
    required Archive archive,
    required Map<String, dynamic> manifest,
    required String sourceBookId,
    required String packageSha256,
  }) async {
    var copyNumber = await shelfIndex.nextCopyNumber(sourceBookId);
    var libraryId = '$sourceBookId-copy-$copyNumber';
    while (await shelfIndex.findByLibraryId(libraryId) != null ||
        await Directory(p.join(booksDir, libraryId)).exists()) {
      copyNumber++;
      libraryId = '$sourceBookId-copy-$copyNumber';
    }
    return _installNew(
      archive: archive,
      manifest: manifest,
      libraryId: libraryId,
      packageSha256: packageSha256,
    );
  }

  Future<ImportResult> _overwrite({
    required Archive archive,
    required Map<String, dynamic> manifest,
    required ShelfBook existing,
    required String packageSha256,
  }) async {
    final targetDir = existing.bookDir;
    final stagingDir = _stagingPath(existing.libraryId);
    final backupDir = _backupPath(existing.libraryId);
    var backupCreated = false;
    try {
      await _extract(archive, stagingDir);
      await Directory(targetDir).rename(backupDir);
      backupCreated = true;
      await Directory(stagingDir).rename(targetDir);
      final updated = _entryFromManifest(
        manifest: manifest,
        archive: archive,
        libraryId: existing.libraryId,
        bookDir: targetDir,
        packageSha256: packageSha256,
      );
      await shelfIndex.replace(updated);
      await Directory(backupDir).delete(recursive: true);
      return ImportResult.success(entry: updated);
    } catch (error) {
      if (backupCreated) {
        await _restoreOverwrite(existing, targetDir, backupDir);
      } else {
        await _deleteIfExists(stagingDir);
      }
      return ImportResult.failed(['覆盖资源包失败: $error']);
    }
  }

  Future<void> _restoreOverwrite(
    ShelfBook previous,
    String targetDir,
    String backupDir,
  ) async {
    try {
      await _deleteIfExists(targetDir);
    } catch (_) {}
    try {
      final backup = Directory(backupDir);
      if (await backup.exists()) await backup.rename(targetDir);
    } catch (_) {}
    try {
      await shelfIndex.replace(previous);
    } catch (_) {}
  }

  Future<void> _extract(Archive archive, String destination) async {
    await Directory(booksDir).create(recursive: true);
    await Directory(destination).create();
    for (final file in archive) {
      if (!file.isFile) continue;
      final outFile = File(
        p.join(destination, file.name.replaceAll('/', p.separator)),
      );
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    }
  }

  ShelfBook _entryFromManifest({
    required Map<String, dynamic> manifest,
    required Archive archive,
    required String libraryId,
    required String bookDir,
    required String packageSha256,
  }) {
    final pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
    final thumbnailPath = archive.any((file) => file.name == 'cover.jpg')
        ? 'cover.jpg'
        : pages.first['thumbnail'] as String;
    return ShelfBook(
      libraryId: libraryId,
      sourceBookId: manifest['book_id'] as String,
      title: manifest['title'] as String,
      pageCount: manifest['page_count'] as int,
      bookDir: bookDir,
      thumbnailPath: thumbnailPath,
      packageSha256: packageSha256,
      importedAt: DateTime.now().toUtc(),
    );
  }

  String _stagingPath(String libraryId) =>
      p.join(booksDir, '.import-$libraryId-${_nonce()}');

  String _backupPath(String libraryId) =>
      p.join(booksDir, '.backup-$libraryId-${_nonce()}');

  static Future<void> _deleteIfExists(String path) async {
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Map<String, dynamic> _readManifest(Archive archive) => jsonDecode(
        utf8.decode(
          archive.firstWhere((file) => file.name == 'manifest.json').content
              as List<int>,
        ),
      ) as Map<String, dynamic>;

  static ShelfBook? _overwriteTarget({
    required List<ShelfBook> entries,
    required String sourceBookId,
    required String? targetLibraryId,
  }) {
    if (targetLibraryId != null) {
      for (final entry in entries) {
        if (entry.libraryId == targetLibraryId) return entry;
      }
      return null;
    }
    if (entries.isEmpty) return null;
    return _preferredConflict(entries, sourceBookId);
  }

  static ShelfBook _preferredConflict(
    List<ShelfBook> entries,
    String sourceBookId,
  ) {
    for (final entry in entries) {
      if (entry.libraryId == sourceBookId) return entry;
    }
    return entries.reduce((best, candidate) {
      final byTime = candidate.importedAt.compareTo(best.importedAt);
      if (byTime != 0) return byTime < 0 ? candidate : best;
      return candidate.libraryId.compareTo(best.libraryId) < 0
          ? candidate
          : best;
    });
  }
}

String _nonce() => DateTime.now().microsecondsSinceEpoch.toString();

final _importDirectoryPattern = RegExp(
  r'^\.import-[a-z0-9][a-z0-9-]{2,63}-\d+$',
);
final _backupDirectoryPattern = RegExp(
  r'^\.backup-([a-z0-9][a-z0-9-]{2,63})-\d+$',
);
