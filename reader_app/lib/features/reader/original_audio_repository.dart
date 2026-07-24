import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/schema_constants.dart';
import 'original_audio_models.dart';
import 'subtitle_timing.dart';

abstract interface class OriginalAudioRepository {
  Future<OriginalAudioBook> loadBook(String libraryId);
}

final originalAudioRepositoryProvider =
    FutureProvider<OriginalAudioRepository>((ref) async {
  final shelfIndex = await ref.watch(shelfIndexProvider.future);
  return LocalOriginalAudioRepository(
    shelfIndex: shelfIndex,
    databaseFactory: ref.watch(appDatabaseFactoryProvider),
  );
});

final originalAudioBookProvider =
    FutureProvider.family<OriginalAudioBook, String>((ref, libraryId) async {
  final repository = await ref.watch(originalAudioRepositoryProvider.future);
  return repository.loadBook(libraryId);
});

/// 将 manifest、时间轴、原音文件和 alignment.db 交叉校验后才交给页面。
/// 这让旧 App 已导入的包、落盘被篡改的包，都不会错误地露出原音入口。
final class LocalOriginalAudioRepository implements OriginalAudioRepository {
  const LocalOriginalAudioRepository({
    required this.shelfIndex,
    required this.databaseFactory,
  });

  final ShelfIndex shelfIndex;
  final DatabaseFactory databaseFactory;

  @override
  Future<OriginalAudioBook> loadBook(String libraryId) async {
    final shelfBook = await shelfIndex.findByLibraryId(libraryId);
    if (shelfBook == null) {
      throw const OriginalAudioUnavailableException('Shelf book was not found');
    }
    try {
      final manifest =
          await _readObject(p.join(shelfBook.bookDir, 'manifest.json'));
      if (manifest['book_id'] != shelfBook.sourceBookId) {
        throw const OriginalAudioDataException(
          'Manifest source identity mismatch',
        );
      }
      final original = manifest['original_audio'];
      if (original is! Map<String, dynamic> ||
          original['alignment_status'] !=
              BookPackSchema.originalAudioReadyStatus) {
        throw const OriginalAudioUnavailableException();
      }
      final sourcePath = _resolveInside(shelfBook.bookDir, original['path']);
      final timelinePath =
          _resolveInside(shelfBook.bookDir, original['timeline_path']);
      if (!File(sourcePath).existsSync() || !File(timelinePath).existsSync()) {
        throw const OriginalAudioDataException(
          'Original audio resource is missing',
        );
      }
      final durationMs = _positiveInt(original['duration_ms']);
      final audioHash = original['sha256'];
      if (audioHash is! String ||
          !BookPackSchema.sha256Pattern.hasMatch(audioHash)) {
        throw const OriginalAudioDataException(
            'Original audio hash is invalid');
      }
      final actualAudioHash =
          (await sha256.bind(File(sourcePath).openRead()).first).toString();
      if (actualAudioHash != audioHash) {
        throw const OriginalAudioDataException('Original audio hash mismatch');
      }

      final timelineBytes = await File(timelinePath).readAsBytes();
      if (original['timeline_sha256'] is! String ||
          original['timeline_sha256'] !=
              sha256.convert(timelineBytes).toString()) {
        throw const OriginalAudioDataException('Timeline hash mismatch');
      }
      final timeline = _decodeObject(timelineBytes);
      final source = timeline['source'];
      if (timeline['schema_version'] != 1 ||
          source is! Map<String, dynamic> ||
          source['original_audio_sha256'] != audioHash ||
          original['vocal_sha256'] != source['vocal_sha256']) {
        throw const OriginalAudioDataException(
            'Timeline audio identity mismatch');
      }
      final sourceSentences = await _loadSourceSentences(shelfBook);
      if (original['timeline_sentence_count'] is! int ||
          (original['timeline_sentence_count'] as int) <= 0) {
        throw const OriginalAudioDataException(
            'Timeline sentence count is invalid');
      }
      final sentences = _parseTimeline(
        timeline,
        sourceSentences,
        Duration(milliseconds: durationMs),
      );
      if (sentences.length != original['timeline_sentence_count']) {
        throw const OriginalAudioDataException(
            'Timeline sentence count mismatch');
      }
      final backgroundPath = await _loadConfirmedBackground(
        bookDirectory: shelfBook.bookDir,
        original: original,
      );
      return OriginalAudioBook(
        libraryId: shelfBook.libraryId,
        audioPath: sourcePath,
        duration: Duration(milliseconds: durationMs),
        sentences: sentences,
        sourceBookId: shelfBook.sourceBookId,
        resourceSha256: audioHash,
        timelineSha256: original['timeline_sha256']! as String,
        backgroundPath: backgroundPath,
      );
    } on OriginalAudioLoadException {
      rethrow;
    } on Object {
      throw const OriginalAudioDataException();
    }
  }

