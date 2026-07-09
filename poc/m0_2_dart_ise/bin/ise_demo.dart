// M0.2 — 讯飞 ISE WebSocket Dart 最小验证
// =========================================
// 验证目标：纯 Dart 完成 HMAC-SHA256 鉴权 + WebSocket 分帧上传 + XML 结果解析。
// 通过后此文件逻辑沉淀为 reader_app 的 services/scoring/xfyun_ise.dart。
//
// 用法：
//   dart pub get
//   XF_APPID=... XF_APIKEY=... XF_APISECRET=... dart run bin/ise_demo.dart <16k单声道wav或pcm> "<参考文本>"
//
// ⚠️ 验证脚本，key 只从环境变量读，不入库。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/io.dart';

const iseHost = 'ise-api.xfyun.cn';
const isePath = '/v2/open-ise';

/// RFC1123 GMT 日期（讯飞要求英文星期/月份，不能用本地化格式）
String _rfc1123Now() {
  const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final t = DateTime.now().toUtc();
  String p2(int n) => n.toString().padLeft(2, '0');
  return '${wk[t.weekday - 1]}, ${p2(t.day)} ${mo[t.month - 1]} ${t.year} '
      '${p2(t.hour)}:${p2(t.minute)}:${p2(t.second)} GMT';
}

/// 生成鉴权 URL：HMAC-SHA256(host+date+request-line) → authorization query
Uri buildAuthUrl(String apiKey, String apiSecret) {
  final date = _rfc1123Now();
  final signOrigin = 'host: $iseHost\ndate: $date\nGET $isePath HTTP/1.1';
  final sig = base64.encode(
      Hmac(sha256, utf8.encode(apiSecret)).convert(utf8.encode(signOrigin)).bytes);
  final authOrigin = 'api_key="$apiKey", algorithm="hmac-sha256", '
      'headers="host date request-line", signature="$sig"';
  return Uri.parse('wss://$iseHost$isePath').replace(queryParameters: {
    'authorization': base64.encode(utf8.encode(authOrigin)),
    'date': date,
    'host': iseHost,
  });
}

/// 提取 wav 中的 PCM 数据（跳过 44 字节标准头；若无 RIFF 头则视为裸 PCM）
Uint8List loadPcm(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length > 44 && String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF') {
    // 找到 data chunk（有的 wav 带扩展头，44 不一定准）
    for (var i = 12; i < bytes.length - 8;) {
      final id = String.fromCharCodes(bytes.sublist(i, i + 4));
      final size = ByteData.sublistView(bytes, i + 4, i + 8).getUint32(0, Endian.little);
      if (id == 'data') return bytes.sublist(i + 8, i + 8 + size);
      i += 8 + size + (size & 1);
    }
  }
  return bytes;
}

