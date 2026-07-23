import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'archive_entries.dart';
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
    final decoder = ZipDecoder();
    try {
      archive = decoder.decodeBytes(zipBytes);
    } catch (e) {
      return ValidationResult.fail(['无法解析 zip 格式: $e']);
    }

    // 2. 路径逃逸和重复路径必须先于清单、必需文件校验。
    final canonical = CanonicalArchiveEntries.fromArchive(
      archive,
      archivePaths:
          decoder.directory.fileHeaders.map((header) => header.filename),
    );
    if (canonical.errors.isNotEmpty) {
      return ValidationResult.fail(canonical.errors);
    }
    final byName = canonical.entries;

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

    _validateOriginalAudio(manifest, byName, errors);

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
    await _validateOriginalTimelineAlignment(
      manifest,
      byName,
      dbBytes,
      databaseFactory ?? sqflite.databaseFactory,
      errors,
    );

    return errors.isEmpty
        ? ValidationResult.pass()
        : ValidationResult.fail(errors);
  }

  static Future<void> _validateOriginalTimelineAlignment(
    Map<String, dynamic> manifest,
    Map<String, ArchiveFile> byName,
    Uint8List dbBytes,
    sqflite.DatabaseFactory databaseFactory,
    List<String> errors,
  ) async {
    final original = manifest['original_audio'];
    if (original is! Map<String, dynamic> ||
        original['alignment_status'] !=
            BookPackSchema.originalAudioReadyStatus) {
      return;
    }
    final timelinePath = original['timeline_path'];
    final timelineFile = timelinePath is String ? byName[timelinePath] : null;
    if (timelineFile == null || !timelineFile.isFile) return;
    try {
      final timeline = jsonDecode(
        utf8.decode(timelineFile.content as List<int>),
      );
      if (timeline is! Map<String, dynamic> || timeline['sentences'] is! List) {
        throw const FormatException();
      }
      final temp = File(
        '${Directory.systemTemp.path}/ra_timeline_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      try {
        await temp.writeAsBytes(dbBytes);
        final database = await databaseFactory.openDatabase(
          temp.path,
          options: sqflite.OpenDatabaseOptions(readOnly: true),
        );
        try {
          final rows = await database.query(
            'sentence',
            columns: const ['id', 'page_no', 'seq', 'text'],
            orderBy: 'seq ASC',
          );
          final sentences = timeline['sentences'] as List;
          if (rows.length != sentences.length) throw const FormatException();
          for (var index = 0; index < rows.length; index++) {
            final row = rows[index];
            final sentence = sentences[index];
            if (sentence is! Map<String, dynamic> ||
                sentence['sentence_id'] != row['id'] ||
                sentence['page_no'] != row['page_no'] ||
                sentence['seq'] != row['seq'] ||
                sentence['text'] != row['text'] ||
                !_hasMatchingWords(sentence['text'] as String, sentence['words'])) {
              throw const FormatException();
            }
          }
        } finally {
          await database.close();
        }
      } finally {
        try {
          await temp.delete();
        } on Object {
          // Temp cleanup does not alter the integrity decision.
        }
      }
    } on Object {
      errors.add('原音逐词时间线与 alignment.db 句子索引不一致');
    }
  }

  static bool _hasMatchingWords(String sentenceText, Object? rawWords) {
    if (rawWords is! List) return false;
    final expected = _timelineWordPattern
        .allMatches(sentenceText)
        .map((match) => match.group(0)!.toLowerCase())
        .toList(growable: false);
    final actual = <String>[];
    for (final raw in rawWords) {
      if (raw is! Map<String, dynamic> || raw['text'] is! String) return false;
      actual.addAll(
        _timelineWordPattern
            .allMatches(raw['text'] as String)
            .map((match) => match.group(0)!.toLowerCase()),
      );
    }
    if (expected.length != actual.length || expected.isEmpty) return false;
    for (var index = 0; index < expected.length; index++) {
      if (expected[index] != actual[index]) return false;
    }
    return true;
  }

  static final _timelineWordPattern = RegExp(
    r"[A-Za-z0-9]+(?:['\u2019-][A-Za-z0-9]+)*|[\u3400-\u4DBF\u4E00-\u9FFF]",
  );

  static void _validateOriginalAudio(
    Map<String, dynamic> manifest,
    Map<String, ArchiveFile> byName,
    List<String> errors,
  ) {
    final originalFiles = byName.entries
        .where(
            (entry) => entry.value.isFile && entry.key.startsWith('original/'))
        .map((entry) => entry.key)
        .toSet();
    final raw = manifest['original_audio'];
    if (raw == null) {
      for (final path in originalFiles) {
        errors.add('原音资源未在 manifest.json 声明: $path');
      }
      return;
    }
    if (raw is! Map<String, dynamic>) {
      errors.add('manifest.json original_audio 必须是对象');
      return;
    }
    for (final key in BookPackSchema.originalAudioRequiredKeys) {
      if (!raw.containsKey(key)) {
        errors.add('manifest.json original_audio 缺字段: $key');
      }
    }
    if (!BookPackSchema.originalAudioRequiredKeys.every(raw.containsKey)) {
      return;
    }

    final path = raw['path'];
    if (path != BookPackSchema.originalAudioPath) {
      errors.add('原音路径非法: $path');
    }
    if (raw['mime_type'] != BookPackSchema.originalAudioMimeType) {
      errors.add('原音 MIME 类型非法: ${raw['mime_type']}');
    }
    final declaredSize = raw['size_bytes'];
    if (declaredSize is! int || declaredSize <= 0) {
      errors.add('原音 size_bytes 非法: $declaredSize');
    }
    final declaredHash = raw['sha256'];
    if (declaredHash is! String ||
        !BookPackSchema.sha256Pattern.hasMatch(declaredHash)) {
      errors.add('原音 sha256 非法: $declaredHash');
    }
    final duration = raw['duration_ms'];
    if (duration is! int || duration <= 0) {
      errors.add('原音 duration_ms 非法: $duration');
    }
    final alignmentStatus = raw['alignment_status'];
    if (!BookPackSchema.originalAudioAlignmentStatuses
        .contains(alignmentStatus)) {
      errors.add('原音 alignment_status 非法: ${raw['alignment_status']}');
    }

    final declaredPath = path is String ? path : null;
    final file = declaredPath == null ? null : byName[declaredPath];
    if (file == null || !file.isFile) {
      errors.add('缺少原音文件: $declaredPath');
    } else {
      final content = List<int>.from(file.content as List<int>);
      if (declaredSize is int && content.length != declaredSize) {
        errors.add('原音文件大小不一致: 声明 $declaredSize，实际 ${content.length}');
      }
      final actualHash = sha256.convert(content).toString();
      if (declaredHash is String && actualHash != declaredHash) {
        errors.add('原音文件 sha256 不一致');
      }
    }

    final background = raw['background'];
    String? backgroundPath;
    if (background != null) {
      if (background is! Map<String, dynamic>) {
        errors.add('原音背景轨必须是对象');
      } else {
        const required = {
          'path',
          'mime_type',
          'size_bytes',
          'sha256',
          'duration_ms',
          'method'
        };
        if (!required.every(background.containsKey)) {
          errors.add('原音背景轨缺少必填字段');
        } else {
          backgroundPath = background['path'] as String?;
          if (backgroundPath != BookPackSchema.originalAudioBackgroundPath ||
              background['mime_type'] !=
                  BookPackSchema.originalAudioBackgroundMimeType ||
              background['method'] !=
                  BookPackSchema.originalAudioBackgroundMethod) {
            errors.add('原音背景轨声明非法');
          }
          final backgroundFile =
              backgroundPath == null ? null : byName[backgroundPath];
          final size = background['size_bytes'];
          final hash = background['sha256'];
          if (backgroundFile == null || !backgroundFile.isFile) {
            errors.add('缺少原音背景轨: $backgroundPath');
          } else {
            final content = List<int>.from(backgroundFile.content as List<int>);
            if (size is! int || size <= 0 || content.length != size) {
              errors.add('原音背景轨大小不一致');
            }
            if (hash is! String ||
                !BookPackSchema.sha256Pattern.hasMatch(hash) ||
                sha256.convert(content).toString() != hash) {
              errors.add('原音背景轨 sha256 不一致');
            }
          }
          if (background['duration_ms'] is! int ||
              (background['duration_ms'] as int) <= 0) {
            errors.add('原音背景轨 duration_ms 非法');
          }
        }
      }
    }
    if (alignmentStatus == BookPackSchema.originalAudioReadyStatus) {
      _validateOriginalTimeline(raw, byName, errors);
    } else if (raw.containsKey('timeline_path') ||
        raw.containsKey('timeline_sha256') ||
        raw.containsKey('timeline_sentence_count') ||
        raw.containsKey('vocal_sha256')) {
      errors.add('raw 原音不应声明逐词时间线');
    }
    for (final extraPath in originalFiles
        .where((entry) => entry != declaredPath && entry != backgroundPath)) {
      errors.add('存在未声明的原音资源: $extraPath');
    }
  }

  static void _validateOriginalTimeline(
    Map<String, dynamic> original,
    Map<String, ArchiveFile> byName,
    List<String> errors,
  ) {
    const required = {
      'timeline_path',
      'timeline_sha256',
      'timeline_sentence_count',
      'vocal_sha256',
    };
    if (!required.every(original.containsKey)) {
      errors.add('原音 ready 状态缺少逐词时间线声明');
      return;
    }
    final path = original['timeline_path'];
    final expectedHash = original['timeline_sha256'];
    final sentenceCount = original['timeline_sentence_count'];
    final vocalHash = original['vocal_sha256'];
    if (path != BookPackSchema.originalAudioTimelinePath ||
        expectedHash is! String ||
        !BookPackSchema.sha256Pattern.hasMatch(expectedHash) ||
        sentenceCount is! int ||
        sentenceCount <= 0 ||
        vocalHash is! String ||
        !BookPackSchema.sha256Pattern.hasMatch(vocalHash)) {
      errors.add('原音逐词时间线声明非法');
      return;
    }
    final file = byName[path];
    if (file == null || !file.isFile) {
      errors.add('缺少原音逐词时间线: $path');
      return;
    }
    final bytes = List<int>.from(file.content as List<int>);
    if (sha256.convert(bytes).toString() != expectedHash) {
      errors.add('原音逐词时间线 sha256 不一致');
      return;
    }
    try {
      final timeline = jsonDecode(utf8.decode(bytes));
      if (timeline is! Map<String, dynamic> ||
          timeline['schema_version'] != 1 ||
          timeline['audio_sha256'] != original['sha256'] ||
          timeline['duration_ms'] != original['duration_ms']) {
        throw const FormatException();
      }
      final source = timeline['source'];
      final sentences = timeline['sentences'];
      if (source is! Map<String, dynamic> ||
          source['original_audio_sha256'] != original['sha256'] ||
          source['vocal_sha256'] != vocalHash ||
          sentences is! List ||
          sentences.length != sentenceCount) {
        throw const FormatException();
      }
      var previousEnd = 0;
      for (var index = 0; index < sentences.length; index++) {
        final sentence = sentences[index];
        if (sentence is! Map<String, dynamic> ||
            sentence['seq'] != index + 1 ||
            sentence['start_ms'] is! int ||
            sentence['end_ms'] is! int ||
            (sentence['start_ms'] as int) < previousEnd ||
            (sentence['end_ms'] as int) <= (sentence['start_ms'] as int) ||
            (sentence['end_ms'] as int) > (original['duration_ms'] as int) ||
            sentence['words'] is! List ||
            (sentence['words'] as List).isEmpty) {
          throw const FormatException();
        }
        final words = sentence['words'] as List;
        var wordEnd = sentence['start_ms'] as int;
        for (var wordIndex = 0; wordIndex < words.length; wordIndex++) {
          final word = words[wordIndex];
          if (word is! Map<String, dynamic> ||
              word['seq'] != wordIndex + 1 ||
              word['text'] is! String ||
              (word['text'] as String).trim().isEmpty ||
              word['start_ms'] is! int ||
              word['end_ms'] is! int ||
              (word['start_ms'] as int) < wordEnd ||
              (word['end_ms'] as int) <= (word['start_ms'] as int) ||
              (word['end_ms'] as int) > (sentence['end_ms'] as int)) {
            throw const FormatException();
          }
          wordEnd = word['end_ms'] as int;
        }
        if ((words.first as Map<String, dynamic>)['start_ms'] !=
                sentence['start_ms'] ||
            (words.last as Map<String, dynamic>)['end_ms'] !=
                sentence['end_ms']) {
          throw const FormatException();
        }
        previousEnd = sentence['end_ms'] as int;
      }
    } on Object {
      errors.add('原音逐词时间线内容非法');
    }
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