  Future<String?> _loadConfirmedBackground({
    required String bookDirectory,
    required Map<String, dynamic> original,
  }) async {
    final background = original['background'];
    if (background == null) return null;
    if (background is! Map<String, dynamic> ||
        background['path'] != 'original/background.ogg' ||
        background['sha256'] is! String ||
        !BookPackSchema.sha256Pattern
            .hasMatch(background['sha256'] as String)) {
      throw const OriginalAudioDataException(
          'Background track declaration is invalid');
    }
    final path = _resolveInside(bookDirectory, background['path']);
    if (!await File(path).exists()) {
      throw const OriginalAudioDataException('Background track is missing');
    }
    final hash = (await sha256.bind(File(path).openRead()).first).toString();
    if (hash != background['sha256']) {
      throw const OriginalAudioDataException('Background track hash mismatch');
    }
    return path;
  }

  Future<List<({String id, int pageNumber, int sequence, String text})>>
      _loadSourceSentences(ShelfBook shelfBook) async {
    final path = p.join(shelfBook.bookDir, 'align', 'alignment.db');
    if (!File(path).existsSync()) {
      throw const OriginalAudioDataException('Alignment database is missing');
    }
    Database? database;
    try {
      database = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final books = await database.query('book', columns: const ['id']);
      if (books.length != 1 || books.single['id'] != shelfBook.sourceBookId) {
        throw const OriginalAudioDataException(
          'Alignment source identity mismatch',
        );
      }
      final rows = await database.query(
        'sentence',
        columns: const ['id', 'page_no', 'seq', 'text'],
        orderBy: 'seq ASC',
      );
      final result =
          <({String id, int pageNumber, int sequence, String text})>[];
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final id = row['id'];
        final pageNumber = row['page_no'];
        final sequence = row['seq'];
        final text = row['text'];
        if (id is! String ||
            id.isEmpty ||
            pageNumber is! int ||
            pageNumber < 1 ||
            sequence is! int ||
            sequence != index + 1 ||
            text is! String ||
            text.trim().isEmpty) {
          throw const OriginalAudioDataException(
            'Alignment sentence is invalid',
          );
        }
        result.add((
          id: id,
          pageNumber: pageNumber,
          sequence: sequence,
          text: text,
        ));
      }
      if (result.isEmpty) {
        throw const OriginalAudioDataException('Alignment has no sentences');
      }
      return result;
    } finally {
      await database?.close();
    }
  }
}

Future<Map<String, dynamic>> _readObject(String path) async =>
    _decodeObject(await File(path).readAsBytes());

Map<String, dynamic> _decodeObject(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw const OriginalAudioDataException('JSON root must be an object');
  }
  return decoded;
}

