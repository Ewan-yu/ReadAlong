import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'shelf_index.dart';

final appDocumentsDirectoryProvider = FutureProvider<Directory>(
  (_) => getApplicationDocumentsDirectory(),
);

final appDatabaseFactoryProvider = Provider<sqflite.DatabaseFactory>(
  (_) => sqflite.databaseFactory,
);

final shelfIndexProvider = FutureProvider<ShelfIndex>((ref) async {
  final documents = await ref.watch(appDocumentsDirectoryProvider.future);
  final databaseFactory = ref.watch(appDatabaseFactoryProvider);
  return ShelfIndex(
    databasePath: p.join(documents.path, 'app.db'),
    databaseFactory: databaseFactory,
  );
});
