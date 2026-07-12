import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/data/bookpack/book_pack_importer.dart';
import 'package:reader_app/features/shelf/shelf_controller.dart';
import 'package:reader_app/features/shelf/shelf_page.dart';

ShelfBook _book(
  String id, {
  String? title,
  int pageCount = 12,
  String thumbnailPath = 'missing-cover.jpg',
}) =>
    ShelfBook(
      libraryId: id,
      sourceBookId: 'source-$id',
      title: title ?? '绘本 $id',
      pageCount: pageCount,
      bookDir: '/missing/$id',
      thumbnailPath: thumbnailPath,
      packageSha256: 'hash-$id',
      importedAt: DateTime.utc(2026, 7, 11),
    );

class _ScriptedShelfController extends ShelfController {
  _ScriptedShelfController(this.initialState);

  final ShelfState initialState;
  ShelfActionResult pickResult = const ShelfActionResult(
    kind: ShelfActionKind.cancelled,
  );
  ShelfActionResult deleteResult = const ShelfActionResult(
    kind: ShelfActionKind.deleted,
  );
  ShelfActionResult conflictResult = const ShelfActionResult(
    kind: ShelfActionKind.imported,
  );
  Completer<ShelfActionResult>? pickCompleter;
  Completer<ShelfActionResult>? deleteCompleter;
  final conflictResolutions = <ImportConflictResolution>[];
  final deleteRecordings = <bool>[];
  var pickCalls = 0;

  @override
  Future<ShelfState> build() async => initialState;

  @override
  Future<ShelfActionResult> pickAndImport() {
    pickCalls++;
    return pickCompleter?.future ?? Future.value(pickResult);
  }

  @override
  Future<ShelfActionResult> resolveConflict(
    PendingImport pending,
    ImportConflictResolution resolution,
  ) async {
    conflictResolutions.add(resolution);
    return conflictResult;
  }

  @override
  Future<ShelfActionResult> deleteBook(
    ShelfBook book, {
    required bool deleteRecordings,
  }) {
    this.deleteRecordings.add(deleteRecordings);
    return deleteCompleter?.future ?? Future.value(deleteResult);
  }
}

