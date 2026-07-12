import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/core/router.dart';
import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/features/reader/reader_models.dart';
import 'package:reader_app/features/reader/reader_repository.dart';

void main() {
  testWidgets('reader route loads the requested library instance',
      (tester) async {
    final book = ReaderBook(
      libraryId: 'story-copy-2',
      sourceBookId: 'story-source',
      title: 'Routed Story',
      pages: const [
        ReaderPageData(
          pageNumber: 1,
          imagePath: 'missing-page.webp',
          thumbnailPath: 'missing-thumbnail.jpg',
          widthPx: 1200,
          heightPx: 1600,
        ),
      ],
    );
    final router = createAppRouter(
      initialLocation: '/reader/story-copy-2',
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          readerBookProvider('story-copy-2').overrideWith(
            (_) async => book,
          ),
        ],
        child: MaterialApp.router(
          theme: buildAppTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Routed Story'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('这一页的图片缺失'), findsOneWidget);
  });
}
