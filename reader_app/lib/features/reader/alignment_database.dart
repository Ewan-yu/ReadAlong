import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const Duration _directOpenTimeout = Duration(seconds: 4);

/// Paths whose direct sqflite open never answered in this process.
///
/// The observed device stall is sticky per path: once an open hangs, every
/// later open of the same file hangs too. Remembering it skips the wait.
final Set<String> _poisonedPaths = {};

bool _sweptTempCopies = false;

/// An open handle to an immutable package alignment database.
///
/// Closing the handle also deletes the temp copy it may be served from, so the
/// fallback strategy never leaks files.
final class AlignmentDatabase {
  AlignmentDatabase(this.database, {this.tempCopyPath});

  final Database database;
  final String? tempCopyPath;

  Future<List<Map<String, Object?>>> query(
    String table, {
    List<String>? columns,
    String? orderBy,
    int? limit,
  }) =>
      database.query(table, columns: columns, orderBy: orderBy, limit: limit);

  Future<void> close() async {
    await database.close();
    final path = tempCopyPath;
    if (path == null) return;
    try {
      await File(path).delete();
    } on Object {
      // A best-effort cleanup; an undeletable temp file is only disk noise.
    }
  }
}

void _sweepStaleTempCopies() {
  if (_sweptTempCopies) return;
  _sweptTempCopies = true;
  final directory = Directory.systemTemp;
  if (!directory.existsSync()) return;
  for (final entity in directory.listSync()) {
    final name = p.basename(entity.path);
    if (entity is File &&
        name.startsWith('ra_alignment_') &&
        name.endsWith('.db')) {
      try {
        entity.deleteSync();
      } on Object {
        // Currently open handles (or platform locks) are skipped; a still-used
        // copy is deleted by its own close().
      }
    }
  }
}

/// Opens the immutable `align/alignment.db` of an imported package.
///
/// On some devices the sqflite open of this exact file can stick forever
/// (observed in the field: the first open after entering a freshly imported
/// book never returns, every later open of the same path in that process
/// times out too, while other databases keep working; killing the app
/// recovers it). The database content is immutable and hash-verified at
/// import time, so when the direct open does not answer in time we copy the
/// file to a fresh temp path and serve queries from the copy. The copy
/// intentionally omits any journal sidecar, which also sidesteps lock or
/// recovery states of the original file. Closing the returned handle deletes
/// the copy again.
Future<AlignmentDatabase> openAlignmentDatabase({
  required DatabaseFactory databaseFactory,
  required String databasePath,
  Duration directOpenTimeout = _directOpenTimeout,
}) async {
  _sweepStaleTempCopies();
  if (!_poisonedPaths.contains(databasePath)) {
    try {
      final database = await databaseFactory
          .openDatabase(
            databasePath,
            options: OpenDatabaseOptions(
              readOnly: true,
              singleInstance: false,
            ),
          )
          .timeout(directOpenTimeout);
      return AlignmentDatabase(database);
    } on Object catch (error) {
      _poisonedPaths.add(databasePath);
      debugPrint(
        'readalong.alignment direct open failed ($error); '
        'serving from a temp copy for the rest of this session',
      );
    }
  }
  final tempPath = p.join(
    Directory.systemTemp.path,
    'ra_alignment_${DateTime.now().microsecondsSinceEpoch}.db',
  );
  await File(databasePath).copy(tempPath);
  final database = await databaseFactory.openDatabase(
    tempPath,
    options: OpenDatabaseOptions(
      readOnly: true,
      singleInstance: false,
    ),
  );
  return AlignmentDatabase(database, tempCopyPath: tempPath);
}
