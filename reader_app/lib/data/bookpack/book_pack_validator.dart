import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'schema_constants.dart';

class ValidationResult {
  final bool ok;
  final List<String> errors;
  const ValidationResult._(this.ok, this.errors);
  factory ValidationResult.pass() => const ValidationResult._(true, []);
  factory ValidationResult.fail(List<String> errors) =>
      ValidationResult._(false, List.unmodifiable(errors));
}

/// 资源包校验器。validateBytes 是异步的（含 sqlite 全量校验）。
class BookPackValidator {
  static Future<ValidationResult> validateBytes(
    Uint8List zipBytes, {
    sqflite.DatabaseFactory? databaseFactory,
  }) async {
    final errors = <String>[];

    // 1. zip 解析
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      return ValidationResult.fail(['无法解析 zip 格式: $e']);
    }

    // 2. 路径逃逸（优先拦截，防恶意包）
    for (final f in archive) {
      final name = f.name;
      if (name.contains('..') || p.isAbsolute(name) || name.startsWith('/')) {
        errors.add('路径逃逸: $name');
      }
    }
    if (errors.isNotEmpty) return ValidationResult.fail(errors);

    final byName = {for (final f in archive) f.name: f};

    // 3. 必需条目
    for (final entry in BookPackSchema.requiredEntries) {
      if (!byName.containsKey(entry)) errors.add('缺少必需文件: $entry');
    }
    if (errors.isNotEmpty) return ValidationResult.fail(errors);

    // 4. manifest.json
    Map<String, dynamic> manifest;
    try {
      manifest =
          jsonDecode(utf8.decode(byName['manifest.json']!.content as List<int>))
              as Map<String, dynamic>;
    } catch (e) {
      return ValidationResult.fail(['manifest.json 解析失败: $e']);
    }

    for (final key in BookPackSchema.manifestRequiredKeys) {
      if (!manifest.containsKey(key)) errors.add('manifest.json 缺字段: $key');
    }
    if (errors.isNotEmpty) return ValidationResult.fail(errors);

    final version = manifest['schema_version'] as int?;
    if (version == null ||
        !BookPackSchema.supportedSchemaVersions.contains(version)) {
      errors.add(
          '不支持的 schema_version: $version（支持: ${BookPackSchema.supportedSchemaVersions}），请升级 App');
    }

    final bookId = manifest['book_id'] as String? ?? '';
    if (!BookPackSchema.bookIdPattern.hasMatch(bookId)) {
      errors.add('book_id 格式非法: $bookId');
    }

    // 5. 页面图片存在
    for (final page
        in ((manifest['pages'] as List?) ?? []).cast<Map<String, dynamic>>()) {
      for (final key in ['image', 'thumbnail']) {
        final path = page[key] as String?;
        if (path != null && !byName.containsKey(path)) {
          errors.add('缺少文件: $path');
        }
      }
    }

    // 6. alignment.db 全量校验
    final dbBytes =
        Uint8List.fromList(byName['align/alignment.db']!.content as List<int>);
    final dbErrors = await _validateDb(
      dbBytes,
      databaseFactory ?? sqflite.databaseFactory,
    );
    errors.addAll(dbErrors);

    return errors.isEmpty
        ? ValidationResult.pass()
        : ValidationResult.fail(errors);
  }

  static Future<List<String>> _validateDb(
    Uint8List dbBytes,
    sqflite.DatabaseFactory databaseFactory,
  ) async {
    final errors = <String>[];
    // 写临时文件，用当前平台的数据库工厂做 SQL 级校验。
    final tmp = File(
        '${Directory.systemTemp.path}/ra_validate_${DateTime.now().millisecondsSinceEpoch}.db');
    try {
      await tmp.writeAsBytes(dbBytes);
      final db = await databaseFactory.openDatabase(
        tmp.path,
        options: sqflite.OpenDatabaseOptions(readOnly: true),
      );

      // 6a. 必需表存在
      final tables = (await db
              .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name'] as String)
          .toSet();
      for (final t in BookPackSchema.alignmentTables) {
        if (!tables.contains(t)) errors.add('alignment.db 缺少表: $t');
      }

      if (errors.isEmpty) {
        // 6b. bbox 归一化
        final rows = await db.rawQuery('SELECT id, bbox_json FROM sentence');
        for (final row in rows) {
          final id = row['id'];
          try {
            final bbox =
                jsonDecode(row['bbox_json'] as String) as Map<String, dynamic>;
            final x = (bbox['x'] as num).toDouble();
            final y = (bbox['y'] as num).toDouble();
            final w = (bbox['w'] as num).toDouble();
            final h = (bbox['h'] as num).toDouble();
            if (x < 0 ||
                y < 0 ||
                w <= 0 ||
                h <= 0 ||
                x + w > 1.001 ||
                y + h > 1.001) {
              errors.add('句子 $id bbox 越界: x=$x y=$y w=$w h=$h');
            }
          } catch (e) {
            errors.add('句子 $id bbox_json 解析失败: $e');
          }
        }

        // 6c. 句子文本非空
        final empty = await db.rawQuery(
            "SELECT id FROM sentence WHERE text IS NULL OR trim(text) = ''");
        for (final row in empty) {
          errors.add('句子 ${row['id']} text 为空');
        }
      }

      await db.close();
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    return errors;
  }
}
