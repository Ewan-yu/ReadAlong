import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/alignment_repository.dart';
import 'package:reader_app/features/reader/point_reading_controller.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';

final class _ControlledAudioPlayer implements SentenceAudioPlayer {
  final played = <SentenceAudioClip>[];
  final pending = <Completer<void>>[];
  final positionCallbacks = <void Function(Duration elapsed)?>[];
  var stopCalls = 0;
  var disposeCalls = 0;
  Object? nextFailure;

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) {
    played.add(clip);
    positionCallbacks.add(onPosition);
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) return Future.error(failure);
    final completer = Completer<void>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

ReaderSentence _sentence({
  required String id,
  required int sequence,
  required NormalizedRect bbox,
  bool shared = false,
  int pageNumber = 1,
  Duration clipStart = Duration.zero,
  Duration clipEnd = const Duration(seconds: 1),
  List<ReaderWordTiming> wordTimings = const [],
}) =>
    ReaderSentence(
      id: id,
      pageNumber: pageNumber,
      sequence: sequence,
      text: id,
      bbox: bbox,
      sharedBbox: shared,
      audio: SentenceAudioClip(
        path: '$id.ogg',
        start: clipStart,
        end: clipEnd,
      ),
      wordTimings: wordTimings,
    );

void main() {
  const firstBox = NormalizedRect(
    x: 0.1,
    y: 0.1,
    width: 0.3,
    height: 0.1,
  );
  const secondBox = NormalizedRect(
    x: 0.1,
    y: 0.4,
    width: 0.3,
    height: 0.1,
  );
  late _ControlledAudioPlayer player;
  late PointReadingBook book;
  late ProviderContainer container;
  ProviderSubscription<AsyncValue<PointReadingState>>? subscription;
  late List<String> requestedLibraryIds;

  setUp(() {
    player = _ControlledAudioPlayer();
    book = PointReadingBook(
      libraryId: 'copy-2',
      sentences: [
        _sentence(id: 'first', sequence: 1, bbox: firstBox),
        _sentence(id: 'second', sequence: 2, bbox: secondBox),
      ],
    );
    requestedLibraryIds = [];
    container = ProviderContainer(
      overrides: [
        pointReadingBookProvider.overrideWith((ref, libraryId) async {
          requestedLibraryIds.add(libraryId);
          return book;
        }),
        sentenceAudioPlayerProvider.overrideWith((ref) {
          ref.onDispose(() {
            unawaited(player.stop());
            unawaited(player.dispose());
          });
          return player;
        }),
      ],
    );
    subscription = null;
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await pumpEventQueue();
  });

  Future<PointReadingController> readyController() async {
    subscription ??= container.listen(
      pointReadingControllerProvider('copy-2'),
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(pointReadingControllerProvider('copy-2').future);
    return container.read(pointReadingControllerProvider('copy-2').notifier);
  }

  PointReadingState currentState() =>
      container.read(pointReadingControllerProvider('copy-2')).requireValue;

  test('build 加载精确 libraryId 的点读索引', () async {
    await readyController();

    expect(requestedLibraryIds, ['copy-2']);
    expect(currentState().book, same(book));
    expect(currentState().activeSentence, isNull);
  });

  test('普通句播放期间高亮且完成后清除', () async {
    final controller = await readyController();

    final playing = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();

    expect(player.stopCalls, 1);
    expect(player.played.map((clip) => clip.path), ['first.ogg']);
    expect(currentState().activeSentence?.id, 'first');
    expect(currentState().subtitleSentence?.id, 'first');
    expect(currentState().playbackPosition, Duration.zero);
    expect(currentState().playbackDuration, const Duration(seconds: 1));
    expect(currentState().isPlaying, isTrue);

    player.pending.single.complete();
    await playing;
    expect(currentState().activeSentence, isNull);
    expect(currentState().isPlaying, isFalse);
    expect(currentState().subtitleSentence?.id, 'first');
    expect(currentState().playbackPosition, const Duration(seconds: 1));
    expect(currentState().activeWordIndex, isNull);
  });

  test('位置回调更新片段进度和当前词', () async {
    book = PointReadingBook(
      libraryId: 'copy-2',
      sentences: [
        _sentence(
          id: 'first',
          sequence: 1,
          bbox: firstBox,
          clipStart: const Duration(seconds: 5),
          clipEnd: const Duration(seconds: 6),
          wordTimings: const [
            ReaderWordTiming(
              id: 'w1',
              sequence: 1,
              word: 'first',
              start: Duration(seconds: 5),
              end: Duration(milliseconds: 5400),
            ),
            ReaderWordTiming(
              id: 'w2',
              sequence: 2,
              word: 'again',
              start: Duration(milliseconds: 5600),
              end: Duration(seconds: 6),
            ),
          ],
        ),
      ],
    );
    final controller = await readyController();
    final playing = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();

    player.positionCallbacks.single!(const Duration(milliseconds: 200));
    expect(currentState().playbackPosition, const Duration(milliseconds: 200));
    expect(currentState().activeWordIndex, 0);

    player.positionCallbacks.single!(const Duration(milliseconds: 500));
    expect(currentState().activeWordIndex, isNull);

    player.positionCallbacks.single!(const Duration(milliseconds: 700));
    expect(currentState().activeWordIndex, 1);
    player.pending.single.complete();
    await playing;
  });

  test('共享 bbox 按 seq 连续播放并逐句更新高亮', () async {
    book = PointReadingBook(
      libraryId: 'copy-2',
      sentences: [
        _sentence(id: 'second', sequence: 2, bbox: firstBox, shared: true),
        _sentence(id: 'first', sequence: 1, bbox: firstBox, shared: true),
      ],
    );
    final controller = await readyController();

    final playing = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();
    expect(currentState().activeSentence?.id, 'first');

    player.pending[0].complete();
    await pumpEventQueue();
    expect(player.played.map((clip) => clip.path), ['first.ogg', 'second.ogg']);
    expect(currentState().activeSentence?.id, 'second');
    expect(currentState().subtitleSentence?.id, 'second');
    expect(currentState().playbackPosition, Duration.zero);

    player.pending[1].complete();
    await playing;
    expect(currentState().activeSentence, isNull);
  });

  test('快速新点击使旧 Future 失效且旧完成不清除新高亮', () async {
    final controller = await readyController();

    final firstPlay = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();
    final secondPlay = controller.playAt(1, const Offset(0.2, 0.45));
    await pumpEventQueue();

    expect(player.stopCalls, 2);
    expect(currentState().activeSentence?.id, 'second');
    player.positionCallbacks[0]!(const Duration(milliseconds: 800));
    expect(currentState().subtitleSentence?.id, 'second');
    expect(currentState().playbackPosition, Duration.zero);
    player.pending[0].complete();
    await firstPlay;
    expect(currentState().activeSentence?.id, 'second');

    player.pending[1].complete();
    await secondPlay;
    expect(currentState().activeSentence, isNull);
  });

  test('未命中不停止当前播放', () async {
    final controller = await readyController();
    final playing = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();
    final stopsBeforeMiss = player.stopCalls;

    await controller.playAt(1, const Offset(0.9, 0.9));

    expect(player.stopCalls, stopsBeforeMiss);
    expect(currentState().activeSentence?.id, 'first');
    expect(currentState().subtitleSentence?.id, 'first');
    player.pending.single.complete();
    await playing;
  });

  test('翻页立即停止并清除且旧完成不恢复状态', () async {
    final controller = await readyController();
    final playing = controller.playAt(1, const Offset(0.2, 0.15));
    await pumpEventQueue();

    await controller.stopForPageChange();

    expect(player.stopCalls, 2);
    expect(currentState().activeSentence, isNull);
    expect(currentState().subtitleSentence, isNull);
    player.pending.single.complete();
    await playing;
    expect(currentState().activeSentence, isNull);
  });

  test('播放失败可消费并允许后续句重试', () async {
    final controller = await readyController();
    player.nextFailure = const SentencePlaybackException();

    await controller.playAt(1, const Offset(0.2, 0.15));

    expect(currentState().activeSentence, isNull);
    expect(currentState().subtitleSentence?.id, 'first');
    expect(currentState().failure, PointReadingFailure.playback);
    controller.clearFailure();
    expect(currentState().failure, isNull);

    final retry = controller.playAt(1, const Offset(0.2, 0.45));
    await pumpEventQueue();
    expect(currentState().activeSentence?.id, 'second');
    player.pending.single.complete();
    await retry;
  });

  test('Provider 销毁停止并释放播放器且不再写状态', () async {
    final controller = await readyController();
    unawaited(controller.playAt(1, const Offset(0.2, 0.15)));
    await pumpEventQueue();

    subscription!.close();
    await pumpEventQueue();

    expect(player.stopCalls, greaterThanOrEqualTo(1));
    expect(player.disposeCalls, 1);
    player.pending.single.complete();
    await pumpEventQueue();
  });
}
