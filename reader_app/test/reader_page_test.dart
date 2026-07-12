import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/features/reader/reader_models.dart';
import 'package:reader_app/features/reader/reader_page.dart';
import 'package:reader_app/features/reader/reader_repository.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

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
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerBookProvider('story-copy-2').overrideWith((_) => book),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const ReaderPage(libraryId: 'story-copy-2'),
        ),
      ),
    );
  }

  testWidgets('加载时显示进度，完成后显示书名和页码', (tester) async {
    final readyBook = await prepareBook(tester);
    final completer = Completer<ReaderBook>();
    await pumpReader(tester, book: completer.future);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

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

  testWidgets('窄屏使用底部横向缩略条且没有布局溢出', (tester) async {
    final book = await prepareBook(tester);
    await pumpReader(
      tester,
      book: Future.value(book),
      size: const Size(360, 800),
    );
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
}
