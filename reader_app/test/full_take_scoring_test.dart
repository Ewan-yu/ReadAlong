import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/features/dubbing/full_take_scoring.dart';

void main() {
  test('按完整录音绝对毫秒范围在内存切 PCM，不创建临时文件', () {
    final pcm = Uint8List.fromList(List<int>.generate(320, (index) => index));
    final slice = pcm16SliceForRange(
      pcm,
      const Duration(milliseconds: 2),
      const Duration(milliseconds: 6),
    );
    expect(slice, hasLength(128));
    expect(slice.first, 64);
    expect(slice.last, 191);
  });

  test('越界或空区间不会伪造可评分 PCM', () {
    final pcm = Uint8List(64);
    expect(pcm16SliceForRange(pcm, Duration.zero, Duration.zero), isEmpty);
    expect(
      pcm16SliceForRange(
        pcm,
        const Duration(seconds: 10),
        const Duration(seconds: 11),
      ),
      isEmpty,
    );
  });
}
