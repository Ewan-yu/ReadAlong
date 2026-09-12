// 临时真机验证器（follow-streaming 分支专用，合并前移除）。
//
// 为"跟读边录边传"方案提供 go/no-go 依据，在应用启动时自动运行并输出
// readalong.spike 前缀日志：
//   A. startStream 流式采集静音 6s：字节连续性 + 20ms 帧 RMS 分布；
//   B. 文件模式采集静音 6s：与 A 对照验证流模式的 AGC/噪声抑制是否同样生效；
//   C. WSS 预建连 ×3：握手与 ssb 发出耗时（需藏进 650ms 稳定期）；
//   D. 扬声器回采语音后，同一段 PCM 用三种节奏评分：
//      paced-untrimmed / fast-untrimmed / paced-trimmed，观察引擎对上传
//      节奏与首尾静音的容忍度；
//   E. startStream 与 cancel/stop/dispose 交错的生命周期安全性。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';

import '../services/recording/recording_service.dart';
import '../services/scoring/ise_credentials.dart';
import '../services/scoring/xfyun_ise_provider.dart';

/// 每次调整 spike 内容后置 true 构建；平时置 false 不影响应用。
/// 2026-09-12 结论已出：流式 NO-GO（1.2.6/1.3.1 均零数据+stop 死锁），
/// 批量加速（12800B 帧无间隔）已验证评分一致。文件保留备查，合并前移除。
const kStreamingSpikeEnabled = false;

void maybeRunStreamingSpike() {
  if (!kStreamingSpikeEnabled) return;
  unawaited(_runSpike());
}

Future<void> _runSpike() async {
  await Future<void>.delayed(const Duration(seconds: 3));
  final clock = Stopwatch()..start();
  void log(String line) =>
      debugPrint('readalong.spike [+${clock.elapsedMilliseconds}ms] $line');
  try {
    log('BEGIN');
    final store = SecureIseCredentialStore(const FlutterSecureStorage());
    final credentials = await store.read();
    if (credentials == null || !credentials.isComplete) {
      log('SKIP no-credentials');
      return;
    }
    log('credentials ok');
    final hasPermission = await AudioRecorder().hasPermission();
    log('hasPermission=$hasPermission');
    final tmp = Directory.systemTemp;
    // startStream 在 Android 上恒输出 PCM16，encoder 字段被忽略。
    const streamCfg = RecordConfig(
      encoder: AudioEncoder.wav,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: false,
      noiseSuppress: true,
    );

    // ---- A. 流式静音采集 ----
    final recorderA = AudioRecorder();
    final chunksA = <Uint8List>[];
    try {
      log('A1 calling startStream');
      final stream = await recorderA
          .startStream(streamCfg)
          .timeout(const Duration(seconds: 10));
      log('A2 startStream returned');
      final sub = stream.listen(chunksA.add,
          onError: (Object error) => log('A stream-onError $error'));
      await Future<void>.delayed(const Duration(seconds: 6));
      log('A3 chunks=${chunksA.length} '
          'bytes=${chunksA.fold<int>(0, (sum, c) => sum + c.length)}');
      await recorderA.stop().timeout(const Duration(seconds: 10));
      log('A4 stop returned');
      await sub.cancel();
      final pcm = _concat(chunksA);
      log('A stream-silence bytes=${pcm.length} expected≈192000 '
          'stats=${_rmsStats(pcm)}');
      await _writeWav(File('${tmp.path}/spike_a_silence.wav'), pcm);
    } on Object catch (error) {
      log('A stream-silence ERROR $error');
    }
    try {
      await recorderA.dispose().timeout(const Duration(seconds: 5));
    } on Object catch (error) {
      log('A dispose ERROR $error');
    }

    // ---- B. 文件模式静音采集（对照音效链）----
    try {
      final path = '${tmp.path}/spike_b_silence.wav';
      final recorderB = AudioRecorder();
      log('B1 calling start(file)');
      await recorderB
          .start(
            const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 16000,
              numChannels: 1,
              autoGain: true,
              echoCancel: true,
              noiseSuppress: true,
            ),
            path: path,
          )
          .timeout(const Duration(seconds: 10));
      log('B2 start(file) returned');
      await Future<void>.delayed(const Duration(seconds: 6));
      await recorderB.stop().timeout(const Duration(seconds: 10));
      log('B3 stop returned');
      await recorderB.dispose().timeout(const Duration(seconds: 5));
      final pcm = parseWavPcm16(await File(path).readAsBytes()).pcm16k;
      log('B file-silence bytes=${pcm.length} stats=${_rmsStats(pcm)}');
    } on Object catch (error) {
      log('B file-silence ERROR $error');
    }

    // ---- C. 预建连握手 + ssb 计时 ----
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final sw = Stopwatch()..start();
        final channel = IOWebSocketChannel.connect(buildXfyunAuthUri(
          apiKey: credentials.apiKey,
          apiSecret: credentials.apiSecret,
          now: DateTime.now().toUtc(),
        ));
        await channel.ready.timeout(const Duration(seconds: 10));
        final tReady = sw.elapsedMilliseconds;
        channel.sink.add(jsonEncode({
          'common': {'app_id': credentials.appId},
          'business': {
            'sub': 'ise',
            'ent': 'en_vip',
            'category': 'read_sentence',
            'cmd': 'ssb',
            'aue': 'raw',
            'auf': 'audio/L16;rate=16000',
            'text': '\ufeff[content]\nHello.',
            'tte': 'utf-8',
            'ttp_skip': true,
            'rst': 'entirety',
            'ise_unite': '1',
            'extra_ability': 'multi_dimension',
          },
          'data': {'status': 0, 'data': ''},
        }));
        log('C preconnect#$attempt t_ready=${tReady}ms '
            't_ssb=${sw.elapsedMilliseconds}ms');
        await channel.sink.close();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } on Object catch (error) {
        log('C preconnect#$attempt ERROR $error');
      }
    }

    // ---- D. 扬声器回采 + 三种上传节奏评分 ----
    final speechPcm = await _captureLoopback(log, tmp);
    if (speechPcm.length >= 16000) {
      final modes = <(String, int, int, bool)>[
        ('paced-untrimmed', 1280, 40, false),
        ('fast-untrimmed', 12800, 0, false),
        ('paced-trimmed', 1280, 40, true),
      ];
      for (final mode in modes) {
        final pcm = mode.$4
            ? trimPcm16kSilence(speechPcm)
            : Uint8List.fromList(speechPcm);
        final result = await _iseScore(
          credentials: credentials,
          pcm: pcm,
          refText: 'Hello.',
          frameBytes: mode.$2,
          frameDelayMs: mode.$3,
        );
        log('D score ${mode.$1} code=${result.code} sid=${result.sid} '
            'elapsed=${result.elapsedMs}ms scores=${result.scores} '
            'message=${result.message}');
      }
    } else {
      log('D skip: loopback capture too short (${speechPcm.length}B)');
    }

    // ---- E. 流式生命周期交错 ----
    try {
      final r1 = AudioRecorder();
      await r1.startStream(streamCfg).timeout(const Duration(seconds: 10));
      await r1.cancel().timeout(const Duration(seconds: 10));
      log('E stream-cancel ok');
      await r1.startStream(streamCfg).timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await r1.stop().timeout(const Duration(seconds: 10));
      log('E stream-stop ok');
      await r1.dispose().timeout(const Duration(seconds: 5));
      log('E stream-dispose ok');
    } on Object catch (error) {
      log('E lifecycle ERROR $error');
    }

    log('SUMMARY done');
  } on Object catch (error, stack) {
    log('FATAL $error');
    debugPrint('readalong.spike stack $stack');
  }
}

