import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reader_app/services/recording/recording_service.dart';

Uint8List _wav({
  int sampleRate = 16000,
  int channels = 1,
  int bits = 16,
  List<int> pcm = const [0, 0, 1, 0],
}) {
  final bytes = Uint8List(44 + pcm.length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * channels * bits ~/ 8, Endian.little);
  view.setUint16(32, channels * bits ~/ 8, Endian.little);
  view.setUint16(34, bits, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

void main() {
  test('WAV 解析提取 16kHz 单声道 PCM', () {
    final result = parseWavPcm16(_wav());
    expect(result.sampleRate, 16000);
    expect(result.channels, 1);
    expect(result.bitsPerSample, 16);
    expect(result.pcm16k, [0, 0, 1, 0]);
  });

  test('非 16kHz 单声道 PCM 被拒绝', () {
    expect(
      () => parseWavPcm16(_wav(sampleRate: 44100)),
      throwsA(isA<RecordingException>()),
    );
    expect(
      () => parseWavPcm16(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<RecordingException>()),
    );
  });

  test('评分只读取内容零点之后的 PCM', () {
    final pcm = Uint8List.fromList(List<int>.generate(96, (index) => index));

    final sliced = pcm16SliceFromOffset(pcm, const Duration(milliseconds: 2));

    expect(sliced, pcm.sublist(64));
    expect(
      pcm16SliceFromOffset(pcm, const Duration(seconds: 1)),
      isEmpty,
    );
  });

  test('启动清理只删除临时跟读目录和旧版 records 目录', () async {
    final root = await Directory.systemTemp.createTemp('follow_cleanup_test_');
    addTearDown(() => root.delete(recursive: true));
    final temporary = Directory(p.join(root.path, 'cache'));
    final documents = Directory(p.join(root.path, 'documents'));
    final transient = File(p.join(
      temporary.path,
      'readalong-follow-recordings',
      'book',
      'take.wav',
    ));
    final legacy = File(p.join(documents.path, 'records', 'book', 'old.wav'));
    final importedBook =
        File(p.join(documents.path, 'books', 'book', 'page.webp'));
    await transient.create(recursive: true);
    await legacy.create(recursive: true);
    await importedBook.create(recursive: true);

    await purgeStaleFollowRecordings(temporary);
    await purgeLegacyFollowRecordings(documents);

    expect(await transient.exists(), isFalse);
    expect(await legacy.exists(), isFalse);
    expect(await importedBook.exists(), isTrue);
  });
}
