import 'package:go_router/go_router.dart';

import '../features/reader/reader_page.dart';
import '../features/reader/original_audio_page.dart';
import '../features/dubbing/sentence_dubbing_page.dart';
import '../features/dubbing/full_dubbing_page.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/recording_management_page.dart';
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
        GoRoute(
          path: '/reader/:libraryId/original',
          builder: (context, state) => OriginalAudioPage(
            libraryId: state.pathParameters['libraryId']!,
          ),
        ),
        GoRoute(
          path: '/reader/:libraryId/dub',
          builder: (context, state) => SentenceDubbingPage(
            libraryId: state.pathParameters['libraryId']!,
          ),
        ),
        GoRoute(
          path: '/reader/:libraryId/dub/full',
          builder: (context, state) => FullDubbingPage(
            libraryId: state.pathParameters['libraryId']!,
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/settings/recordings',
          builder: (context, state) => const RecordingManagementPage(),
        ),
        // M4: GoRoute(path: '/follow/:bookId/:sentenceId', ...)
      ],
    );

final appRouter = createAppRouter();