Future<_ScriptedShelfController> _pumpShelf(
  WidgetTester tester, {
  List<ShelfBook> books = const [],
  bool isMutating = false,
  Size size = const Size(800, 800),
  ValueChanged<ShelfBook>? onOpenBook,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final controller = _ScriptedShelfController(
    ShelfState(books: books, isMutating: isMutating),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        shelfControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: ShelfPage(onOpenBook: onOpenBook),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  return controller;
}

Future<void> _tapImport(WidgetTester tester) async {
  tester
      .widget<FloatingActionButton>(find.byType(FloatingActionButton))
      .onPressed!();
  await tester.pump();
}

int _visibleFirstRowCount(WidgetTester tester) {
  final titles = find.byWidgetPredicate(
    (widget) =>
        widget is Text && widget.data?.startsWith('这是一本名字很长但不能溢出的绘本') == true,
  );
  final positions = titles.evaluate().map((element) {
    return tester
        .getTopLeft(find.byElementPredicate((item) => item == element));
  }).toList();
  final firstRowY = positions.map((position) => position.dy).reduce(
        (first, next) => first < next ? first : next,
      );
  return positions
      .where((position) => (position.dy - firstRowY).abs() < 1)
      .length;
}

void _expectMinTouchTarget(WidgetTester tester, Finder finder) {
  final size = tester.getSize(finder);
  expect(size.width, greaterThanOrEqualTo(AppSizes.minTouchTarget));
  expect(size.height, greaterThanOrEqualTo(AppSizes.minTouchTarget));
}

Future<void> _openDeleteDialog(
  WidgetTester tester,
  ShelfBook book,
) async {
  await tester.longPress(find.text(book.title));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空态显示引导并允许导入', (tester) async {
    await _pumpShelf(tester);

    expect(find.text('书架还是空的'), findsOneWidget);
    expect(
      find.text('让爸爸妈妈用电脑制作绘本资源包，然后导入这里吧'),
      findsOneWidget,
    );
    expect(find.text('导入绘本'), findsOneWidget);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNotNull,
    );
    _expectMinTouchTarget(tester, find.byType(FloatingActionButton));
  });

  testWidgets('书架标题省略且封面边界稳定保持 3:4', (tester) async {
    final book = _book('one', title: '月亮晚安', pageCount: 18);
    await _pumpShelf(tester, books: [book]);

    expect(find.text('月亮晚安'), findsOneWidget);
    expect(find.text('18 页'), findsOneWidget);
    expect(find.byIcon(Icons.auto_stories), findsOneWidget);
    final coverFinder = find.byType(AspectRatio).first;
    final cover = tester.widget<AspectRatio>(coverFinder);
    final coverSize = tester.getSize(coverFinder);
    final title = tester.widget<Text>(find.text(book.title));
    expect(cover.aspectRatio, 3 / 4);
    expect(coverSize.width / coverSize.height, closeTo(3 / 4, 0.001));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
  });

  testWidgets('窄屏和宽屏自适应列数且不溢出', (tester) async {
    final books = List.generate(
      12,
      (index) => _book(
        '$index',
        title: '这是一本名字很长但不能溢出的绘本 $index',
      ),
    );

    await _pumpShelf(
      tester,
      books: books,
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    final narrowFirstRow = _visibleFirstRowCount(tester);

    await _pumpShelf(
      tester,
      books: books,
      size: const Size(1280, 800),
    );
    expect(tester.takeException(), isNull);
    final wideFirstRow = _visibleFirstRowCount(tester);

    expect(narrowFirstRow, 2);
    expect(wideFirstRow, 5);
  });

  testWidgets('校验错误对话框可滚动到最末错误', (tester) async {
    final controller = await _pumpShelf(tester);
    final errors = List.generate(30, (index) => '校验错误 ${index + 1}');
    controller.pickResult = ShelfActionResult(
      kind: ShelfActionKind.validationFailed,
      errors: errors,
    );

    await _tapImport(tester);
    await tester.pumpAndSettle();

    expect(find.text('绘本无法导入'), findsOneWidget);
    expect(find.text('校验错误 1'), findsOneWidget);
    expect(find.text('校验错误 30'), findsNothing);
    expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        ),
        findsWidgets);
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(TextButton, '知道了'),
    );

    await tester.scrollUntilVisible(
      find.text('校验错误 30'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('校验错误 30'), findsOneWidget);
  });

  testWidgets('冲突对话框可覆盖、存为副本或保留绘本', (tester) async {
    final existing = _book('existing');
    final pending = PendingImport(
      bytes: Uint8List.fromList([1, 2, 3]),
      conflict: ImportResult.conflict(conflictEntry: existing),
    );
    final controller = await _pumpShelf(tester, books: [existing]);
    controller.pickResult = ShelfActionResult(
      kind: ShelfActionKind.conflict,
      pendingImport: pending,
    );

    await _tapImport(tester);
    await tester.pumpAndSettle();
    expect(find.text('覆盖绘本'), findsOneWidget);
    expect(find.text('存为副本'), findsOneWidget);
    expect(find.text('保留绘本'), findsOneWidget);
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(FilledButton, '覆盖绘本'),
    );
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(OutlinedButton, '存为副本'),
    );
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(TextButton, '保留绘本'),
    );

    await tester.tap(find.text('覆盖绘本'));
    await tester.pumpAndSettle();
    expect(
        controller.conflictResolutions, [ImportConflictResolution.overwrite]);

    await _tapImport(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('存为副本'));
    await tester.pumpAndSettle();
    expect(
      controller.conflictResolutions,
      [ImportConflictResolution.overwrite, ImportConflictResolution.saveCopy],
    );

    await _tapImport(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留绘本'));
    await tester.pumpAndSettle();
    expect(controller.conflictResolutions, hasLength(2));
  });

  testWidgets('删除录音复选框默认关闭并转发选择', (tester) async {
    final book = _book('delete');
    final controller = await _pumpShelf(tester, books: [book]);

    await _openDeleteDialog(tester, book);
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox)).value,
      isFalse,
    );
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(TextButton, '保留绘本'),
    );
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(TextButton, '删除绘本'),
    );
    await tester.tap(find.text('同时删除我的录音'));
    await tester.pump();
    await tester.tap(find.text('删除绘本'));
    await tester.pumpAndSettle();

    expect(controller.deleteRecordings, [isTrue]);
  });

  testWidgets('忙碌时保留绘本并禁用所有书架操作', (tester) async {
    final book = _book('busy');
    final controller = await _pumpShelf(
      tester,
      books: [book],
      isMutating: true,
    );

    expect(find.text(book.title), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
    await tester.longPress(find.text(book.title));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('删除绘本'), findsNothing);
    expect(controller.pickCalls, 0);
  });

  testWidgets('busy 结果不显示反馈并允许稍后重试', (tester) async {
    final controller = await _pumpShelf(tester);
    controller.pickResult = const ShelfActionResult(kind: ShelfActionKind.busy);

    await _tapImport(tester);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(controller.pickCalls, 1);
  });

  testWidgets('imported 结果显示绘本名称', (tester) async {
    final imported = _book('imported', title: '小熊看月亮');
    final controller = await _pumpShelf(tester);
    controller.pickResult = ShelfActionResult(
      kind: ShelfActionKind.imported,
      book: imported,
    );

    await _tapImport(tester);
    await tester.pump();

    expect(find.text('已导入《小熊看月亮》'), findsOneWidget);
  });

  testWidgets('alreadyImported 结果提示绘本已在书架', (tester) async {
    final existing = _book('existing', title: '云朵面包');
    final controller = await _pumpShelf(tester, books: [existing]);
    controller.pickResult = ShelfActionResult(
      kind: ShelfActionKind.alreadyImported,
      book: existing,
    );

    await _tapImport(tester);
    await tester.pump();

    expect(find.text('《云朵面包》已经在书架里'), findsOneWidget);
  });

  testWidgets('failed 结果显示可理解的失败对话框', (tester) async {
    final controller = await _pumpShelf(tester);
    controller.pickResult = const ShelfActionResult(
      kind: ShelfActionKind.failed,
      errors: ['internal detail'],
    );

    await _tapImport(tester);
    await tester.pumpAndSettle();

    expect(find.text('操作没有完成'), findsOneWidget);
    expect(find.text('请稍后再试。若问题持续，请重启应用后重试。'), findsOneWidget);
    expect(find.textContaining('重新导出'), findsNothing);
    _expectMinTouchTarget(
      tester,
      find.widgetWithText(TextButton, '知道了'),
    );
  });

  testWidgets('partialDelete 结果提示部分本地文件未清理', (tester) async {
    final book = _book('partial', title: '星星绘本');
    final controller = await _pumpShelf(tester, books: [book]);
    controller.deleteResult = ShelfActionResult(
      kind: ShelfActionKind.partialDelete,
      book: book,
    );

    await _openDeleteDialog(tester, book);
    await tester.tap(find.text('删除绘本'));
    await tester.pump();

    expect(find.text('绘本已删除，但部分本地文件未能清理'), findsOneWidget);
  });

  testWidgets('deleted 结果显示删除完成反馈', (tester) async {
    final book = _book('deleted', title: '要删除的绘本');
    final controller = await _pumpShelf(tester, books: [book]);
    controller.deleteResult = ShelfActionResult(
      kind: ShelfActionKind.deleted,
      book: book,
    );

    await _openDeleteDialog(tester, book);
    await tester.tap(find.text('删除绘本'));
    await tester.pump();

    expect(find.text('已删除《要删除的绘本》'), findsOneWidget);
  });

  testWidgets('绘本点击打开精确 libraryId 并保留长按删除', (tester) async {
    final book = _book('story-copy-2', title: '打开这本绘本');
    final opened = <ShelfBook>[];
    await _pumpShelf(
      tester,
      books: [book],
      onOpenBook: opened.add,
    );
    final semantics = find.ancestor(
      of: find.text(book.title),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label?.startsWith(book.title) == true,
      ),
    );

    expect(tester.widget<Semantics>(semantics).properties.button, isTrue);
    await tester.tap(find.text(book.title));
    await tester.pumpAndSettle();
    expect(opened, [book]);

    await tester.longPress(find.text(book.title));
    await tester.pumpAndSettle();
    expect(find.text('删除绘本'), findsOneWidget);
  });

  testWidgets('导入等待期间页面销毁后不显示反馈', (tester) async {
    final controller = await _pumpShelf(tester);
    controller.pickCompleter = Completer<ShelfActionResult>();

    await _tapImport(tester);
    await tester.pumpWidget(const SizedBox());
    controller.pickCompleter!.complete(
      ShelfActionResult(kind: ShelfActionKind.imported, book: _book('later')),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('删除等待期间页面销毁后不显示反馈', (tester) async {
    final book = _book('later-delete');
    final controller = await _pumpShelf(tester, books: [book]);
    controller.deleteCompleter = Completer<ShelfActionResult>();

    await _openDeleteDialog(tester, book);
    await tester.tap(find.text('删除绘本'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    controller.deleteCompleter!.complete(
      ShelfActionResult(kind: ShelfActionKind.deleted, book: book),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsNothing);
  });
}
