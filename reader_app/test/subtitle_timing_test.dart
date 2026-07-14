import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/subtitle_timing.dart';

ReaderSentence _sentence({
  String text = 'Good night.',
  Duration clipStart = Duration.zero,
  Duration clipEnd = const Duration(seconds: 2),
  List<ReaderWordTiming> timings = const [],
}) =>
    ReaderSentence(
      id: 's1',
      pageNumber: 1,
      sequence: 1,
      text: text,
      bbox: const NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
      sharedBbox: false,
      audio: SentenceAudioClip(
        path: 's1.ogg',
        start: clipStart,
        end: clipEnd,
      ),
      wordTimings: timings,
    );

ReaderWordTiming _word(
  int sequence,
  String text,
  int startMs,
  int endMs,
) =>
    ReaderWordTiming(
      id: 'w$sequence',
      sequence: sequence,
      word: text,
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
    );

void main() {
  test('播放位置裁剪到片段范围且进度稳定', () {
    const duration = Duration(seconds: 2);

    expect(
      clampPlaybackPosition(const Duration(milliseconds: -1), duration),
      Duration.zero,
    );
    expect(
      clampPlaybackPosition(const Duration(milliseconds: 750), duration),
      const Duration(milliseconds: 750),
    );
    expect(
      clampPlaybackPosition(const Duration(seconds: 3), duration),
      duration,
    );
    expect(playbackProgress(Duration.zero, duration), 0);
    expect(
      playbackProgress(const Duration(milliseconds: 750), duration),
      closeTo(0.375, 0.000001),
    );
    expect(playbackProgress(const Duration(seconds: 3), duration), 1);
    expect(playbackProgress(Duration.zero, Duration.zero), 0);
  });

  test('非零 clip 起点使用底层音源绝对时间查词', () {
    final sentence = _sentence(
      clipStart: const Duration(seconds: 5),
      clipEnd: const Duration(seconds: 7),
      timings: [
        _word(1, 'Good', 5000, 5800),
        _word(2, 'night.', 6000, 7000),
      ],
    );

    expect(activeWordIndex(sentence, Duration.zero), 0);
    expect(
      activeWordIndex(sentence, const Duration(milliseconds: 999)),
      isNull,
    );
    expect(activeWordIndex(sentence, const Duration(seconds: 1)), 1);
    expect(activeWordIndex(sentence, const Duration(seconds: 2)), isNull);
  });

  test('词区间左闭右开且词间静音不高亮', () {
    final sentence = _sentence(
      timings: [
        _word(1, 'Good', 100, 700),
        _word(2, 'night.', 900, 1700),
      ],
    );

    expect(activeWordIndex(sentence, Duration.zero), isNull);
    expect(activeWordIndex(sentence, const Duration(milliseconds: 100)), 0);
    expect(activeWordIndex(sentence, const Duration(milliseconds: 699)), 0);
    expect(
        activeWordIndex(sentence, const Duration(milliseconds: 700)), isNull);
    expect(
        activeWordIndex(sentence, const Duration(milliseconds: 899)), isNull);
    expect(activeWordIndex(sentence, const Duration(milliseconds: 900)), 1);
    expect(
        activeWordIndex(sentence, const Duration(milliseconds: 1700)), isNull);
  });

  test('无 timing 时不查词且返回完整普通文本片段', () {
    final sentence = _sentence(text: 'No timing here.');

    expect(activeWordIndex(sentence, const Duration(seconds: 1)), isNull);
    expect(
      buildSubtitleSegments(sentence.text, sentence.wordTimings),
      [const SubtitleTextSegment(text: 'No timing here.')],
    );
  });

  test('字幕分段保留标点、多空格、重复词并精确重组原文', () {
    const text = '  Go, go... home!  ';
    final timings = [
      _word(1, 'Go', 0, 300),
      _word(2, 'go', 300, 600),
      _word(3, 'home!', 600, 1000),
    ];

    final segments = buildSubtitleSegments(text, timings);

    expect(segments.map((segment) => segment.text).join(), text);
    expect(
      segments.where((segment) => segment.wordIndex != null).map(
            (segment) => (segment.text, segment.wordIndex),
          ),
      [('Go', 0), ('go', 1), ('home', 2)],
    );
  });

  test('apostrophe 和 hyphen 作为单词内部字符', () {
    const text = "Grandma's well-loved book.";
    final timings = [
      _word(1, "Grandma's", 0, 400),
      _word(2, 'well-loved', 400, 800),
      _word(3, 'book.', 800, 1200),
    ];

    final segments = buildSubtitleSegments(text, timings);

    expect(segments.map((segment) => segment.text).join(), text);
    expect(
      segments.where((segment) => segment.wordIndex != null).map(
            (segment) => segment.text,
          ),
      ["Grandma's", 'well-loved', 'book'],
    );
  });

  test('timing 词序与原文不一致时整句降级', () {
    final segments = buildSubtitleSegments(
      'Good night.',
      [_word(1, 'Wrong', 0, 1000)],
    );

    expect(segments, [const SubtitleTextSegment(text: 'Good night.')]);
  });
}
