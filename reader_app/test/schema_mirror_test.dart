import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/data/bookpack/schema_constants.dart';

/// 防漂移测试：Dart 镜像常量必须与 shared/schema/ 单一事实来源一致。
/// 改了 shared/schema 而没同步 schema_constants.dart 时此测试失败。
void main() {
  final repoRoot = Directory.current.path.endsWith('reader_app')
      ? '${Directory.current.path}/..'
      : Directory.current.path;

  test('manifest required keys 与 manifest.schema.json 一致', () {
    final schema = jsonDecode(
        File('$repoRoot/shared/schema/manifest.schema.json').readAsStringSync())
        as Map<String, dynamic>;
    final required = (schema['required'] as List).cast<String>().toSet();
    expect(BookPackSchema.manifestRequiredKeys, equals(required));
  });

  test('schema_version 与 manifest.schema.json const 一致', () {
    final schema = jsonDecode(
        File('$repoRoot/shared/schema/manifest.schema.json').readAsStringSync())
        as Map<String, dynamic>;
    final version =
        (schema['properties']['schema_version'] as Map)['const'] as int;
    expect(BookPackSchema.supportedSchemaVersions.contains(version), isTrue);
  });

  test('alignment 表集合与 alignment.sql 一致', () {
    final sql = File('$repoRoot/shared/schema/alignment.sql').readAsStringSync();
    final tables = RegExp(r'CREATE TABLE (\w+)')
        .allMatches(sql)
        .map((m) => m.group(1)!)
        .toSet();
    expect(BookPackSchema.alignmentTables, equals(tables));
  });
}
