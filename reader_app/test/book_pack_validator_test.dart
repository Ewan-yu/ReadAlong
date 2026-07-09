import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/data/bookpack/book_pack_validator.dart';

Uint8List _fixture(String name) {
  final repoRoot = Directory.current.path.endsWith('reader_app')
      ? '${Directory.current.path}/..'
      : Directory.current.path;
  final path = '$repoRoot/shared/fixtures/out/$name';
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
        '夹具文件不存在: $path\n'
        '请先运行: conda run -n readalong python shared/fixtures/make_fixture_book.py');
  }
  return file.readAsBytesSync();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('BookPackValidator', () {
    test('合法包通过全量校验', () async {
      final result = await BookPackValidator.validateBytes(
          _fixture('fixture_book.readalongbook'));
      expect(result.ok, isTrue, reason: '合法包应通过: ${result.errors}');
    });

    test('坏包：缺 alignment.db 被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
          _fixture('bad_missing_file.readalongbook'));
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('align/alignment.db')), isTrue,
          reason: '错误信息应提及缺失文件，实际: ${result.errors}');
    });

    test('坏包：bbox 越界被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
          _fixture('bad_bbox.readalongbook'));
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('bbox')), isTrue,
          reason: '错误信息应提及 bbox，实际: ${result.errors}');
    });

    test('坏包：句子文本为空被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
          _fixture('bad_empty_text.readalongbook'));
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('text') || e.contains('空')),
          isTrue,
          reason: '错误信息应提及空文本，实际: ${result.errors}');
    });

    test('坏包：路径逃逸被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
          _fixture('bad_path_escape.readalongbook'));
      expect(result.ok, isFalse);
      expect(result.errors.any((e) => e.contains('路径逃逸')), isTrue,
          reason: '错误信息应提及路径逃逸，实际: ${result.errors}');
    });

    test('非法 zip 字节被拒绝', () async {
      final result = await BookPackValidator.validateBytes(
          Uint8List.fromList([0, 1, 2, 3]));
      expect(result.ok, isFalse);
    });
  });
}
