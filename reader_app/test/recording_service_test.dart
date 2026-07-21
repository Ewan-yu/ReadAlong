import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
