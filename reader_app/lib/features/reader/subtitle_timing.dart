import 'point_reading_models.dart';

final class SubtitleTextSegment {
  const SubtitleTextSegment({required this.text, this.wordIndex});

  final String text;
  final int? wordIndex;

  @override
  bool operator ==(Object other) =>
      other is SubtitleTextSegment &&
      text == other.text &&
      wordIndex == other.wordIndex;

  @override
  int get hashCode => Object.hash(text, wordIndex);
}

final RegExp _subtitleWordPattern = RegExp(
  r"[A-Za-z0-9]+(?:['\u2019-][A-Za-z0-9]+)*",
);

List<String> normalizedSubtitleWords(String text) => _subtitleWordPattern
    .allMatches(text)
    .map((match) => match.group(0)!.toLowerCase())
    .toList(growable: false);

Duration clampPlaybackPosition(Duration elapsed, Duration clipDuration) {
  if (elapsed < Duration.zero) return Duration.zero;
  if (elapsed > clipDuration) return clipDuration;
  return elapsed;
}

double playbackProgress(Duration elapsed, Duration clipDuration) {
  if (clipDuration <= Duration.zero) return 0;
  final clamped = clampPlaybackPosition(elapsed, clipDuration);
  return clamped.inMicroseconds / clipDuration.inMicroseconds;
}

int? activeWordIndex(ReaderSentence sentence, Duration elapsed) {
  final timings = sentence.wordTimings;
  if (timings.isEmpty) return null;
  final clipDuration = sentence.audio.end - sentence.audio.start;
  final sourcePosition =
      sentence.audio.start + clampPlaybackPosition(elapsed, clipDuration);
  var low = 0;
  var high = timings.length - 1;
  var candidate = -1;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (timings[middle].start <= sourcePosition) {
      candidate = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  if (candidate < 0 || sourcePosition >= timings[candidate].end) return null;
  return candidate;
}

List<SubtitleTextSegment> buildSubtitleSegments(
  String text,
  List<ReaderWordTiming> timings,
) {
  if (timings.isEmpty) return [SubtitleTextSegment(text: text)];
  final matches = _subtitleWordPattern.allMatches(text).toList(growable: false);
  if (matches.length != timings.length) {
    return [SubtitleTextSegment(text: text)];
  }
  for (var index = 0; index < timings.length; index++) {
    final timingWords = normalizedSubtitleWords(timings[index].word);
    if (timingWords.length != 1 ||
        timingWords.single != matches[index].group(0)!.toLowerCase()) {
      return [SubtitleTextSegment(text: text)];
    }
  }

  final segments = <SubtitleTextSegment>[];
  var offset = 0;
  for (var index = 0; index < matches.length; index++) {
    final match = matches[index];
    if (match.start > offset) {
      segments
          .add(SubtitleTextSegment(text: text.substring(offset, match.start)));
    }
    segments.add(
      SubtitleTextSegment(
        text: text.substring(match.start, match.end),
        wordIndex: index,
      ),
    );
    offset = match.end;
  }
  if (offset < text.length) {
    segments.add(SubtitleTextSegment(text: text.substring(offset)));
  }
  return List.unmodifiable(segments);
}
