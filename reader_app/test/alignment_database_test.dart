import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/features/reader/alignment_database.dart';

/// Delegates to the real factory except one path whose open never returns,
/// mirroring the field-observed sqflite stall on an imported package.
class _HangingOnPathFactory implements DatabaseFactory {
  _HangingOnPathFactory(this._inner, this.hangingPath);

  final DatabaseFactory _inner;
  final String hangingPath;
  var hangCount = 0;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    if (path == hangingPath) {
      hangCount += 1;
      return Completer<Database>().future;
    }
    return _inner.openDatabase(path, options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

Future<String> _writeSourceDatabase(Directory tempDir) async {
  final sourcePath = p.join(tempDir.path, 'align', 'alignment.db');
  await File(sourcePath).parent.create(recursive: true);
  final setup = await databaseFactoryFfi.openDatabase(sourcePath);
  await setup.execute('CREATE TABLE sentence (id TEXT, text TEXT)');
  await setup.insert('sentence', {'id': 's0001', 'text': 'Hello world.'});
  await setup.close();
  return sourcePath;
}

void main() {
  sqfliteFfiInit();

  test('直接打开挂起时回退到临时副本，数据可完整查询且关闭即清理', () async {
    final tempDir = await Directory.systemTemp.createTemp('alignment_db_test_');
    final sourcePath = await _writeSourceDatabase(tempDir);

    final factory = _HangingOnPathFactory(databaseFactoryFfi, sourcePath);
    final handle = await openAlignmentDatabase(
      databaseFactory: factory,
      databasePath: sourcePath,
      directOpenTimeout: const Duration(milliseconds: 100),
    );

    expect(handle.tempCopyPath, isNotNull);
    final rows = await handle.query('sentence', columns: const ['id', 'text']);
    expect(rows.single['id'], 's0001');
    expect(rows.single['text'], 'Hello world.');
    expect(factory.hangCount, 1);

    final copyPath = handle.tempCopyPath!;
    expect(File(copyPath).existsSync(), isTrue);
    await handle.close();
    expect(File(copyPath).existsSync(), isFalse);
    // The package original stays untouched.
    expect(File(sourcePath).existsSync(), isTrue);
    await tempDir.delete(recursive: true);
  });

  test('同一进程内毒性路径直接走副本，不再等待直开超时', () async {
    final tempDir = await Directory.systemTemp.createTemp('alignment_db_test_');
    final sourcePath = await _writeSourceDatabase(tempDir);

    final factory = _HangingOnPathFactory(databaseFactoryFfi, sourcePath);
    const timeout = Duration(milliseconds: 100);
    final first = await openAlignmentDatabase(
      databaseFactory: factory,
      databasePath: sourcePath,
      directOpenTimeout: timeout,
    );
    await first.close();
    expect(factory.hangCount, 1);

    final second = await openAlignmentDatabase(
      databaseFactory: factory,
      databasePath: sourcePath,
      directOpenTimeout: timeout,
    );
    // No second direct-open attempt: the remembered path goes straight to copy.
    expect(factory.hangCount, 1);
    final rows = await second.query('sentence');
    expect(rows, hasLength(1));
    await second.close();
    await tempDir.delete(recursive: true);
  });

  test('直接打开成功时不产生副本', () async {
    final tempDir = await Directory.systemTemp.createTemp('alignment_db_test_');
    final sourcePath = await _writeSourceDatabase(tempDir);

    final factory = _HangingOnPathFactory(
      databaseFactoryFfi,
      p.join(tempDir.path, 'never.db'),
    );
    final handle = await openAlignmentDatabase(
      databaseFactory: factory,
      databasePath: sourcePath,
      directOpenTimeout: const Duration(seconds: 2),
    );

    final rows = await handle.query('sentence');
    expect(rows, hasLength(1));
    expect(handle.tempCopyPath, isNull);
    expect(factory.hangCount, 0);
    await handle.close();
    await tempDir.delete(recursive: true);
  });
}