Future<Uint8List> _captureLoopback(
  void Function(String) log,
  Directory tmp,
) async {
  // startStream 在 record_android 1.2.6 上一致性悬挂（零数据 + stop 死锁），
  // 回采改用已验证可用的文件模式；评分节奏 A/B 不依赖采集方式。
  try {
    final player = AudioPlayer();
    await player.setAsset('assets/audio/encouragement/good_job.wav');
    final path = '${tmp.path}/spike_d_loopback.wav';
    final recorder = AudioRecorder();
    log('D1 calling start(file)');
    await recorder
        .start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
            autoGain: true,
            echoCancel: false,
            noiseSuppress: false,
          ),
          path: path,
        )
        .timeout(const Duration(seconds: 10));
    log('D2 start(file) returned');
    await player.play();
    await Future<void>.delayed(const Duration(seconds: 2));
    await recorder.stop().timeout(const Duration(seconds: 10));
    log('D3 stop returned');
    await recorder.dispose().timeout(const Duration(seconds: 5));
    await player.dispose();
    final pcm = parseWavPcm16(await File(path).readAsBytes()).pcm16k;
    log('D loopback bytes=${pcm.length} stats=${_rmsStats(pcm)}');
    return pcm;
  } on Object catch (error) {
    log('D loopback ERROR $error');
    return Uint8List(0);
  }
}

final class _IseOutcome {
  const _IseOutcome(
    this.code,
    this.sid,
    this.elapsedMs, {
    this.scores,
    this.message,
  });

  final int code;
  final String? sid;
  final int elapsedMs;
  final Map<String, double>? scores;
  final String? message;
}

