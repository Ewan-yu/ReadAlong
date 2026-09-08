import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/features/reader/alignment_repository.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/reader_geometry.dart';
import 'package:reader_app/features/reader/reader_models.dart';
import 'package:reader_app/features/reader/reader_page.dart';
import 'package:reader_app/features/reader/reader_repository.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';
import 'package:reader_app/services/recording/recording_service.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/scoring_provider.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart'
    show scoringProvider;

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

final class _WidgetAudioPlayer implements SentenceAudioPlayer {
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

final class _WidgetRecorder implements AudioRecordingService {
  _WidgetRecorder(this.path, {this.stopError});

  final String path;
  final Object? stopError;

  @override
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  }) async =>
      RecordingSession(path: path, levels: const Stream.empty());

  @override
  Future<String> stop() async {
    final error = stopError;
    if (error != null) throw error;
    return path;
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

final class _WidgetScorer implements ScoringProvider {
  @override
  String get name => 'widget-test';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async =>
      const ScoreResult(
        childScore: 90,
        provider: 'widget-test',
        accuracy: 90,
        fluency: 90,
        integrity: 90,
      );
}

final class _ImmediatePreparation implements RecordingPreparationProtocol {
  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    onUpdate(const RecordingPreparationUpdate.countdown(3));
    return Duration.zero;
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('reader_page_test_');
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<String> imageFile(String name) async {
    final file = File(p.join(tempDir.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(base64Decode(_png));
    return file.path;
  }

  Future<ReaderBook> makeBook({
    int pageCount = 4,
    Set<int> missingImages = const {},
    Set<int> missingThumbnails = const {},
  }) async {
    final pages = <ReaderPageData>[];
    for (var number = 1; number <= pageCount; number++) {
      final imagePath = p.join(tempDir.path, 'pages', 'p$number.webp');
      final thumbnailPath = p.join(tempDir.path, 'thumbnails', 'p$number.jpg');
      if (!missingImages.contains(number)) {
        await imageFile(p.relative(imagePath, from: tempDir.path));
      }
      if (!missingThumbnails.contains(number)) {
        await imageFile(p.relative(thumbnailPath, from: tempDir.path));
      }
      pages.add(ReaderPageData(
        pageNumber: number,
        imagePath: imagePath,
        thumbnailPath: thumbnailPath,
        widthPx: 1200,
        heightPx: 1600,
      ));
    }
    return ReaderBook(
      libraryId: 'story-copy-2',
      sourceBookId: 'story-source',
      title: 'Moon Story With A Long Title',
      pages: pages,
    );
  }

  Future<ReaderBook> prepareBook(
    WidgetTester tester, {
    int pageCount = 4,
    Set<int> missingImages = const {},
    Set<int> missingThumbnails = const {},
  }) async {
    return (await tester.runAsync(
      () => makeBook(
        pageCount: pageCount,
        missingImages: missingImages,
        missingThumbnails: missingThumbnails,
      ),
    ))!;
  }

  Future<void> pumpReader(
    WidgetTester tester, {
    required Future<ReaderBook> book,
    Size size = const Size(1280, 800),
    Future<PointReadingBook>? pointReadingBook,
    SentenceAudioPlayer? audioPlayer,
    List<Override> overrides = const [],
  }) async {
    final effectivePlayer = audioPlayer ?? _WidgetAudioPlayer();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerBookProvider('story-copy-2').overrideWith((_) => book),
          pointReadingBookProvider('story-copy-2').overrideWith(
            (_) =>
                pointReadingBook ??
                Future.value(PointReadingBook(
                  libraryId: 'story-copy-2',
                  sentences: const [],
                )),
          ),
          sentenceAudioPlayerProvider.overrideWith((_) => effectivePlayer),
          ...overrides,
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ReaderPage(libraryId: 'story-copy-2'),
        ),
      ),
    );
  }

  ReaderSentence sentence({
    required String id,
    required int sequence,
    required NormalizedRect bbox,
    int pageNumber = 1,
    String? text,
    bool shared = false,
    Duration clipStart = Duration.zero,
    Duration clipEnd = const Duration(seconds: 1),
    List<ReaderWordTiming> wordTimings = const [],
  }) =>
      ReaderSentence(
        id: id,
        pageNumber: pageNumber,
        sequence: sequence,
        text: text ?? id,
        bbox: bbox,
        sharedBbox: shared,
        audio: SentenceAudioClip(
          path: '$id.ogg',
          start: clipStart,
          end: clipEnd,
        ),
        wordTimings: wordTimings,
      );

  Future<void> tapNormalized(
    WidgetTester tester, {
    required int pageNumber,
    required Offset normalized,
    Matrix4? transform,
  }) async {
    final surface = find.byKey(ValueKey('reader-tap-surface-$pageNumber'));
    final size = tester.getSize(surface);
    final imageRect = containedImageRect(
      canvasSize: size,
      imageSize: const Size(1200, 1600),
    );
    final scenePoint = Offset(
      imageRect.left + imageRect.width * normalized.dx,
      imageRect.top + imageRect.height * normalized.dy,
    );
    final viewportPoint = transform == null
        ? scenePoint
        : MatrixUtils.transformPoint(transform, scenePoint);
    await tester.tapAt(tester.getTopLeft(surface) + viewportPoint);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
  }

  testWidgets('加载时显示进度，完成后显示书名和页码', (tester) async {
    final readyBook = await prepareBook(tester);
    final completer = Completer<ReaderBook>();
    await pumpReader(tester, book: completer.future);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('返回书架'), findsOneWidget);

    completer.complete(readyBook);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Moon Story With A Long Title'), findsOneWidget);
    expect(find.text('1 / 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-page-view')), findsOneWidget);
  });

  testWidgets('整本书加载失败时显示重新导入提示', (tester) async {
    final completer = Completer<ReaderBook>();
    await pumpReader(
      tester,
      book: completer.future,
    );
    completer.completeError(StateError('broken manifest'));
    await tester.pumpAndSettle();

    expect(find.text('这本绘本暂时打不开'), findsOneWidget);
    expect(find.text('资源可能已损坏，请返回书架后重新导入'), findsOneWidget);
    expect(find.textContaining('broken manifest'), findsNothing);
  });

  testWidgets('跟读评价提供 48dp 独立关闭按钮', (tester) async {
    final target = sentence(
      id: 'follow-one',
      sequence: 1,
      text: 'My dad.',
      bbox: const NormalizedRect(x: .1, y: .1, width: .4, height: .1),
    );
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FollowScoreDialog(
          sentence: target,
          score: const ScoreResult(childScore: 90, provider: 'widget-test'),
          onClose: () => closed = true,
          onDemo: () {},
          onMyRecording: () {},
          onRepeat: () {},
          onNext: () {},
        ),
      ),
    ));

    expect(find.byKey(const ValueKey('follow-score-dialog')), findsOneWidget);
    expect(find.byTooltip('关闭评价'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('follow-score-close'))),
      const Size(48, 48),
    );

    await tester.tap(find.byKey(const ValueKey('follow-score-close')));
    expect(closed, isTrue);
  });

  testWidgets('单页原图缺失时保持翻页和页码状态', (tester) async {
    final book = await prepareBook(
      tester,
      pageCount: 2,
      missingImages: {2},
    );
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();

    expect(find.text('这一页的图片缺失'), findsOneWidget);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击缩略图与滑动翻页双向更新页码和选中语义', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-3')));
    await tester.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('reader-thumbnail-3')))
          .hasFlag(SemanticsFlag.isSelected),
      isTrue,
    );

    await tester.drag(
      find.byKey(const ValueKey('reader-page-view')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('reader-thumbnail-2')))
          .hasFlag(SemanticsFlag.isSelected),
      isTrue,
    );
  });

  testWidgets('切页时重置离开页面的缩放矩阵', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    final first = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('reader-canvas-1')),
    );
    first.transformationController!.value = Matrix4.identity()..scale(2.0);
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('reader-page-view')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();

    expect(
      first.transformationController!.value.storage,
      orderedEquals(Matrix4.identity().storage),
    );
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('宽屏使用右侧纵向缩略条并可收起且不改变当前页', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(
      tester,
      book: Future.value(book),
      size: const Size(1280, 800),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-thumbnail-strip-vertical')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-thumbnail-strip-horizontal')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('3 / 4'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-thumbnail-3')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窗口从宽屏缩到窄屏后切换为底部缩略条且没有溢出', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(
      tester,
      book: Future.value(book),
      size: const Size(1280, 800),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-thumbnail-strip-vertical')),
      findsOneWidget,
    );

    await tester.binding.setSurfaceSize(const Size(360, 800));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('reader-thumbnail-strip-horizontal')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-thumbnail-strip-vertical')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('缩略项和收起按钮满足 48dp 点击目标', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    final thumbnailSize =
        tester.getSize(find.byKey(const ValueKey('reader-thumbnail-1')));
    final toggleSize =
        tester.getSize(find.byKey(const ValueKey('reader-thumbnail-toggle')));
    expect(thumbnailSize.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    expect(thumbnailSize.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    expect(toggleSize.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
    expect(toggleSize.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
  });

  testWidgets('阅读页使用受限尺寸解码且不预载远端页面', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    bool isCached(int page) {
      final status = PaintingBinding.instance.imageCache.statusForKey(
        ResizeImage(
          FileImage(File(book.pages[page - 1].imagePath)),
          width: book.pages[page - 1].widthPx.clamp(1, 2048),
        ),
      );
      return status.pending || status.live || status.keepAlive;
    }

    final visible = tester.widget<Image>(
      find.byKey(const ValueKey('reader-page-image-1')),
    );
    expect(visible.image, isA<ResizeImage>());
    expect((visible.image as ResizeImage).width, lessThanOrEqualTo(2048));
    expect(isCached(3), isFalse);
    expect(isCached(4), isFalse);
  });

  testWidgets('未缩放点击播放正确句并显示与图片对齐的高亮', (tester) async {
    const bbox = NormalizedRect(
      x: 0.1,
      y: 0.2,
      width: 0.3,
      height: 0.1,
    );
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'first',
          sequence: 1,
          text: 'My dad.',
          clipEnd: const Duration(seconds: 2),
          bbox: bbox,
          wordTimings: [
            ReaderWordTiming(
              id: 'first-word-1',
              sequence: 1,
              word: 'My',
              start: Duration.zero,
              end: const Duration(seconds: 1),
            ),
            ReaderWordTiming(
              id: 'first-word-2',
              sequence: 2,
              word: 'dad.',
              start: const Duration(seconds: 1),
              end: const Duration(seconds: 2),
            ),
          ],
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.25, 0.25),
    );

    expect(player.played.map((clip) => clip.path), ['first.ogg']);
    expect(
      find.byKey(const ValueKey('reader-subtitle-active-word-0')),
      findsOneWidget,
    );
    final highlight = find.byKey(const ValueKey('reader-highlight-first'));
    expect(highlight, findsOneWidget);
    final surface = find.byKey(const ValueKey('reader-tap-surface-1'));
    final surfaceSize = tester.getSize(surface);
    final imageRect = containedImageRect(
      canvasSize: surfaceSize,
      imageSize: const Size(1200, 1600),
    );
    final expected = Rect.fromLTWH(
      tester.getTopLeft(surface).dx + imageRect.left + bbox.x * imageRect.width,
      tester.getTopLeft(surface).dy + imageRect.top + bbox.y * imageRect.height,
      bbox.width * imageRect.width,
      bbox.height * imageRect.height,
    );
    final actual = tester.getRect(highlight);
    expect(actual.left, closeTo(expected.left, 0.01));
    expect(actual.top, closeTo(expected.top, 0.01));
    expect(actual.width, closeTo(expected.width, 0.01));
    expect(actual.height, closeTo(expected.height, 0.01));

    player.positionCallbacks.single!(const Duration(milliseconds: 1200));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('reader-subtitle-active-word-1')),
      findsOneWidget,
    );
  });

  testWidgets('2x 缩放和平移后点击仍命中且高亮同步变换', (tester) async {
    const bbox = NormalizedRect(
      x: 0.1,
      y: 0.2,
      width: 0.3,
      height: 0.1,
    );
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [sentence(id: 'zoomed', sequence: 1, bbox: bbox)],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();
    final canvas = tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey('reader-canvas-1')),
    );
    final matrix = Matrix4.identity()
      ..translate(-300.0, -100.0)
      ..scale(2.0);
    canvas.transformationController!.value = matrix;
    await tester.pump();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.25, 0.25),
      transform: matrix,
    );

    expect(player.played.map((clip) => clip.path), ['zoomed.ogg']);
    final highlight = find.byKey(const ValueKey('reader-highlight-zoomed'));
    expect(highlight, findsOneWidget);
    final surfaceSize = tester.getSize(
      find.byKey(const ValueKey('reader-tap-surface-1')),
    );
    final imageRect = containedImageRect(
      canvasSize: surfaceSize,
      imageSize: const Size(1200, 1600),
    );
    expect(
      tester.getRect(highlight).width,
      closeTo(bbox.width * imageRect.width * 2, 0.01),
    );
  });

  testWidgets('点击 BoxFit.contain 留白不触发点读', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'first',
          sequence: 1,
          bbox: const NormalizedRect(
            x: 0,
            y: 0,
            width: 1,
            height: 1,
          ),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('reader-tap-surface-1'));

    await tester.tapAt(
      tester.getTopLeft(surface) +
          Offset(10, tester.getSize(surface).height / 2),
    );
    await tester.pump();

    expect(player.played, isEmpty);
    expect(find.byKey(const ValueKey('reader-highlight-first')), findsNothing);
  });

  testWidgets('翻页立即停止并清除当前高亮', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'first',
          sequence: 1,
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();
    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    expect(
        find.byKey(const ValueKey('reader-highlight-first')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('reader-highlight-first')), findsNothing);
    expect(player.stopCalls, greaterThanOrEqualTo(2));
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('alignment 加载失败提示一次且不阻断图片翻页', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    final alignment = Completer<PointReadingBook>();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: alignment.future,
    );
    await tester.pump();
    alignment.completeError(StateError('broken alignment path'));
    await tester.pumpAndSettle();

    expect(find.text('点读资源暂时不可用，请重新导入绘本'), findsOneWidget);
    expect(find.textContaining('broken alignment path'), findsNothing);
    expect(find.byKey(const ValueKey('reader-canvas-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('音频失败提示后可继续点击其他句', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'first',
          sequence: 1,
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
        sentence(
          id: 'second',
          sequence: 2,
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.5,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    final player = _WidgetAudioPlayer()
      ..nextFailure = const SentencePlaybackException();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    await tester.pumpAndSettle();

    expect(find.text('这一句暂时无法播放，请重新导入绘本'), findsOneWidget);
    expect(find.byKey(const ValueKey('reader-highlight-first')), findsNothing);

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.55),
    );
    expect(player.played.map((clip) => clip.path), ['first.ogg', 'second.ogg']);
    expect(
        find.byKey(const ValueKey('reader-highlight-second')), findsOneWidget);
  });

  testWidgets('点句直接显示跟读操作并按位置更新页面高亮', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'timed',
          sequence: 1,
          text: 'Good night.',
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
          clipEnd: const Duration(seconds: 3),
          wordTimings: const [
            ReaderWordTiming(
              id: 'w1',
              sequence: 1,
              word: 'Good',
              start: Duration.zero,
              end: Duration(seconds: 1),
            ),
            ReaderWordTiming(
              id: 'w2',
              sequence: 2,
              word: 'night.',
              start: Duration(seconds: 1),
              end: Duration(seconds: 3),
            ),
          ],
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );

    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(find.bySemanticsLabel('Good night.'), findsOneWidget);
    expect(find.text('听示范'), findsNothing);
    expect(find.text('开始录音'), findsNothing);
    expect(find.byTooltip('上一句'), findsOneWidget);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(find.byTooltip('下一句'), findsOneWidget);
    expect(find.text('重播本句'), findsNothing);
    expect(find.text('跟读这句'), findsNothing);
    expect(
        find.byKey(const ValueKey('reader-highlight-timed')), findsOneWidget);

    player.positionCallbacks.single!(const Duration(milliseconds: 1500));
    await tester.pump();

    expect(
        find.byKey(const ValueKey('reader-highlight-timed')), findsOneWidget);

    player.pending.single.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(find.text('听示范'), findsNothing);
    expect(find.text('开始录音'), findsNothing);
    expect(find.byTooltip('开始录音'), findsOneWidget);
  });

  testWidgets('进入绘本默认选中当前页第一句并保持工具栏高度稳定', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'default-first',
          sequence: 1,
          pageNumber: 1,
          text: 'The first sentence is ready.',
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
        sentence(
          id: 'default-second',
          sequence: 2,
          pageNumber: 2,
          text: 'The second page is ready.',
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    final followPanel = find.byKey(const ValueKey('follow-stable-panel'));
    expect(followPanel, findsOneWidget);
    final panelHeight = tester.getSize(followPanel).height;
    expect(find.text('The first sentence is ready.'), findsOneWidget);
    expect(find.byTooltip('上一句'), findsOneWidget);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(find.byTooltip('下一句'), findsOneWidget);
    expect(player.played, isEmpty);

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(find.text('The first sentence is ready.'), findsNothing);
    expect(find.text('The second page is ready.'), findsOneWidget);
    expect(tester.getSize(followPanel).height, panelHeight);
  });

  testWidgets('共享点读框只播放第一句，上一句下一句无需录音即可切换', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    const sharedBox = NormalizedRect(
      x: 0.1,
      y: 0.2,
      width: 0.5,
      height: 0.1,
    );
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'shared-second',
          sequence: 2,
          bbox: sharedBox,
          shared: true,
        ),
        sentence(
          id: 'shared-first',
          sequence: 1,
          bbox: sharedBox,
          shared: true,
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    expect(player.played.map((clip) => clip.path), ['shared-first.ogg']);
    expect(find.text('shared-first'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-next-sentence')));
    await tester.pump();
    expect(player.played.map((clip) => clip.path), [
      'shared-first.ogg',
      'shared-second.ogg',
    ]);
    expect(find.text('shared-second'), findsOneWidget);
    expect(find.text('开始录音'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reader-previous-sentence')));
    await tester.pump();
    expect(player.played.map((clip) => clip.path), [
      'shared-first.ogg',
      'shared-second.ogg',
      'shared-first.ogg',
    ]);

    player.pending.last.complete();
    await tester.pump();
  });

  testWidgets('上一句下一句跨页后自动切换页面并播放目标句', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'page-one-sentence',
          sequence: 1,
          pageNumber: 1,
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
        sentence(
          id: 'page-two-sentence',
          sequence: 2,
          pageNumber: 2,
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    await tester.tap(find.byKey(const ValueKey('reader-next-sentence')));
    await tester.pumpAndSettle();

    expect(find.text('2 / 2'), findsOneWidget);
    expect(player.played.map((clip) => clip.path), [
      'page-one-sentence.ogg',
      'page-two-sentence.ogg',
    ]);
    expect(
      find.byKey(const ValueKey('reader-highlight-page-two-sentence')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);

    player.pending.last.complete();
    await tester.pump();
  });

  testWidgets('第一句和最后一句的导航按钮按边界禁用', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'only-sentence',
          sequence: 1,
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
      ],
    );
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
    );
    await tester.pumpAndSettle();
    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );

    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('reader-previous-sentence')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('reader-next-sentence')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('无 timing 句显示完整原文且没有词高亮', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    const fullText = 'This sentence has no word timing.';
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'plain',
          sequence: 1,
          text: fullText,
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );

    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(find.text(fullText), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-subtitle-active-word-0')),
      findsNothing,
    );
  });

  testWidgets('翻页收起当前字幕但保留稳定工具栏', (tester) async {
    final book = await prepareBook(tester, pageCount: 2);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'page-one',
          sequence: 1,
          text: 'Page one sentence.',
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();
    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reader-thumbnail-2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(find.text('Page one sentence.'), findsNothing);
    player.positionCallbacks.single!(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
  });

  testWidgets('360 高度下长字幕可读且不显示延后控件', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final longText = List.filled(
      18,
      'A thoughtfully illustrated sentence wraps safely',
    ).join(' ');
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'long',
          sequence: 1,
          text: longText,
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      size: const Size(360, 800),
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );

    expect(find.byKey(const ValueKey('follow-stable-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('全文播放'), findsNothing);
    expect(find.text('重播本句'), findsNothing);
    expect(find.text('跟读这句'), findsNothing);
    expect(find.text('听示范'), findsNothing);
    expect(find.text('开始录音'), findsNothing);
    expect(find.byTooltip('上一句'), findsOneWidget);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(find.byTooltip('下一句'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('点读面板直接进入跟读且面板稳定', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'stable-panel',
          sequence: 1,
          text: 'A stable reading panel.',
          bbox: const NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1,
          ),
        ),
      ],
    );
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );

    final followPanel = find.byKey(const ValueKey('follow-stable-panel'));
    expect(followPanel, findsOneWidget);
    final panelHeight = tester.getSize(followPanel).height;
    expect(
      panelHeight,
      inInclusiveRange(
        AppSizes.readerControlPanelMinHeight,
        AppSizes.readerControlPanelMaxHeight,
      ),
    );

    expect(find.text('点读'), findsNothing);
    expect(find.text('跟读'), findsNothing);
    expect(find.text('听示范'), findsNothing);
    expect(find.text('开始录音'), findsNothing);
    expect(find.byTooltip('开始录音'), findsOneWidget);
    expect(tester.getSize(followPanel).height, panelHeight);
    expect(
      find.descendant(of: followPanel, matching: find.byType(RepaintBoundary)),
      findsWidgets,
    );
    expect(
      find.descendant(of: followPanel, matching: find.byType(AnimatedSize)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('空闲工具栏一键重播当前句示范音', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'replay-me',
          sequence: 1,
          text: 'Play it again.',
          clipEnd: const Duration(seconds: 2),
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    player.pending.single.complete();
    await tester.pumpAndSettle();
    expect(player.played, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('follow-replay-demonstration')));
    await tester.pump();

    expect(player.played, hasLength(2));
    expect(player.played.last.path, 'replay-me.ogg');
    expect(player.played.last.start, Duration.zero);
    expect(player.played.last.end, const Duration(seconds: 2));
    // 播放示范期间重播与录音按钮同时禁用，避免重复触发。
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('follow-replay-demonstration')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('follow-start-recording')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('录音态停止按钮完整固定在面板内不被裁切', (tester) async {
    final book = await prepareBook(tester, pageCount: 1);
    // 注入停止失败,让收尾走失败分支:定时器已取消且不触发任何真实文件
    // IO(评分链路的 readAsBytes 在 fake async 测试里永远无法完成)。
    final recorder = _WidgetRecorder(
      p.join(tempDir.path, 'follow-take.wav'),
      stopError: const RecordingException('录音没有保存成功，请再试一次'),
    );
    final pointBook = PointReadingBook(
      libraryId: book.libraryId,
      sentences: [
        sentence(
          id: 'record-me',
          sequence: 1,
          text: 'A long sentence that wraps to multiple lines in the panel.',
          bbox: const NormalizedRect(x: .1, y: .2, width: .4, height: .1),
        ),
      ],
    );
    final player = _WidgetAudioPlayer();
    await pumpReader(
      tester,
      book: Future.value(book),
      pointReadingBook: Future.value(pointBook),
      audioPlayer: player,
      overrides: [
        recordingServiceProvider.overrideWith((_) async => recorder),
        scoringProvider.overrideWithValue(_WidgetScorer()),
        recordingPreparationProtocolProvider
            .overrideWithValue(_ImmediatePreparation()),
        followQuickPreparationProtocolProvider
            .overrideWithValue(_ImmediatePreparation()),
      ],
    );
    await tester.pumpAndSettle();

    await tapNormalized(
      tester,
      pageNumber: 1,
      normalized: const Offset(0.2, 0.25),
    );
    player.pending.single.complete();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('follow-start-recording')));
    // 单帧推进让录音阶段渲染完成，但不推进到 7 秒自动收尾。
    await tester.pump(const Duration(milliseconds: 100));

    final panelRect = tester.getRect(
      find.byKey(const ValueKey('follow-stable-panel')),
    );
    final stopRect = tester.getRect(
      find.byKey(const ValueKey('follow-stop-recording')),
    );
    expect(stopRect.width, 64);
    expect(stopRect.top, greaterThanOrEqualTo(panelRect.top));
    expect(stopRect.bottom, lessThanOrEqualTo(panelRect.bottom));

    // 推进超过自动收尾上限,让 7 秒定时器真实触发:录音 UI 收起、
    // 面板进入评分态。注入的停止失败让链路停在评分分支,不触发真实文件 IO。
    await tester.pump(const Duration(seconds: 8));

    expect(
      find.byKey(const ValueKey('follow-stop-recording')),
      findsNothing,
    );
    expect(find.text('录音已收到，正在评分…'), findsOneWidget);
  });
}
