import 'dart:collection';
import 'dart:ui';

final class NormalizedRect {
  const NormalizedRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  })  : assert(x >= 0 && x <= 1),
        assert(y >= 0 && y <= 1),
        assert(width > 0 && width <= 1),
        assert(height > 0 && height <= 1),
        assert(x + width <= 1),
        assert(y + height <= 1);

  final double x;
  final double y;
  final double width;
  final double height;

  double get area => width * height;

  bool contains(Offset point) =>
      point.dx >= x &&
      point.dx <= x + width &&
      point.dy >= y &&
      point.dy <= y + height;

  NormalizedRect expand(double amount) {
    final left = (x - amount).clamp(0.0, 1.0);
    final top = (y - amount).clamp(0.0, 1.0);
    final right = (x + width + amount).clamp(0.0, 1.0);
    final bottom = (y + height + amount).clamp(0.0, 1.0);
    return NormalizedRect(
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NormalizedRect &&
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

final class SentenceAudioClip {
  const SentenceAudioClip({
    required this.path,
    required this.start,
    required this.end,
    this.wholeFile = false,
  });

  final String path;
  final Duration start;
  final Duration end;
  final bool wholeFile;
}

final class ReaderWordTiming {
  const ReaderWordTiming({
    required this.id,
    required this.sequence,
    required this.word,
    required this.start,
    required this.end,
  });

  final String id;
  final int sequence;
  final String word;
  final Duration start;
  final Duration end;
}

final class ReaderSentence {
  ReaderSentence({
    required this.id,
    required this.pageNumber,
    required this.sequence,
    required this.text,
    required this.bbox,
    required this.sharedBbox,
    required this.audio,
    List<ReaderWordTiming> wordTimings = const [],
  }) : wordTimings = List.unmodifiable(wordTimings);

  final String id;
  final int pageNumber;
  final int sequence;
  final String text;
  final NormalizedRect bbox;
  final bool sharedBbox;
  final SentenceAudioClip audio;
  final List<ReaderWordTiming> wordTimings;

  ReaderSentence withWordTimings(List<ReaderWordTiming> timings) =>
      ReaderSentence(
        id: id,
        pageNumber: pageNumber,
        sequence: sequence,
        text: text,
        bbox: bbox,
        sharedBbox: sharedBbox,
        audio: audio,
        wordTimings: timings,
      );
}

final class PointReadingBook {
  PointReadingBook({
    required this.libraryId,
    required List<ReaderSentence> sentences,
  }) : sentencesByPage = _indexSentences(libraryId, sentences);

  final String libraryId;
  final Map<int, List<ReaderSentence>> sentencesByPage;

  List<ReaderSentence> sentencesForPage(int pageNumber) =>
      sentencesByPage[pageNumber] ?? const [];
}

Map<int, List<ReaderSentence>> _indexSentences(
  String libraryId,
  List<ReaderSentence> source,
) {
  if (libraryId.isEmpty) {
    throw const PointReadingDataException('Library identity is empty');
  }
  final sentences = List<ReaderSentence>.of(source)
    ..sort((left, right) => left.sequence.compareTo(right.sequence));
  final ids = <String>{};
  final sequences = <int>{};
  final mutable = SplayTreeMap<int, List<ReaderSentence>>();
  for (final sentence in sentences) {
    if (sentence.id.isEmpty ||
        sentence.pageNumber < 1 ||
        sentence.sequence < 1 ||
        sentence.text.trim().isEmpty ||
        sentence.audio.path.isEmpty ||
        sentence.audio.start.isNegative ||
        sentence.audio.end <= sentence.audio.start) {
      throw const PointReadingDataException('Sentence data is invalid');
    }
    if (!ids.add(sentence.id) || !sequences.add(sentence.sequence)) {
      throw const PointReadingDataException(
        'Sentence identity or sequence is duplicated',
      );
    }
    mutable.putIfAbsent(sentence.pageNumber, () => []).add(sentence);
  }
  return UnmodifiableMapView({
    for (final entry in mutable.entries)
      entry.key: List<ReaderSentence>.unmodifiable(entry.value),
  });
}

sealed class PointReadingException implements Exception {
  const PointReadingException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class PointReadingDataException extends PointReadingException {
  const PointReadingDataException(super.message);
}

final class PointReadingLoadException extends PointReadingException {
  const PointReadingLoadException(super.message);
}