Future<Map<String, double?>> iseScore({
  required String appId,
  required String apiKey,
  required String apiSecret,
  required Uint8List pcm,
  required String refText,
  String category = 'read_sentence',
}) async {
  final url = buildAuthUrl(apiKey, apiSecret);
  final channel = IOWebSocketChannel.connect(url);
  final done = Completer<String>();

  channel.stream.listen((msg) {
    final d = jsonDecode(msg as String) as Map<String, dynamic>;
    if (d['code'] != 0) {
      if (!done.isCompleted) {
        done.completeError('讯飞返回错误 code=${d['code']} msg=${d['message']} sid=${d['sid']}');
      }
      return;
    }
    final data = d['data'] as Map<String, dynamic>?;
    if (data != null && data['status'] == 2) {
      final xml = utf8.decode(base64.decode(data['data'] as String), allowMalformed: true);
      if (!done.isCompleted) done.complete(xml);
    }
  }, onError: (e) {
    if (!done.isCompleted) done.completeError('WebSocket 错误: $e');
  }, onDone: () {
    if (!done.isCompleted) done.completeError('连接关闭但未收到结果（检查 key/额度）');
  });

  // 帧1: ssb 参数帧（BOM + [content] 节点，讯飞英文 read_sentence 协议要求）
  final text = '﻿[content]\n$refText';
  channel.sink.add(jsonEncode({
    'common': {'app_id': appId},
    'business': {
      'sub': 'ise',
      'ent': 'en_vip',
      'category': category,
      'cmd': 'ssb',
      'aue': 'raw',
      'auf': 'audio/L16;rate=16000',
      'text': text,
      'tte': 'utf-8',
      'ttp_skip': true,
      'rst': 'entirety',
      'ise_unite': '1',
      'extra_ability': 'multi_dimension',
    },
    'data': {'status': 0, 'data': ''},
  }));
  await Future.delayed(const Duration(milliseconds: 40));

  // 帧2..: auw 音频帧，1280 字节/帧，间隔 40ms；aus: 1 首 / 2 中 / 4 末
  const chunk = 1280;
  for (var i = 0; i < pcm.length; i += chunk) {
    final end = (i + chunk < pcm.length) ? i + chunk : pcm.length;
    final isLast = end >= pcm.length;
    channel.sink.add(jsonEncode({
      'business': {'cmd': 'auw', 'aus': i == 0 ? 1 : (isLast ? 4 : 2)},
      'data': {
        'status': isLast ? 2 : 1,
        'data': base64.encode(pcm.sublist(i, end)),
      },
    }));
    await Future.delayed(const Duration(milliseconds: 40));
  }

  final xml = await done.future.timeout(const Duration(seconds: 15));
  await channel.sink.close();
  return parseIseXml(xml);
}

/// 从结果 XML 提取 5 维分数（与 Python PoC 相同的正则法，正式版换 xml 包解析词级）
Map<String, double?> parseIseXml(String xml) {
  double? find(String attr) {
    final m = RegExp('$attr="([\\d.]+)"').firstMatch(xml);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  return {
    'total': find('total_score'),
    'accuracy': find('accuracy_score'),
    'fluency': find('fluency_score'),
    'standard': find('standard_score'),
    'integrity': find('integrity_score'),
  };
}

Future<void> main(List<String> args) async {
  final appId = Platform.environment['XF_APPID'];
  final apiKey = Platform.environment['XF_APIKEY'];
  final apiSecret = Platform.environment['XF_APISECRET'];
  if (appId == null || apiKey == null || apiSecret == null) {
    stderr.writeln('❌ 请设置 XF_APPID / XF_APIKEY / XF_APISECRET 环境变量');
    exit(1);
  }
  if (args.length < 2) {
    stderr.writeln('用法: dart run bin/ise_demo.dart <16k单声道wav/pcm> "<参考文本>"');
    exit(1);
  }
  final audioPath = args[0];
  final refText = args[1];
  if (!File(audioPath).existsSync()) {
    stderr.writeln('❌ 找不到音频: $audioPath');
    exit(1);
  }

  final pcm = loadPcm(audioPath);
  print('音频 PCM: ${pcm.length} 字节（约 ${(pcm.length / 32000).toStringAsFixed(1)} 秒）');
  print('参考文本: $refText');
  print('连接讯飞 ISE...');

  try {
    final r = await iseScore(
      appId: appId,
      apiKey: apiKey,
      apiSecret: apiSecret,
      pcm: pcm,
      refText: refText,
    );
    print('✅ 评分结果:');
    print('  total_score    : ${r['total']}');
    print('  accuracy_score : ${r['accuracy']}');
    print('  fluency_score  : ${r['fluency']}');
    print('  standard_score : ${r['standard']}');
    print('  integrity_score: ${r['integrity']}');
    final child = (r['fluency'] ?? 0) * 0.45 +
        (r['integrity'] ?? 0) * 0.45 +
        (r['accuracy'] ?? 0) * 0.10;
    print('  child_score(加权): ${child.toStringAsFixed(1)} → '
        '${(child / 20).toStringAsFixed(1)} 星');
  } catch (e) {
    stderr.writeln('❌ $e');
    exit(2);
  }
}
