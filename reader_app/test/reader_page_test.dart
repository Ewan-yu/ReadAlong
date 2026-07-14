import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

final class _WidgetAudioPlayer implements SentenceAudioPlayer {
  final played = <SentenceAudioClip>[];
  final pending = <Completer<void>>[];
  var stopCalls = 0;
  var disposeCalls = 0;
  Object? nextFailure;

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) {
    played.add(clip);
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
  }) =>
      ReaderSentence(
        id: id,
        pageNumber: pageNumber,
        sequence: sequence,
        text: id,
        bbox: bbox,
        sharedBbox: false,
        audio: SentenceAudioClip(
          path: '$id.ogg',
          start: Duration.zero,
          end: const Duration(seconds: 1),
        ),
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

  testWidgets('首次打开只缓存当前页和下一页原图', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(tester, book: Future.value(book));
    await tester.pumpAndSettle();

    bool isCached(int page) {
      final status = PaintingBinding.instance.imageCache.statusForKey(
        FileImage(File(book.pages[page - 1].imagePath)),
      );
      return status.pending || status.live || status.keepAlive;
    }

    expect(isCached(1), isTrue);
    expect(isCached(2), isTrue);
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
      sentences: [sentence(id: 'first', sequence: 1, bbox: bbox)],
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
}