/// 复刻生产 _request 的最小 ISE 客户端，帧大小与帧间隔可调。
Future<_IseOutcome> _iseScore({
  required IseCredentials credentials,
  required Uint8List pcm,
  required String refText,
  required int frameBytes,
  required int frameDelayMs,
}) async {
  final sw = Stopwatch()..start();
  final channel = IOWebSocketChannel.connect(buildXfyunAuthUri(
    apiKey: credentials.apiKey,
    apiSecret: credentials.apiSecret,
    now: DateTime.now().toUtc(),
  ));
  final completer = Completer<Map<String, Object?>>();
  late final StreamSubscription<Object?> subscription;
  subscription = channel.stream.listen(
    (message) {
      try {
        final decoded = jsonDecode(message as String);
        if (decoded is! Map<String, dynamic>) return;
        final code = decoded['code'];
        if (code is int && code != 0) {
          if (!completer.isCompleted) {
            completer.complete({
              'code': code,
              'sid': decoded['sid'],
              'message': decoded['message'],
            });
          }
          return;
        }
        final data = decoded['data'];
        if (data is Map<String, dynamic> && data['status'] == 2) {
          if (!completer.isCompleted) {
            completer.complete({
              'code': 0,
              'sid': decoded['sid'],
              'xml': data['data'],
            });
          }
        }
      } on Object {
        if (!completer.isCompleted) {
          completer
              .complete(const {'code': -1, 'sid': null, 'message': 'decode'});
        }
      }
    },
    onError: (Object error) {
      if (!completer.isCompleted) {
        completer.complete({
          'code': -2,
          'sid': null,
          'message': error.toString(),
        });
      }
    },
    onDone: () {
      if (!completer.isCompleted) {
        completer
            .complete(const {'code': -3, 'sid': null, 'message': 'closed'});
      }
    },
  );

  try {
    await channel.ready;
    channel.sink.add(jsonEncode({
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
    }));
    if (frameDelayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: frameDelayMs));
    }
    for (var offset = 0; offset < pcm.length; offset += frameBytes) {
      final end = math.min(offset + frameBytes, pcm.length);
      final isLast = end == pcm.length;
      channel.sink.add(jsonEncode({
        'business': {
          'cmd': 'auw',
          'aus': isLast ? 4 : (offset == 0 ? 1 : 2),
        },
        'data': {
          'status': isLast ? 2 : 1,
          'data': base64.encode(Uint8List.sublistView(pcm, offset, end)),
        },
      }));
      if (!isLast && frameDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: frameDelayMs));
      }
    }
    final result = await completer.future.timeout(const Duration(seconds: 25),
        onTimeout: () {
      return const {'code': -4, 'sid': null, 'message': 'timeout'};
    });
    final code = result['code'] as int;
    final sid = result['sid']?.toString();
    final message = result['message']?.toString();
    return _IseOutcome(
      code,
      sid,
      sw.elapsedMilliseconds,
      scores: code == 0 ? _extractScores(result['xml']?.toString()) : null,
      message: message,
    );
  } finally {
    await subscription.cancel();
    await channel.sink.close();
  }
}

Map<String, double>? _extractScores(String? xml) {
  if (xml == null) return null;
  final decoded = utf8.decode(base64.decode(xml), allowMalformed: true);
  double? attr(String name) {
    final match = RegExp('$name="(\\d+(?:\\.\\d+)?)"').firstMatch(decoded);
    return match == null ? null : double.tryParse(match.group(1)!);
  }

  final accuracy = attr('accuracy_score');
  final fluency = attr('fluency_score');
  final integrity = attr('integrity_score');
  if (accuracy == null && fluency == null && integrity == null) return null;
  return {
    'accuracy': accuracy ?? -1,
    'fluency': fluency ?? -1,
    'integrity': integrity ?? -1,
    'total': attr('total_score') ?? -1,
  };
}

Uint8List _concat(List<Uint8List> chunks) {
  final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
  final result = Uint8List(total);
  var offset = 0;
  for (final chunk in chunks) {
    result.setRange(offset, offset + chunk.length, chunk);
    offset += chunk.length;
  }
  return result;
}

/// 20ms 帧 RMS 分布：p50/p90/max，用于对照静音底噪与语音能量。
Map<String, double> _rmsStats(Uint8List pcm) {
  const frameBytes = 640; // 16 kHz × 16bit × 20ms。
  final rms = <double>[];
  final view = ByteData.sublistView(pcm);
  for (var base = 0; base + frameBytes <= pcm.length; base += frameBytes) {
    var sumSquares = 0.0;
    for (var offset = 0; offset < frameBytes; offset += 2) {
      final sample = view.getInt16(base + offset, Endian.little);
      sumSquares += sample * sample;
    }
    rms.add(math.sqrt(sumSquares / (frameBytes ~/ 2)));
  }
  if (rms.isEmpty) {
    return const {'p50': 0, 'p90': 0, 'max': 0, 'frames': 0};
  }
  rms.sort();
  double percentile(double fraction) =>
      rms[((rms.length - 1) * fraction).floor()];
  return {
    'p50': percentile(0.5),
    'p90': percentile(0.9),
    'max': rms.last,
    'frames': rms.length.toDouble(),
  };
}

Future<void> _writeWav(File file, Uint8List pcm) async {
  final bytes = Uint8List(44 + pcm.length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 16000, Endian.little);
  view.setUint32(28, 32000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  await file.writeAsBytes(bytes);
}
