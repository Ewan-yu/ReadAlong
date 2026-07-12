import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../appdb/shelf_index.dart';
import 'archive_entries.dart';
import 'book_pack_validator.dart';

enum ImportConflictResolution { reject, overwrite, saveCopy }

enum ImportFailureCategory { validation, operation }

class ImportResult {
  final bool ok;
  final bool isConflict;
  final bool isAlreadyImported;
  final ShelfBook? entry;
  final ShelfBook? conflictEntry;
  final ImportFailureCategory? failureCategory;
  final List<String> errors;

  const ImportResult._({
    required this.ok,
    required this.isConflict,
    required this.isAlreadyImported,
    this.entry,
    this.conflictEntry,
    this.failureCategory,
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

  factory ImportResult.validationFailure(List<String> errors) => ImportResult._(
        ok: false,
        isConflict: false,
        isAlreadyImported: false,
        failureCategory: ImportFailureCategory.validation,
        errors: List.unmodifiable(errors),
      );

  factory ImportResult.operationFailure(List<String> errors) => ImportResult._(
        ok: false,
        isConflict: false,
        isAlreadyImported: false,
        failureCategory: ImportFailureCategory.operation,
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
    ValidationResult validation;
    try {
      validation = await BookPackValidator.validateBytes(
        zipBytes,
        databaseFactory: validationDatabaseFactory,
      );
    } catch (error) {
      return ImportResult.operationFailure(['校验资源包时发生本地错误: $error']);
    }
    if (!validation.ok) {
      return ImportResult.validationFailure(validation.errors);
    }

    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBytes(zipBytes);
      final canonical = CanonicalArchiveEntries.fromArchive(
        archive,
        archivePaths:
            decoder.directory.fileHeaders.map((header) => header.filename),
      );
      if (canonical.errors.isNotEmpty) {
        return ImportResult.validationFailure(canonical.errors);
      }
      final entries = canonical.entries;
      final manifest = _readManifest(entries);
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
            return ImportResult.operationFailure(
              ['书籍目录已存在但未被书架索引管理: $bookDir'],
            );
          }
          return _installNew(
            entries: entries,
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
            return ImportResult.operationFailure(['未找到可覆盖的本地书籍']);
          }
          return _overwrite(
            entries: entries,
            manifest: manifest,
            existing: target,
            packageSha256: packageSha256,
          );
        case ImportConflictResolution.saveCopy:
          return _saveCopy(
            entries: entries,
            manifest: manifest,
            sourceBookId: sourceBookId,
            packageSha256: packageSha256,
          );
      }
    } catch (error) {
      return ImportResult.operationFailure(['导入资源包失败: $error']);
    }
  }

  Future<void> recoverInterruptedImports() async {
    final root = Directory(booksDir);
    if (!await root.exists()) return;
    final unresolved = <String>[];

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (_importDirectoryPattern.hasMatch(name)) {
        await entity.delete(recursive: true);
        continue;
      }

      final deleteMatch = _deleteDirectoryPattern.firstMatch(name);
      if (deleteMatch != null) {
        final libraryId = deleteMatch.group(2)!;
        final targetPath = p.join(booksDir, libraryId);
        final indexed = await shelfIndex.findByLibraryId(libraryId);
        if (indexed == null) {
          await entity.delete(recursive: true);
        } else if (!p.equals(
          p.normalize(indexed.bookDir),
          p.normalize(targetPath),
        )) {
          unresolved.add('索引目录 ${indexed.bookDir} 不属于删除暂存目录 ${entity.path}');
        } else if (await FileSystemEntity.type(
              targetPath,
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound) {
          await entity.rename(targetPath);
        } else {
          unresolved.add('目标 $targetPath 与删除暂存目录 ${entity.path} 同时存在');
        }
        continue;
      }

      final backupMatch = _backupDirectoryPattern.firstMatch(name);
      if (backupMatch == null) continue;
      final targetPath = p.join(booksDir, backupMatch.group(1)!);
      if (await FileSystemEntity.type(targetPath, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await entity.rename(targetPath);
      } else {
        unresolved.add('目标 $targetPath 与备份 ${entity.path} 同时存在');
      }
    }

    if (unresolved.isNotEmpty) {
      throw StateError('发现未完成的覆盖恢复；已保留备份：${unresolved.join('；')}');
    }
  }

  Future<ImportResult> _installNew({
    required Map<String, ArchiveFile> entries,
    required Map<String, dynamic> manifest,
    required String libraryId,
    required String packageSha256,
  }) async {
    final bookDir = p.join(booksDir, libraryId);
    final stagingDir = _stagingPath(libraryId);
    var movedToBookDir = false;
    try {
      await _extract(entries, stagingDir);
      await Directory(stagingDir).rename(bookDir);
      movedToBookDir = true;
      final entry = _entryFromManifest(
        manifest: manifest,
        entries: entries,
        libraryId: libraryId,
        bookDir: bookDir,
        packageSha256: packageSha256,
      );
      await shelfIndex.add(entry);
      return ImportResult.success(entry: entry);
    } catch (error) {
      await _deleteIfExists(movedToBookDir ? bookDir : stagingDir);
      return ImportResult.operationFailure(['导入资源包失败: $error']);
    }
  }

  Future<ImportResult> _saveCopy({
    required Map<String, ArchiveFile> entries,
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
      entries: entries,
      manifest: manifest,
      libraryId: libraryId,
      packageSha256: packageSha256,
    );
  }

  Future<ImportResult> _overwrite({
    required Map<String, ArchiveFile> entries,
    required Map<String, dynamic> manifest,
    required ShelfBook existing,
    required String packageSha256,
  }) async {
    final targetDir = existing.bookDir;
    final stagingDir = _stagingPath(existing.libraryId);
    final backupDir = _backupPath(existing.libraryId);
    var backupCreated = false;
    try {
      await _extract(entries, stagingDir);
      await Directory(targetDir).rename(backupDir);
      backupCreated = true;
      await Directory(stagingDir).rename(targetDir);
      final updated = _entryFromManifest(
        manifest: manifest,
        entries: entries,
        libraryId: existing.libraryId,
        bookDir: targetDir,
        packageSha256: packageSha256,
      );
      await shelfIndex.replace(updated);
      await Directory(backupDir).delete(recursive: true);
      return ImportResult.success(entry: updated);
    } catch (error) {
      final errors = <String>['覆盖资源包失败: $error'];
      if (backupCreated) {
        errors.addAll(
          await _restoreOverwrite(existing, targetDir, backupDir),
        );
      } else {
        await _deleteIfExists(stagingDir);
      }
      return ImportResult.operationFailure(errors);
    }
  }

  Future<List<String>> _restoreOverwrite(
    ShelfBook previous,
    String targetDir,
    String backupDir,
  ) async {
    final errors = <String>[];
    final backup = Directory(backupDir);
    if (!await backup.exists()) {
      errors.add('回滚备份不存在，已保留新目标: $backupDir');
      return errors;
    }

    try {
      await shelfIndex.replace(previous);
    } catch (error) {
      errors.add('回滚书架索引失败，已保留目标和备份: $error');
      return errors;
    }

    try {
      await _deleteIfExists(targetDir);
    } catch (error) {
      errors.add('删除新目标失败，已保留备份 $backupDir: $error');
      return errors;
    }

    try {
      await backup.rename(targetDir);
    } catch (error) {
      errors.add('恢复旧资源失败，已保留备份 $backupDir: $error');
    }
    return errors;
  }

  Future<void> _extract(
    Map<String, ArchiveFile> entries,
    String destination,
  ) async {
    await Directory(booksDir).create(recursive: true);
    await Directory(destination).create();
    for (final entry in entries.entries) {
      final file = entry.value;
      if (!file.isFile) continue;
      final outFile = File(
        p.join(destination, entry.key.replaceAll('/', p.separator)),
      );
      await outFile.parent.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    }
  }

  ShelfBook _entryFromManifest({
    required Map<String, dynamic> manifest,
    required Map<String, ArchiveFile> entries,
    required String libraryId,
    required String bookDir,
    required String packageSha256,
  }) {
    final pages = (manifest['pages'] as List).cast<Map<String, dynamic>>();
    final thumbnailPath = entries.containsKey('cover.jpg')
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

  String deleteStagingPath(String libraryId) =>
      p.join(booksDir, '.delete-${_nonce()}-$libraryId');

  static Future<void> _deleteIfExists(String path) async {
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Map<String, dynamic> _readManifest(
    Map<String, ArchiveFile> entries,
  ) =>
      jsonDecode(
        utf8.decode(
          entries['manifest.json']!.content as List<int>,
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
final _deleteDirectoryPattern = RegExp(
  r'^\.delete-(\d+)-([a-z0-9][a-z0-9-]{2,126})$',
);
