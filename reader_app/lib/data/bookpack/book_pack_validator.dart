import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'archive_entries.dart';
import 'book_pack_limits.dart';
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

    // 1. ZIP 中央目录预检必须发生在解压之前，避免 ZIP bomb 触发无界分配。
    final zipLimitErrors = BookPackLimits.validateZipBytes(zipBytes);
    if (zipLimitErrors.isNotEmpty) return ValidationResult.fail(zipLimitErrors);

    // 2. zip 解析
    Archive archive;
    final decoder = ZipDecoder();
    try {
      archive = decoder.decodeBytes(zipBytes);
    } catch (e) {
      return ValidationResult.fail(['无法解析 zip 格式: $e']);
    }

    // 3. 路径逃逸和重复路径必须先于清单、必需文件校验。
    final canonical = CanonicalArchiveEntries.fromArchive(
      archive,
      archivePaths:
          decoder.directory.fileHeaders.map((header) => header.filename),
    );
    if (canonical.errors.isNotEmpty) {
      return ValidationResult.fail(canonical.errors);
    }
    final byName = canonical.entries;

    // 4. 必需条目
    for (final entry in BookPackSchema.requiredEntries) {
      if (!byName.containsKey(entry)) errors.add('缺少必需文件: $entry');
    }
    if (errors.isNotEmpty) return ValidationResult.fail(errors);

    // 5. manifest.json
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

    final version = manifest['schema_version'];
    if (version is! int ||
        !BookPackSchema.supportedSchemaVersions.contains(version)) {
      errors.add(
          '不支持的 schema_version: $version（支持: ${BookPackSchema.supportedSchemaVersions}），请升级 App');
    }

    final bookId = manifest['book_id'];
    if (bookId is! String) {
      errors.add('book_id 必须是字符串');
    }
    final normalizedBookId = bookId is String ? bookId : '';
    if (!BookPackSchema.bookIdPattern.hasMatch(normalizedBookId)) {
      errors.add('book_id 格式非法: $bookId');
    }

    _validateManifestShape(manifest, byName, errors);

    _validateOriginalAudio(manifest, byName, errors);

    // 6. alignment.db 全量校验
    final dbBytes =
        Uint8List.fromList(byName['align/alignment.db']!.content as List<int>);
    final dbErrors = await _validateDb(
      dbBytes,
      databaseFactory ?? sqflite.databaseFactory,
      manifest: manifest,
      entries: byName,
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

  static void _validateManifestShape(
    Map<String, dynamic> manifest,
    Map<String, ArchiveFile> byName,
    List<String> errors,
  ) {
    final title = manifest['title'];
    if (title is! String || title.trim().isEmpty) {
      errors.add('title 必须是非空字符串');
    }
    final language = manifest['language'];
    if (language != 'en') errors.add('language 只支持 en: $language');
    final createdAt = manifest['created_at'];
    if (createdAt is! String || DateTime.tryParse(createdAt) == null) {
      errors.add('created_at 必须是有效时间字符串');
    }

    final generator = manifest['generator'];
    if (generator is! Map<String, dynamic> ||
        generator['name'] is! String ||
        (generator['name'] as String).trim().isEmpty ||
        generator['version'] is! String ||
        (generator['version'] as String).trim().isEmpty) {
      errors.add('generator 必须包含非空 name 和 version');
    }
    _validateImageDeclaration(manifest['page_image'], 'page_image', errors);
    _validateImageDeclaration(manifest['thumbnail'], 'thumbnail', errors);

    final pageCount = manifest['page_count'];
    final pages = manifest['pages'];
    if (pageCount is! int || pageCount < 1) {
      errors.add('page_count 必须是正整数');
    }
    if (pages is! List) {
      errors.add('pages 必须是数组');
      return;
    }
    if (pageCount is int && pages.length != pageCount) {
      errors.add('page_count 与 pages.length 不一致: $pageCount/${pages.length}');
    }

    final pageNumbers = <int>{};
    for (final raw in pages) {
      if (raw is! Map<String, dynamic>) {
        errors.add('pages 条目必须是对象');
        continue;
      }
      final pageNo = raw['page_no'];
      if (pageNo is! int || pageNo < 1 || !pageNumbers.add(pageNo)) {
        errors.add('页面页码非法或重复: $pageNo');
      }
      final width = raw['width_px'];
      final height = raw['height_px'];
      if (width is! int || width < 1 || height is! int || height < 1) {
        errors.add('页面尺寸必须是正整数: page=$pageNo');
      }
      final image = raw['image'];
      final thumbnail = raw['thumbnail'];
      if (image is! String ||
          !RegExp(r'^pages/p[0-9]{4}\.webp$').hasMatch(image)) {
        errors.add('页面图片路径非法: $image');
      } else if (!byName.containsKey(image)) {
        errors.add('缺少文件: $image');
      }
      if (thumbnail is! String ||
          !RegExp(r'^thumbnails/p[0-9]{4}\.jpg$').hasMatch(thumbnail)) {
        errors.add('页面缩略图路径非法: $thumbnail');
      } else if (!byName.containsKey(thumbnail)) {
        errors.add('缺少文件: $thumbnail');
      }
      final sourceRegion = raw['source_region'];
      if (!const {'full', 'left', 'right', 'custom'}.contains(sourceRegion)) {
        errors.add('页面 source_region 非法: $sourceRegion');
      }
      _validateSourceCrop(raw['source_crop'], pageNo, errors);
    }
    if (pageCount is int && pageNumbers.length == pageCount) {
      for (var pageNo = 1; pageNo <= pageCount; pageNo++) {
        if (!pageNumbers.contains(pageNo)) {
          errors.add('页面页码不连续，缺少: $pageNo');
        }
      }
    }
  }

  static void _validateImageDeclaration(
    Object? raw,
    String name,
    List<String> errors,
  ) {
    if (raw is! Map<String, dynamic>) {
      errors.add('$name 必须是对象');
      return;
    }
    if (raw['format'] is! String ||
        raw['max_long_edge_px'] is! int ||
        (raw['max_long_edge_px'] as int) < 1 ||
        raw['quality'] is! int ||
        (raw['quality'] as int) < 1 ||
        (raw['quality'] as int) > 100) {
      errors.add('$name 声明非法');
    }
  }

  static void _validateSourceCrop(
    Object? raw,
    Object? pageNo,
    List<String> errors,
  ) {
    if (raw == null) return;
    if (raw is! Map<String, dynamic>) {
      errors.add('页面 source_crop 必须是对象: page=$pageNo');
      return;
    }
    final values = [raw['x'], raw['y'], raw['w'], raw['h']];
    if (values.any((value) => value is! num) ||
        (raw['x'] as num) < 0 ||
        (raw['y'] as num) < 0 ||
        (raw['w'] as num) <= 0 ||
        (raw['h'] as num) <= 0 ||
        (raw['x'] as num) + (raw['w'] as num) > 1 ||
        (raw['y'] as num) + (raw['h'] as num) > 1) {
      errors.add('页面 source_crop 越界: page=$pageNo');
    }
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
          final rowsById = {
            for (final row in rows) row['id']: row,
          };
          final seenIds = <Object?>{};
          var previousSequence = 0;
          for (final sentence in sentences) {
            final sentenceId = sentence is Map<String, dynamic>
                ? sentence['sentence_id']
                : null;
            final row = rowsById[sentenceId];
            if (sentence is! Map<String, dynamic> ||
                row == null ||
                !seenIds.add(sentenceId) ||
                sentence['sentence_id'] != row['id'] ||
                sentence['page_no'] != row['page_no'] ||
                sentence['seq'] != row['seq'] ||
                sentence['text'] != row['text'] ||
                sentence['seq'] is! int ||
                (sentence['seq'] as int) <= previousSequence ||
                sentence['text'] is! String ||
                !_hasMatchingWords(
                    sentence['text'] as String, sentence['words'])) {
              throw const FormatException();
            }
            previousSequence = sentence['seq'] as int;
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
    final playback = raw['playback'];
    String? playbackPath;
    if (playback != null) {
      if (playback is! Map<String, dynamic>) {
        errors.add('原音兼容播放轨必须是对象');
      } else {
        playbackPath = playback['path'] as String?;
        final size = playback['size_bytes'];
        final hash = playback['sha256'];
        if (playbackPath != BookPackSchema.originalAudioPlaybackPath ||
            playback['mime_type'] !=
                BookPackSchema.originalAudioPlaybackMimeType) {
          errors.add('原音兼容播放轨声明非法');
        }
        final playbackFile = playbackPath == null ? null : byName[playbackPath];
        if (playbackFile == null || !playbackFile.isFile) {
          errors.add('缺少原音兼容播放轨: $playbackPath');
        } else {
          final content = List<int>.from(playbackFile.content as List<int>);
          if (size is! int || size <= 0 || content.length != size) {
            errors.add('原音兼容播放轨大小不一致');
          }
          if (hash is! String ||
              !BookPackSchema.sha256Pattern.hasMatch(hash) ||
              sha256.convert(content).toString() != hash) {
            errors.add('原音兼容播放轨 sha256 不一致');
          }
        }
      }
    }
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
    for (final extraPath in originalFiles.where((entry) =>
        entry != declaredPath &&
        entry != playbackPath &&
        entry != backgroundPath)) {
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
      var previousSourceSequence = 0;
      final sentenceIds = <String>{};
      for (final sentence in sentences) {
        if (sentence is! Map<String, dynamic> ||
            sentence['sentence_id'] is! String ||
            !sentenceIds.add(sentence['sentence_id'] as String) ||
            sentence['seq'] is! int ||
            (sentence['seq'] as int) <= previousSourceSequence ||
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
        previousSourceSequence = sentence['seq'] as int;
      }
    } on Object {
      errors.add('原音逐词时间线内容非法');
    }
  }

  static Future<List<String>> _validateDb(
    Uint8List dbBytes,
    sqflite.DatabaseFactory databaseFactory, {
    required Map<String, dynamic> manifest,
    required Map<String, ArchiveFile> entries,
  }) async {
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
        try {
          await _validateAlignmentIdentity(db, manifest, entries, errors);
        } catch (error) {
          errors.add('alignment.db schema 校验失败: $error');
        }
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

  static Future<void> _validateAlignmentIdentity(
    sqflite.Database db,
    Map<String, dynamic> manifest,
    Map<String, ArchiveFile> entries,
    List<String> errors,
  ) async {
    final bookId = manifest['book_id'];
    final language = manifest['language'];
    final version = manifest['schema_version'];
    final books = await db.query('book');
    if (books.length != 1) {
      errors.add('alignment.db 必须且只能包含一条 book 记录');
      return;
    }
    final book = books.single;
    if (book['id'] != bookId ||
        book['language'] != language ||
        book['schema_version'] != version) {
      errors.add('alignment.db book 身份与 manifest 不一致');
    }

    final pages = (manifest['pages'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .toList(growable: false) ??
        const <Map<String, dynamic>>[];
    final manifestPages = {
      for (final page in pages) page['page_no']: page,
    };
    final dbPages = await db.query(
      'page',
      columns: const [
        'book_id',
        'page_no',
        'image_path',
        'thumbnail_path',
        'width_px',
        'height_px',
      ],
      orderBy: 'page_no ASC',
    );
    if (dbPages.length != pages.length) {
      errors.add('alignment.db page 数量与 manifest 不一致');
    }
    final seenPages = <int>{};
    for (final row in dbPages) {
      final pageNo = row['page_no'];
      final expected = manifestPages[pageNo];
      if (row['book_id'] != bookId ||
          pageNo is! int ||
          !seenPages.add(pageNo) ||
          expected == null ||
          row['image_path'] != expected['image'] ||
          row['thumbnail_path'] != expected['thumbnail'] ||
          row['width_px'] != expected['width_px'] ||
          row['height_px'] != expected['height_px'] ||
          !entries.containsKey(row['image_path']) ||
          !entries.containsKey(row['thumbnail_path'])) {
        errors.add('alignment.db page 与 manifest 不一致: $pageNo');
      }
    }

    final sentences = await db.query(
      'sentence',
      columns: const [
        'id',
        'book_id',
        'page_no',
        'seq',
        'text',
        'audio_path',
        'audio_source',
        't_start',
        't_end',
      ],
      orderBy: 'seq ASC',
    );
    final sentenceIds = <String>{};
    final sequences = <int>{};
    for (final row in sentences) {
      final id = row['id'];
      final pageNo = row['page_no'];
      final seq = row['seq'];
      final audioPath = row['audio_path'];
      final start = (row['t_start'] as num?)?.toDouble();
      final end = (row['t_end'] as num?)?.toDouble();
      if (id is! String ||
          !sentenceIds.add(id) ||
          row['book_id'] != bookId ||
          pageNo is! int ||
          !manifestPages.containsKey(pageNo) ||
          seq is! int ||
          !sequences.add(seq) ||
          seq < 1 ||
          row['text'] is! String ||
          audioPath is! String ||
          !entries.containsKey(audioPath) ||
          start == null ||
          end == null ||
          start < 0 ||
          end <= start) {
        errors.add('alignment.db sentence 记录非法: $id');
      }
      if (row['text'] is! String || (row['text'] as String).trim().isEmpty) {
        errors.add('句子 $id text 为空');
      }
    }
    final orderedSequences = sequences.toList()..sort();
    for (var index = 0; index < orderedSequences.length; index++) {
      if (orderedSequences[index] != index + 1) {
        errors.add('alignment.db sentence.seq 不连续');
        break;
      }
    }

    final words = await db.query(
      'word_timing',
      columns: const ['id', 'sentence_id', 'seq', 'word', 't_start', 't_end'],
      orderBy: 'sentence_id ASC, seq ASC',
    );
    final wordIds = <String>{};
    final wordSequences = <String, List<int>>{};
    for (final row in words) {
      final id = row['id'];
      final sentenceId = row['sentence_id'];
      final seq = row['seq'];
      final start = (row['t_start'] as num?)?.toDouble();
      final end = (row['t_end'] as num?)?.toDouble();
      if (id is! String ||
          !wordIds.add(id) ||
          sentenceId is! String ||
          !sentenceIds.contains(sentenceId) ||
          seq is! int ||
          seq < 1 ||
          row['word'] is! String ||
          (row['word'] as String).trim().isEmpty ||
          start == null ||
          end == null ||
          start < 0 ||
          end <= start) {
        errors.add('alignment.db word_timing 记录非法: $id');
        continue;
      }
      wordSequences.putIfAbsent(sentenceId, () => []).add(seq);
    }
    for (final sequence in wordSequences.values) {
      sequence.sort();
      for (var index = 0; index < sequence.length; index++) {
        if (sequence[index] != index + 1) {
          errors.add('alignment.db word_timing.seq 不连续');
          break;
        }
      }
    }
  }
}
