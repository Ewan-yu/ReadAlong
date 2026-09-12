import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xml/xml.dart';

import 'ise_credentials.dart';
import 'score_models.dart';
import 'scoring_provider.dart';

const _iseHost = 'ise-api.xfyun.cn';
const _isePath = '/v2/open-ise';

/// Silence trimming keeps the scored payload tight and consistent across
/// takes; the engine scores trimmed and untrimmed audio almost identically
/// (device-verified 2026-09-12), so this is hygiene rather than latency work.
const _scoringSilenceHeadMargin = Duration(milliseconds: 200);
const _scoringSilenceTailMargin = Duration(milliseconds: 300);
const _scoringRmsSpeechFloor = 300;
const _scoringMinTrimmedAudio = Duration(milliseconds: 500);

/// Removes leading/trailing silence around the first and last audible speech
/// frame while keeping short safety margins. The speech floor adapts to the
/// take itself: Android's AGC amplifies quiet-room noise above any fixed
/// absolute floor, which real-device scoring showed leaves the automatic
/// trailing silence untrimmed. A take without clearly louder speech (noise
/// only) is returned unchanged — never risk cutting content.
Uint8List trimPcm16kSilence(Uint8List pcm16k) {
  const bytesPerSample = 2;
  const samplesPerFrame = 320; // 16 kHz × 20 ms frame.
  const bytesPerFrame = samplesPerFrame * bytesPerSample;
  const bytesPerMillisecond = 32; // 16 kHz × 16-bit mono.
  final minTrimmedBytes =
      _scoringMinTrimmedAudio.inMilliseconds * bytesPerMillisecond;
  if (pcm16k.length <= minTrimmedBytes) return pcm16k;
  final view = ByteData.sublistView(pcm16k);
  final frameCount = pcm16k.length ~/ bytesPerFrame;
  final frameRms = List<double>.filled(frameCount, 0);
  for (var frame = 0; frame < frameCount; frame++) {
    var sumSquares = 0;
    final base = frame * bytesPerFrame;
    for (var offset = 0; offset < bytesPerFrame; offset += bytesPerSample) {
      final sample = view.getInt16(base + offset, Endian.little);
      sumSquares += sample * sample;
    }
    frameRms[frame] = math.sqrt(sumSquares / samplesPerFrame);
  }
  // A loud reference from the take's own loudest frames. Speech after AGC
  // sits far above room noise, so a fraction of it re-draws the noise floor.
  final loudness = _percentile(frameRms, 0.9);
  final floor = math.max(
    _scoringRmsSpeechFloor.toDouble(),
    loudness * 0.12,
  );
  var firstSpeech = -1;
  var lastSpeech = -1;
  for (var frame = 0; frame < frameCount; frame++) {
    if (frameRms[frame] >= floor) {
      if (firstSpeech < 0) firstSpeech = frame;
      lastSpeech = frame;
    }
  }
  if (firstSpeech < 0) return pcm16k;
  final headFrames = _scoringSilenceHeadMargin.inMilliseconds ~/ 20;
  final tailFrames = _scoringSilenceTailMargin.inMilliseconds ~/ 20;
  final minFrames = minTrimmedBytes ~/ bytesPerFrame;
  var startFrame = firstSpeech - headFrames;
  var endFrame = lastSpeech + 1 + tailFrames;
  if (endFrame - startFrame < minFrames) {
    endFrame = startFrame + minFrames;
  }
  startFrame = startFrame.clamp(0, frameCount);
  endFrame = endFrame.clamp(0, frameCount);
  if (endFrame - startFrame < minFrames) {
    startFrame = (endFrame - minFrames).clamp(0, frameCount);
  }
  final start = startFrame * bytesPerFrame;
  final end = endFrame * bytesPerFrame;
  if (start == 0 && end >= pcm16k.length) return pcm16k;
  return Uint8List.sublistView(pcm16k, start, end);
}

