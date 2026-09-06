import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

/// Opens the immutable `align/alignment.db` of an imported package.
///
/// On some devices the sqflite open of this exact file can stick forever
/// (observed in the field: the first open after entering a freshly imported
/// book never returns, every later open of the same path in that process
/// times out too, while other databases keep working; killing the app
/// recovers it). The database content is immutable and hash-verified at
/// import time, so when the direct open does not answer in time we copy the
/// file to a fresh temp path and serve queries from the copy instead. The
/// copy intentionally omits any journal sidecar, which also sidesteps
/// lock/recovery states of the original file.
Future<sqflite.Database> openAlignmentDatabase({
  required sqflite.DatabaseFactory databaseFactory,
  required String databasePath,
  Duration directOpenTimeout = const Duration(seconds: 4),
}) async {
  try {
    return await databaseFactory
        .openDatabase(
          databasePath,
          options: sqflite.OpenDatabaseOptions(
            readOnly: true,
            singleInstance: false,
          ),
        )
        .timeout(directOpenTimeout);
  } on Object catch (error) {
    debugPrint(
      'readalong.alignment direct open failed ($error); serving from a '
      'temp copy',
    );
    final tempPath = p.join(
      Directory.systemTemp.path,
      'ra_alignment_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    await File(databasePath).copy(tempPath);
    return databaseFactory.openDatabase(
      tempPath,
      options: sqflite.OpenDatabaseOptions(
        readOnly: true,
        singleInstance: false,
      ),
    );
  }
}
