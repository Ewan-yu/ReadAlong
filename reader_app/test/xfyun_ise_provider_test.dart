import 'dart:convert';

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
}