double _percentile(List<double> values, double fraction) {
  if (values.isEmpty) return 0;
  final sorted = List<double>.of(values)..sort();
  final index = (sorted.length - 1) * fraction;
  final lower = index.floor();
  final upper = index.ceil();
  if (lower == upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}

typedef XfyunChannelConnector = WebSocketChannel Function(Uri uri);

abstract interface class IseConnectionProbe {
  Future<void> testCredentials(IseCredentials credentials);
}

final class XfyunIseProvider implements ScoringProvider, IseConnectionProbe {
  XfyunIseProvider({
    required this.credentialStore,
    XfyunChannelConnector? connector,
    DateTime Function()? now,
  })  : _connector = connector ?? IOWebSocketChannel.connect,
        _now = now ?? DateTime.now;

  final IseCredentialStore credentialStore;
  final XfyunChannelConnector _connector;
  final DateTime Function() _now;

  @override
  String get name => 'xfyun_ise';

  @override
  Future<bool> isConfigured() async =>
      (await credentialStore.read())?.isComplete ?? false;

  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async {
    final credentials = await credentialStore.read();
    if (credentials == null) {
      throw const ScoringException('请先在设置里配置讯飞评分');
    }
    if (pcm16k.isEmpty || refText.trim().isEmpty) {
      throw const ScoringException('录音或参考文本为空');
    }
    final trimmed = trimPcm16kSilence(pcm16k);
    final stopwatch = Stopwatch()..start();
    final xml = await _request(
      credentials: credentials,
      pcm16k: trimmed,
      refText: refText.trim(),
    );
    stopwatch.stop();
    debugPrint(
      'readalong.ise timing: audio=${pcm16k.length ~/ 32}ms '
      'trimmed=${trimmed.length ~/ 32}ms upload+eval='
      '${stopwatch.elapsedMilliseconds}ms',
    );
    return parseXfyunIseXml(xml);
  }

  @override
  Future<void> testCredentials(IseCredentials credentials) async {
    final value = credentials.normalized();
    if (!value.isComplete) {
      throw const ScoringException('请填写完整的讯飞配置');
    }
    await _request(
      credentials: value,
      pcm16k: Uint8List(32000),
      refText: 'Hello.',
    );
  }

  Future<String> _request({
    required IseCredentials credentials,
    required Uint8List pcm16k,
    required String refText,
  }) async {
    final channel = _connector(
      buildXfyunAuthUri(
        apiKey: credentials.apiKey,
        apiSecret: credentials.apiSecret,
        now: _now().toUtc(),
      ),
    );
    final result = Completer<String>();
    late final StreamSubscription<Object?> subscription;
    subscription = channel.stream.listen(
      (message) {
        try {
          final decoded = jsonDecode(message as String);
          if (decoded is! Map<String, dynamic>) {
            throw const ScoringException('讯飞返回了无法识别的数据');
          }
          final code = decoded['code'];
          if (code is int && code != 0) {
            if (!result.isCompleted) {
              result.completeError(_mapXfyunError(code));
            }
            return;
          }
          final data = decoded['data'];
          if (data is Map<String, dynamic> && data['status'] == 2) {
            final payload = data['data'];
            if (payload is! String || payload.isEmpty) {
              throw const ScoringException('讯飞没有返回评分结果');
            }
            final xml = utf8.decode(
              base64.decode(payload),
              allowMalformed: true,
            );
            if (!result.isCompleted) result.complete(xml);
          }
        } on Object catch (error) {
          if (!result.isCompleted) {
            result.completeError(
              error is ScoringException
                  ? error
                  : const ScoringException('讯飞返回了无法识别的数据'),
            );
          }
        }
      },
      onError: (_) {
        if (!result.isCompleted) {
          result.completeError(
            const ScoringException('网络有点慢，录音已保存，可以稍后重试'),
          );
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.completeError(
            const ScoringException('暂时没有拿到分数，录音已经保存'),
          );
        }
      },
    );

    try {
      channel.sink.add(
        jsonEncode({
          'common': {'app_id': credentials.appId},
          'business': {
            'sub': 'ise',
            'ent': 'en_vip',
            'category': 'read_sentence',
            'cmd': 'ssb',
            'aue': 'raw',
            'auf': 'audio/L16;rate=16000',
            'text': '\ufeff[content]\n$refText',
            'tte': 'utf-8',
            'ttp_skip': true,
            'rst': 'entirety',
            'ise_unite': '1',
            'extra_ability': 'multi_dimension',
          },
          'data': {'status': 0, 'data': ''},
        }),
      );
      // Device-verified 2026-09-12: the engine scores large frames sent in
      // one burst identically to the documented 40ms/1280B pacing (sid
      // compared), cutting upload wall time from ≈audio duration to ≈0.2s.
      // Official cap is 19200B per frame (26000B after base64).
      const chunkSize = 12800;
      for (var offset = 0; offset < pcm16k.length; offset += chunkSize) {
        final end = (offset + chunkSize).clamp(0, pcm16k.length);
        final isFirst = offset == 0;
        final isLast = end == pcm16k.length;
        channel.sink.add(
          jsonEncode({
            'business': {
              'cmd': 'auw',
              'aus': isLast ? 4 : (isFirst ? 1 : 2),
            },
            'data': {
              'status': isLast ? 2 : 1,
              'data': base64.encode(
                Uint8List.sublistView(pcm16k, offset, end),
              ),
            },
          }),
        );
      }

      return await result.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw const ScoringException(
          '网络有点慢，录音已保存，可以稍后重试',
        ),
      );
    } on ScoringException {
      rethrow;
    } on Object {
      throw const ScoringException('暂时没有拿到分数，录音已经保存');
    } finally {
      await subscription.cancel();
      await channel.sink.close();
    }
  }
}

