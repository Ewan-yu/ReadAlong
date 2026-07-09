import 'package:go_router/go_router.dart';

import '../features/shelf/shelf_page.dart';

/// 路由表：书架 → 阅读器 → 跟读（M1/M4 里程碑逐步补充）
final appRouter = GoRouter(
  initialLocation: '/shelf',
  routes: [
    GoRoute(
      path: '/shelf',
      builder: (context, state) => const ShelfPage(),
    ),
    // M1: GoRoute(path: '/reader/:bookId', ...)
    // M4: GoRoute(path: '/follow/:bookId/:sentenceId', ...)
  ],
);
