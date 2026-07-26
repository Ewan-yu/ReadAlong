import 'package:flutter/material.dart';
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

  testWidgets('150px 高的完整配音试听歌词不会发生纵向溢出', (tester) async {
    final sentences = [
      sentence,
      OriginalAudioSentence(
        id: 's2',
        sequence: 2,
        text: 'My dress is short.',
        start: const Duration(seconds: 3),
        end: const Duration(seconds: 5),
        words: const [],
      ),
      OriginalAudioSentence(
        id: 's3',
        sequence: 3,
        text: "My grandpa's chopsticks are long.",
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 7),
        words: const [],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1500,
            height: 150,
            child: TimelineLyrics(
              sentences: sentences,
              currentIndex: 1,
              activeWordIndex: null,
              currentFontSize: 28,
              neighbourFontSize: 17,
              compact: true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('My dress is short.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
