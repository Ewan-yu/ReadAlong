import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_page.dart';
import 'package:reader_app/features/reader/original_audio_player.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';
import 'package:reader_app/features/reader/reader_models.dart';
import 'package:reader_app/features/reader/reader_repository.dart';

final class _FakeOriginalAudioPlayer implements OriginalAudioPlayer {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final loadedPaths = <String>[];
  final seeked = <Duration>[];
  var playCalls = 0;
  var pauseCalls = 0;
  var stopCalls = 0;

  @override
  Stream<Duration> get positionStream => positions.stream;

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  Future<void> dispose() async {
    await positions.close();
    await playing.close();
  }

  @override
  Future<void> load(String path) async => loadedPaths.add(path);

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> play() async {
    playCalls++;
    playing.add(true);
  }

  @override
  Future<void> seek(Duration position) async => seeked.add(position);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    playing.add(false);
  }
}

void main() {
  final readerBook = ReaderBook(
    libraryId: 'copy-1',
    sourceBookId: 'story-1',
    title: 'Moon Story',
    pages: const [
      ReaderPageData(
        pageNumber: 1,
        imagePath: 'not-present.webp',
        thumbnailPath: 'not-present.jpg',
        widthPx: 1200,
        heightPx: 1600,
      ),
    ],
  );
  final originalBook = OriginalAudioBook(
    libraryId: 'copy-1',
    audioPath: 'original/source.mp3',
    duration: const Duration(seconds: 4),
    sentences: [
      OriginalAudioSentence(
        id: 's1',
        sequence: 1,
        text: 'Good night.',
        start: Duration.zero,
        end: const Duration(milliseconds: 1800),
        words: const [
          OriginalAudioWord(
            sequence: 1,
            text: 'Good',
            start: Duration.zero,
            end: Duration(milliseconds: 900),
          ),
          OriginalAudioWord(
            sequence: 2,
            text: 'night.',
            start: Duration(milliseconds: 900),
            end: Duration(milliseconds: 1800),
          ),
        ],
      ),
      OriginalAudioSentence(
        id: 's2',
        sequence: 2,
        text: 'Good morning.',
        start: const Duration(milliseconds: 2200),
        end: const Duration(seconds: 4),
        words: const [
          OriginalAudioWord(
            sequence: 1,
            text: 'Good',
            start: Duration(milliseconds: 2200),
            end: Duration(milliseconds: 3100),
          ),
          OriginalAudioWord(
            sequence: 2,
            text: 'morning.',
            start: Duration(milliseconds: 3100),
            end: Duration(seconds: 4),
          ),
        ],
      ),
    ],
  );

  Future<void> pumpPage(
    WidgetTester tester,
    _FakeOriginalAudioPlayer player,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerBookProvider('copy-1').overrideWith((_) async => readerBook),
          originalAudioBookProvider('copy-1')
              .overrideWith((_) async => originalBook),
          originalAudioPlayerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const OriginalAudioPage(libraryId: 'copy-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('原音页以封面点缀、大字歌词和独立控制器呈现', (tester) async {
    final player = _FakeOriginalAudioPlayer();
    addTearDown(player.dispose);

    await pumpPage(tester, player);

    expect(player.loadedPaths, ['original/source.mp3']);
    expect(find.text('Moon Story'), findsNWidgets(2));
    expect(find.text('原音欣赏'), findsOneWidget);
    expect(find.byKey(const ValueKey('original-audio-cover')), findsOneWidget);
    expect(find.byKey(const ValueKey('original-audio-lyrics')), findsOneWidget);
    expect(find.text('Good night.'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('original-audio-controls')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('original-audio-play-toggle'))),
      const Size(AppSizes.primaryButton, AppSizes.primaryButton),
    );
  });

  testWidgets('位置流按绝对时间切句，句子跳转与播放控制可用', (tester) async {
    final player = _FakeOriginalAudioPlayer();
    addTearDown(player.dispose);
    await pumpPage(tester, player);

    await tester.tap(find.byKey(const ValueKey('original-audio-play-toggle')));
    await tester.pump();
    expect(player.playCalls, 1);

    player.positions.add(const Duration(milliseconds: 2300));
    await tester.pump();
    expect(find.text('Good morning.'), findsOneWidget);

    await tester.tap(find.byTooltip('上一句'));
    await tester.pump();
    expect(player.seeked.last, Duration.zero);

    await tester.tap(find.byTooltip('下一句'));
    await tester.pump();
    expect(player.seeked.last, const Duration(milliseconds: 2200));
  });
}
