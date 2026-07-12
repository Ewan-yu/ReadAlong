import 'package:go_router/go_router.dart';

import '../features/reader/reader_page.dart';
import '../features/shelf/shelf_page.dart';

/// 路由表：书架 → 阅读器 → 跟读（M1/M4 里程碑逐步补充）
GoRouter createAppRouter({String initialLocation = '/shelf'}) => GoRouter(
      initialLocation: initialLocation,
      routes: [
        GoRoute(
          path: '/shelf',
          builder: (context, state) => const ShelfPage(),
        ),
        GoRoute(
          path: '/reader/:libraryId',
          builder: (context, state) => ReaderPage(
            libraryId: state.pathParameters['libraryId']!,
          ),
        ),
        // M4: GoRoute(path: '/follow/:bookId/:sentenceId', ...)
      ],
    );

final appRouter = createAppRouter();