List<OriginalAudioSentence> _parseTimeline(
  Map<String, dynamic> timeline,
  List<({String id, int pageNumber, int sequence, String text})>
      sourceSentences,
  Duration duration,
) {
  final rawSentences = timeline['sentences'];
  if (rawSentences is! List || rawSentences.isEmpty) {
    throw const OriginalAudioDataException('Timeline sentence count mismatch');
  }
  final sourceById = {
    for (final sentence in sourceSentences) sentence.id: sentence,
  };
  final sentences = <OriginalAudioSentence>[];
  var previousEnd = Duration.zero;
  var previousSourceSequence = 0;
  final seenIds = <String>{};
  for (final raw in rawSentences) {
    final rawId = raw is Map<String, dynamic> ? raw['sentence_id'] : null;
    final source = rawId is String ? sourceById[rawId] : null;
    if (raw is! Map<String, dynamic> ||
        source == null ||
        !seenIds.add(source.id) ||
        raw['sentence_id'] != source.id ||
        raw['page_no'] != source.pageNumber ||
        raw['seq'] != source.sequence ||
        raw['text'] != source.text ||
        source.sequence <= previousSourceSequence) {
      throw const OriginalAudioDataException(
        'Timeline sentence identity mismatch',
      );
    }
    final start = _millisecondsToDuration(raw['start_ms']);
    final end = _millisecondsToDuration(raw['end_ms']);
    if (end <= start || start < previousEnd || end > duration) {
      throw const OriginalAudioDataException(
          'Timeline sentence range is invalid');
    }
    final words = _parseWords(raw['words'], source.text, start, end);
    sentences.add(OriginalAudioSentence(
      id: source.id,
      sequence: source.sequence,
      text: source.text,
      start: start,
      end: end,
      words: words,
    ));
    previousEnd = end;
    previousSourceSequence = source.sequence;
  }
  return List.unmodifiable(sentences);
}

List<OriginalAudioWord> _parseWords(
  Object? rawWords,
  String sentenceText,
  Duration sentenceStart,
  Duration sentenceEnd,
) {
  if (rawWords is! List || rawWords.isEmpty) {
    throw const OriginalAudioDataException('Timeline words are missing');
  }
  final words = <OriginalAudioWord>[];
  var previousEnd = sentenceStart;
  for (var index = 0; index < rawWords.length; index++) {
    final raw = rawWords[index];
    if (raw is! Map<String, dynamic>) {
      throw const OriginalAudioDataException('Timeline word is invalid');
    }
    final sequence = raw['seq'];
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const OriginalAudioDataException('Timeline word text is invalid');
    }
    if (sequence is! int || sequence != index + 1) {
      throw const OriginalAudioDataException(
          'Timeline word sequence is invalid');
    }
    final start = _millisecondsToDuration(raw['start_ms']);
    final end = _millisecondsToDuration(raw['end_ms']);
    if (end <= start ||
        start < previousEnd ||
        start < sentenceStart ||
        end > sentenceEnd) {
      throw const OriginalAudioDataException('Timeline word range is invalid');
    }
    words.add(OriginalAudioWord(
      sequence: sequence,
      text: text,
      start: start,
      end: end,
    ));
    previousEnd = end;
  }
  final sourceWords = normalizedSubtitleWords(sentenceText);
  final timelineWords = words
      .expand((word) => normalizedSubtitleWords(word.text))
      .toList(growable: false);
  if (sourceWords.isEmpty ||
      sourceWords.length != timelineWords.length ||
      !_sameWords(sourceWords, timelineWords)) {
    throw const OriginalAudioDataException('Timeline word text mismatch');
  }
  return List.unmodifiable(words);
}

bool _sameWords(List<String> left, List<String> right) {
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

int _positiveInt(Object? value) {
  if (value is! int || value <= 0) {
    throw const OriginalAudioDataException('Timeline duration is invalid');
  }
  return value;
}

Duration _millisecondsToDuration(Object? value) {
  if (value is! int || value < 0) {
    throw const OriginalAudioDataException('Timeline duration is invalid');
  }
  return Duration(milliseconds: value);
}

String _resolveInside(String bookDir, Object? relativePath) {
  if (relativePath is! String ||
      relativePath.isEmpty ||
      p.isAbsolute(relativePath)) {
    throw const OriginalAudioDataException('Original resource path is invalid');
  }
  final root = p.normalize(p.absolute(bookDir));
  final resolved = p.normalize(p.absolute(p.join(root, relativePath)));
  if (!p.isWithin(root, resolved)) {
    throw const OriginalAudioDataException(
        'Original resource path escapes book');
  }
  return resolved;
}
