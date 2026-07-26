import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/timeline_lyrics.dart';

void main() {
  final sentence = OriginalAudioSentence(
    id: 's1',
    sequence: 1,
    text: 'Good night.',
    start: const Duration(seconds: 1),
    end: const Duration(seconds: 3),
    words: const [
      OriginalAudioWord(
        sequence: 1,
        text: 'Good',
        start: Duration(milliseconds: 1100),
        end: Duration(milliseconds: 1500),
      ),
      OriginalAudioWord(
        sequence: 2,
        text: 'night',
        start: Duration(milliseconds: 1800),
        end: Duration(milliseconds: 2600),
      ),
    ],
  );

  test('完整时间轴在句首提前提示首词，并保持 80ms', () {
    expect(timelineActiveWordIndex(sentence, const Duration(seconds: 1)), 0);
    expect(
      timelineActiveWordIndex(
        sentence,
        const Duration(milliseconds: 1579),
      ),
      0,
    );
    expect(
      timelineActiveWordIndex(
        sentence,
        const Duration(milliseconds: 1580),
      ),
      isNull,
    );
  });

  test('首词保持结束后到第二词之前仍保持正常静音间隔', () {
    expect(
      timelineActiveWordIndex(
        sentence,
        const Duration(milliseconds: 1700),
      ),
      isNull,
    );
    expect(
      timelineActiveWordIndex(
        sentence,
        const Duration(milliseconds: 1800),
      ),
      1,
    );
  });
}
