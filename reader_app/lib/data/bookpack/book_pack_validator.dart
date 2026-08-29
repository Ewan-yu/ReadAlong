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
    BookPackLimits limits = const BookPackLimits(),
  }) async {
    final errors = <String>[];

    if (zipBytes.length > limits.maxPackageBytes) {
      return ValidationResult.fail([
        '资源包过大: ${zipBytes.length} 字节（上限 ${limits.maxPackageBytes}）',
      ]);
    }

    // ZIP 中央目录预检必须发生在解压之前，避免 ZIP bomb 触发无界分配。
    final zipLimitErrors =
        BookPackLimits.validateZipBytes(zipBytes, limits: limits);
    if (zipLimitErrors.isNotEmpty) {
      return ValidationResult.fail(zipLimitErrors);
    }

    // 1. zip 解析
    Archive archive;
    final decoder = ZipDecoder();
    try {
      archive = decoder.decodeBytes(zipBytes);
    } catch (e) {
      return ValidationResult.fail(['无法解析 zip 格式: $e']);
    }

    final archiveLimitErrors = _validateArchiveLimits(archive, limits);
    if (archiveLimitErrors.isNotEmpty) {
      return ValidationResult.fail(archiveLimitErrors);
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

    errors.addAll(_validateManifest(manifest, byName));
    if (errors.isNotEmpty) return ValidationResult.fail(errors);

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

  static List<String> _validateArchiveLimits(
    Archive archive,
    BookPackLimits limits,
  ) {
    final errors = <String>[];
    if (archive.length > limits.maxArchiveEntries) {
      errors.add(
        '资源包条目过多: ${archive.length}（上限 ${limits.maxArchiveEntries}）',
      );
    }
    var totalBytes = 0;
    for (final file in archive) {
      if (file.size < 0 || file.size > limits.maxSingleEntryBytes) {
        errors.add(
          '资源包单文件过大: ${file.name} (${file.size} 字节，上限 ${limits.maxSingleEntryBytes})',
        );
        continue;
      }
      if (totalBytes > limits.maxUncompressedBytes - file.size) {
        errors.add(
          '资源包解压后过大（上限 ${limits.maxUncompressedBytes} 字节）',
        );
        break;
      }
      totalBytes += file.size;
    }
    return errors;
  }

  static List<String> _validateManifest(
    Map<String, dynamic> manifest,
    Map<String, ArchiveFile> entries,
  ) {
    final errors = <String>[];
    final version = manifest['schema_version'];
    if (version is! int ||
        !BookPackSchema.supportedSchemaVersions.contains(version)) {
      errors.add(
          '不支持的 schema_version: $version（支持: ${BookPackSchema.supportedSchemaVersions}），请升级 App');
    }

    final bookId = manifest['book_id'];
    if (bookId is! String || !BookPackSchema.bookIdPattern.hasMatch(bookId)) {
      errors.add('book_id 格式非法: $bookId');
    }
    _requireNonEmptyString(manifest, 'title', errors);
    if (manifest['language'] != 'en') {
      errors.add('language 必须是 en: ${manifest['language']}');
    }
    final createdAt = manifest['created_at'];
    if (createdAt is! String || DateTime.tryParse(createdAt) == null) {
      errors.add('created_at 必须是有效时间: $createdAt');
    }
    final generator = manifest['generator'];
    if (generator is! Map<String, dynamic>) {
      errors.add('generator 必须是对象');
    } else {
      _requireNonEmptyString(generator, 'name', errors, prefix: 'generator.');
      _requireNonEmptyString(generator, 'version', errors,
          prefix: 'generator.');
    }
    _validateImageSpec(manifest['page_image'], 'page_image', 'webp', errors);
    _validateImageSpec(manifest['thumbnail'], 'thumbnail', 'jpg', errors);

    final pageCount = manifest['page_count'];
    final rawPages = manifest['pages'];
    if (pageCount is! int || pageCount < 1) {
      errors.add('page_count 非法: $pageCount');
    }
    if (rawPages is! List) {
      errors.add('pages 必须是数组');
      return errors;
    }
    if (pageCount is int && rawPages.length != pageCount) {
      errors.add('page_count 与 pages 数量不一致: $pageCount/${rawPages.length}');
    }

    final seenPageNumbers = <int>{};
    for (var index = 0; index < rawPages.length; index++) {
      final rawPage = rawPages[index];
      if (rawPage is! Map<String, dynamic>) {
        errors.add('pages[$index] 必须是对象');
        continue;
      }
      final pageNo = rawPage['page_no'];
      final image = rawPage['image'];
      final thumbnail = rawPage['thumbnail'];
      final width = rawPage['width_px'];
      final height = rawPage['height_px'];
      final sourceRegion = rawPage['source_region'];
      if (pageNo is! int || pageNo < 1 || !seenPageNumbers.add(pageNo)) {
        errors.add('pages[$index].page_no 非法或重复: $pageNo');
      }
      if (image is! String ||
          !RegExp(r'^pages/p[0-9]{4}\.webp$').hasMatch(image)) {
        errors.add('pages[$index].image 路径非法: $image');
      } else if (!_isFileEntry(entries, image)) {
        errors.add('缺少文件: $image');
      }
      if (thumbnail is! String ||
          !RegExp(r'^thumbnails/p[0-9]{4}\.jpg$').hasMatch(thumbnail)) {
        errors.add('pages[$index].thumbnail 路径非法: $thumbnail');
      } else if (!_isFileEntry(entries, thumbnail)) {
        errors.add('缺少文件: $thumbnail');
      }
      if (width is! int || width < 1 || height is! int || height < 1) {
        errors.add('pages[$index] 图片尺寸非法');
      }
      if (sourceRegion is! String ||
          !{'full', 'left', 'right', 'custom'}.contains(sourceRegion)) {
        errors.add('pages[$index].source_region 非法: $sourceRegion');
      }
    }
    if (pageCount is int &&
        seenPageNumbers.length == pageCount &&
        !Iterable<int>.generate(pageCount, (index) => index + 1)
            .every(seenPageNumbers.contains)) {
      errors.add('pages.page_no 必须从 1 连续编号');
    }
    return errors;
  }

  static void _requireNonEmptyString(
    Map<String, dynamic> value,
    String key,
    List<String> errors, {
    String prefix = '',
  }) {
    final raw = value[key];
    if (raw is! String || raw.trim().isEmpty) {
      errors.add('$prefix$key 必须是非空字符串');
    }
  }

  static void _validateImageSpec(
    Object? raw,
    String name,
    String expectedFormat,
    List<String> errors,
  ) {
    if (raw is! Map<String, dynamic>) {
      errors.add('$name 必须是对象');
      return;
    }
    if (raw['format'] != expectedFormat) {
      errors.add('$name.format 非法: ${raw['format']}');
    }
    final maxLongEdge = raw['max_long_edge_px'];
    if (maxLongEdge is! int || maxLongEdge < 1) {
      errors.add('$name.max_long_edge_px 非法');
    }
    final quality = raw['quality'];
    if (quality is! int || quality < 1 || quality > 100) {
      errors.add('$name.quality 非法');
    }
  }

  static bool _isFileEntry(
    Map<String, ArchiveFile> entries,
    String path,
  ) {
    final file = entries[path];
    return file != null && file.isFile && !file.isSymbolicLink;
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
        '${Directory.systemTemp.path}/ra_validate_${DateTime.now().microsecondsSinceEpoch}.db');
    sqflite.Database? db;
    try {
      await tmp.writeAsBytes(dbBytes);
      db = await databaseFactory.openDatabase(
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
        await _validateDatabaseIdentity(
          db,
          manifest: manifest,
          entries: entries,
          errors: errors,
        );
      }
    } on Object catch (error) {
      errors.add('alignment.db 校验失败: $error');
    } finally {
      try {
        await db?.close();
      } catch (_) {}
      try {
        await tmp.delete();
      } catch (_) {}
    }
    return errors;
  }

  static Future<void> _validateDatabaseIdentity(
    sqflite.Database db, {
    required Map<String, dynamic> manifest,
    required Map<String, ArchiveFile> entries,
    required List<String> errors,
  }) async {
    final bookId = manifest['book_id'];
    final bookRows = await db.query(
      'book',
      columns: const [
        'id',
        'title',
        'language',
        'schema_version',
        'created_at'
      ],
    );
    if (bookRows.length != 1) {
      errors.add('alignment.db book 必须恰好有一行');
      return;
    }
    final book = bookRows.single;
    if (book['id'] != bookId ||
        book['language'] != manifest['language'] ||
        book['schema_version'] != manifest['schema_version']) {
      errors.add('alignment.db book 身份与 manifest.json 不一致');
    }

    final manifestPages = (manifest['pages'] as List)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    final pages = await db.query('page', orderBy: 'page_no ASC');
    if (pages.length != manifestPages.length) {
      errors.add(
        'alignment.db page 数量与 manifest.json 不一致: '
        '${pages.length}/${manifestPages.length}',
      );
    }
    final pageByNumber = <int, Map<String, Object?>>{};
    for (final row in pages) {
      final pageNo = row['page_no'];
      if (pageNo is! int || pageByNumber.containsKey(pageNo)) {
        errors.add('alignment.db page.page_no 非法或重复: $pageNo');
        continue;
      }
      pageByNumber[pageNo] = row;
      final expected = manifestPages.firstWhere(
        (page) => page['page_no'] == pageNo,
        orElse: () => const <String, dynamic>{},
      );
      if (expected.isEmpty ||
          row['book_id'] != bookId ||
          row['image_path'] != expected['image'] ||
          row['thumbnail_path'] != expected['thumbnail'] ||
          row['width_px'] != expected['width_px'] ||
          row['height_px'] != expected['height_px'] ||
          row['source_region'] != expected['source_region']) {
        errors.add('alignment.db page $pageNo 与 manifest.json 不一致');
      }
      final imagePath = row['image_path'];
      final thumbnailPath = row['thumbnail_path'];
      if (imagePath is! String || !_isFileEntry(entries, imagePath)) {
        errors.add('alignment.db page $pageNo 缺少图片资源: $imagePath');
      }
      if (thumbnailPath is! String || !_isFileEntry(entries, thumbnailPath)) {
        errors.add('alignment.db page $pageNo 缺少缩略图资源: $thumbnailPath');
      }
    }

    final sentences = await db.query('sentence', orderBy: 'seq ASC');
    final sentenceById = <String, Map<String, Object?>>{};
    final pageNumbers = pageByNumber.keys.toSet();
    var expectedSequence = 1;
    for (final row in sentences) {
      final id = row['id'];
      final sequence = row['seq'];
      if (id is! String || !sentenceById.containsKey(id)) {
        if (id is String) sentenceById[id] = row;
      } else {
        errors.add('alignment.db sentence.id 重复: $id');
      }
      if (sequence is! int || sequence != expectedSequence) {
        errors.add('alignment.db sentence.seq 不连续: $sequence');
      }
      expectedSequence++;
      if (row['book_id'] != bookId ||
          row['page_no'] is! int ||
          !pageNumbers.contains(row['page_no'])) {
        errors.add('alignment.db sentence $id 的书籍或页码引用非法');
      }
      final text = row['text'];
      if (text is! String || text.trim().isEmpty) {
        errors.add('句子 $id text 为空');
      }
      _validateBbox(row['id'], row['bbox_json'], errors);
      final start = row['t_start'];
      final end = row['t_end'];
      if (start is! num ||
          end is! num ||
          !start.isFinite ||
          !end.isFinite ||
          end <= start ||
          start < 0) {
        errors.add('句子 $id 音频时间范围非法');
      }
      final audioPath = row['audio_path'];
      if (audioPath is! String || !_isFileEntry(entries, audioPath)) {
        errors.add('句子 $id 缺少音频资源: $audioPath');
      }
    }

    final words = await db.query(
      'word_timing',
      orderBy: 'sentence_id ASC, seq ASC',
    );
    final lastWordSequence = <String, int>{};
    for (final row in words) {
      final sentenceId = row['sentence_id'];
      final sequence = row['seq'];
      final sentence = sentenceId is String ? sentenceById[sentenceId] : null;
      if (sentence == null) {
        errors.add('word_timing 引用了不存在的句子: $sentenceId');
        continue;
      }
      final sentenceKey = sentenceId as String;
      final expectedWordSequence = (lastWordSequence[sentenceKey] ?? 0) + 1;
      if (sequence is! int || sequence != expectedWordSequence) {
        errors.add('句子 $sentenceKey 的 word_timing.seq 不连续: $sequence');
      }
      lastWordSequence[sentenceKey] = expectedWordSequence;
      final word = row['word'];
      if (word is! String || word.trim().isEmpty) {
        errors.add('句子 $sentenceKey 存在空词');
      }
      final start = row['t_start'];
      final end = row['t_end'];
      final sentenceStart = sentence['t_start'];
      final sentenceEnd = sentence['t_end'];
      if (start is! num ||
          end is! num ||
          sentenceStart is! num ||
          sentenceEnd is! num ||
          !start.isFinite ||
          !end.isFinite ||
          end <= start ||
          start < sentenceStart ||
          end > sentenceEnd) {
        errors.add('句子 $sentenceKey 的词时间范围非法');
      }
    }
  }

  static void _validateBbox(
    Object? id,
    Object? rawValue,
    List<String> errors,
  ) {
    try {
      final bbox = jsonDecode(rawValue as String) as Map<String, dynamic>;
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
    } on Object catch (error) {
      errors.add('句子 $id bbox_json 解析失败: $error');
    }
  }
}
