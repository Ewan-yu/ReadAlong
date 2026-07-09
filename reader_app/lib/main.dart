import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router.dart';
import 'core/theme/tokens.dart';

void main() {
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
