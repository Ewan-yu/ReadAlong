import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/tokens.dart';
import 'dev/streaming_spike.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Full-resolution picture-book pages can easily occupy tens of megabytes
  // each after RGBA decoding. Keep enough room for the visible page and one
  // prefetched neighbour without pressuring emulator graphics bridges.
  PaintingBinding.instance.imageCache
    ..maximumSize = 24
    ..maximumSizeBytes = 64 << 20;
  maybeRunStreamingSpike();
  runApp(const ProviderScope(child: ReadAlongApp()));
}

class ReadAlongApp extends StatelessWidget {
  const ReadAlongApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'ReadAlong 跟读宝',
      theme: buildAppTheme(),
      routerConfig: appRouter,
      debugShowCheckedModeBanner: false,
    );
  }
}
