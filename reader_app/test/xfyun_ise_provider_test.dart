import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart';

void main() {
  test('鉴权 URL 使用固定 RFC1123 日期且不暴露 secret', () {
    final uri = buildXfyunAuthUri(
      apiKey: 'test-key',
      apiSecret: 'private-secret',
      now: DateTime.utc(2026, 7, 20, 12, 34, 56),
    );

    expect(uri.scheme, 'wss');
    expect(uri.host, 'ise-api.xfyun.cn');
    expect(uri.path, '/v2/open-ise');
    expect(uri.queryParameters['date'], 'Mon, 20 Jul 2026 12:34:56 GMT');
    final authorization = utf8.decode(
      base64.decode(uri.queryParameters['authorization']!),
    );
    expect(authorization, contains('api_key="test-key"'));
    expect(authorization, contains('algorithm="hmac-sha256"'));
    expect(authorization, isNot(contains('private-secret')));
  });

  test('XML 解析生成儿童加权分和错词', () {
    const xml = '''
      <xml_result>
        <read_sentence total_score="36" accuracy_score="50"
          fluency_score="80" standard_score="20" integrity_score="90">
          <sentence>
            <word content="My" total_score="88" />
            <word content="Granny" total_score="42" />
          </sentence>
        </read_sentence>
      </xml_result>
    ''';

    final result = parseXfyunIseXml(xml);

    expect(result.provider, 'xfyun_ise');
    expect(result.childScore, closeTo(81.5, 0.001));
    expect(result.stars, 4);
    expect(result.words, hasLength(2));
    expect(result.words.first.isError, isFalse);
    expect(result.words.last.isError, isTrue);
  });

  test('缺少句子维度时返回可理解异常', () {
    expect(
      () => parseXfyunIseXml('<xml_result />'),
      throwsA(
        isA<ScoringException>().having(
          (error) => error.message,
          'message',
          '讯飞没有返回句子评分',
        ),
      ),
    );
  });

  // 16 kHz × 16-bit mono:每毫秒 32 字节,每 20ms 一帧 640 字节。
  // [amplitude] 为常数样本幅值,其帧 RMS 恰为该值,便于断言。
  Uint8List pcm({
    required int silenceHeadMs,
    required int speechMs,
    required int silenceTailMs,
    int amplitude = 5000,
  }) {
    final bytes = Uint8List((silenceHeadMs + speechMs + silenceTailMs) * 32);
    final view = ByteData.sublistView(bytes);
    final speechStart = silenceHeadMs * 32;
    for (var offset = speechStart;
        offset < speechStart + speechMs * 32;
        offset += 2) {
      view.setInt16(offset, amplitude, Endian.little);
    }
    return bytes;
  }

  test('评分上传前裁掉首尾静音并保留安全边距', () {
    final input = pcm(silenceHeadMs: 1000, speechMs: 1000, silenceTailMs: 2000);

    final trimmed = trimPcm16kSilence(input);
    final view = ByteData.sublistView(trimmed);

    // 保留语音前 200ms、语音后 300ms:从 800ms 裁到 2300ms,共 1500ms。
    expect(trimmed.length, 1500 * 32);
    expect(
      view.getInt16(200 * 32 - 2, Endian.little),
      0,
      reason: '头部 200ms 保护区保持静音',
    );
    expect(view.getInt16(200 * 32, Endian.little), 5000);
    expect(
      view.getInt16(trimmed.length - 300 * 32 - 2, Endian.little),
      5000,
      reason: '语音后紧接 300ms 尾部保护区',
    );
    expect(view.getInt16(trimmed.length - 2, Endian.little), 0);
  });

  test('自适应判定线:AGC 放大的房间噪声不再挡住首尾静音裁剪', () {
    // 真机发现 Android AGC 会把安静房间的噪声抬到固定判定线之上。
    // 噪声幅值 400(高于旧固定线 300),语音幅值 4000。
    Uint8List mix({
      required int headMs,
      required int speechMs,
      required int tailMs,
    }) {
      final head = pcm(
        silenceHeadMs: headMs,
        speechMs: 0,
        silenceTailMs: 0,
        amplitude: 400,
      );
      final speech = pcm(
        silenceHeadMs: 0,
        speechMs: speechMs,
        silenceTailMs: 0,
        amplitude: 4000,
      );
      final tail = pcm(
        silenceHeadMs: 0,
        speechMs: 0,
        silenceTailMs: tailMs,
        amplitude: 400,
      );
      return Uint8List.fromList([...head, ...speech, ...tail]);
    }

    final input = mix(headMs: 800, speechMs: 1200, tailMs: 2000);
    final trimmed = trimPcm16kSilence(input);

    // 语音 800–2000ms,保留前后边距后应为 600–2300ms,共 1700ms。
    expect(trimmed.length, 1700 * 32);
  });

  test('整段只有噪声(无显著响亮语音)时不裁剪,避免误删', () {
    final noiseOnly =
        pcm(silenceHeadMs: 0, speechMs: 3000, silenceTailMs: 0, amplitude: 400);

    expect(identical(trimPcm16kSilence(noiseOnly), noiseOnly), isTrue);
  });

  test('全静音或过短的录音不裁剪,避免误删有效内容', () {
    final silent = pcm(silenceHeadMs: 0, speechMs: 0, silenceTailMs: 3000);
    expect(identical(trimPcm16kSilence(silent), silent), isTrue);

    final short = pcm(silenceHeadMs: 0, speechMs: 100, silenceTailMs: 200);
    expect(identical(trimPcm16kSilence(short), short), isTrue);
  });

  test('语音贯穿首尾时整段保留', () {
    final input = pcm(silenceHeadMs: 0, speechMs: 2000, silenceTailMs: 0);

    expect(identical(trimPcm16kSilence(input), input), isTrue);
  });
}