Uri buildXfyunAuthUri({
  required String apiKey,
  required String apiSecret,
  required DateTime now,
}) {
  final date = _rfc1123(now.toUtc());
  final source = 'host: $_iseHost\ndate: $date\nGET $_isePath HTTP/1.1';
  final signature = base64.encode(
    Hmac(sha256, utf8.encode(apiSecret)).convert(utf8.encode(source)).bytes,
  );
  final authorization = 'api_key="$apiKey", algorithm="hmac-sha256", '
      'headers="host date request-line", signature="$signature"';
  return Uri.parse('wss://$_iseHost$_isePath').replace(
    queryParameters: {
      'authorization': base64.encode(utf8.encode(authorization)),
      'date': date,
      'host': _iseHost,
    },
  );
}

String _rfc1123(DateTime value) {
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String two(int number) => number.toString().padLeft(2, '0');
  return '${weekdays[value.weekday - 1]}, ${two(value.day)} '
      '${months[value.month - 1]} ${value.year} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)} GMT';
}

ScoreResult parseXfyunIseXml(String source) {
  try {
    final document = XmlDocument.parse(source);
    final elements = document.descendants.whereType<XmlElement>();
    final sentence = elements.cast<XmlElement?>().firstWhere(
          (element) =>
              element?.getAttribute('fluency_score') != null &&
              element?.getAttribute('integrity_score') != null,
          orElse: () => null,
        );
    if (sentence == null) {
      throw const ScoringException('讯飞没有返回句子评分');
    }
    double? number(String name) =>
        double.tryParse(sentence.getAttribute(name) ?? '');
    final accuracy = number('accuracy_score');
    final fluency = number('fluency_score');
    final integrity = number('integrity_score');
    if (accuracy == null || fluency == null || integrity == null) {
      throw const ScoringException('讯飞评分结果不完整');
    }
    final words = elements
        .where((element) => element.name.local.toLowerCase() == 'word')
        .map((element) {
          final word = element.getAttribute('content') ?? element.innerText;
          final wordAccuracy = double.tryParse(
            element.getAttribute('accuracy_score') ??
                element.getAttribute('total_score') ??
                '',
          );
          return WordScore(word.trim(), wordAccuracy);
        })
        .where((word) => word.word.isNotEmpty)
        .toList(growable: false);
    return ScoreResult(
      childScore: ScoreResult.weighted(
        fluency: fluency,
        integrity: integrity,
        accuracy: accuracy,
      ),
      provider: 'xfyun_ise',
      total: number('total_score'),
      accuracy: accuracy,
      fluency: fluency,
      standard: number('standard_score'),
      integrity: integrity,
      words: words,
    );
  } on ScoringException {
    rethrow;
  } on Object {
    throw const ScoringException('讯飞返回了无法识别的评分结果');
  }
}

ScoringException _mapXfyunError(int code) {
  if (code == 10105) {
    return const ScoringException('讯飞配置不正确，请检查后重试');
  }
  if (code == 11200 || code == 11201) {
    return const ScoringException('今日评分次数已用完');
  }
  return const ScoringException('暂时没有拿到分数，录音已经保存');
}

final xfyunIseProvider = Provider<XfyunIseProvider>(
  (ref) => XfyunIseProvider(
    credentialStore: ref.watch(iseCredentialStoreProvider),
  ),
);

final iseConnectionProbeProvider = Provider<IseConnectionProbe>(
  (ref) => ref.watch(xfyunIseProvider),
);

final scoringProvider = Provider<ScoringProvider>(
  (ref) => ref.watch(xfyunIseProvider),
);
