import 'dart:typed_data';

import 'score_models.dart';

/// 评分 Provider 抽象 — 讯飞 ISE 为主，Whisper 本地兜底（二期）。
abstract interface class ScoringProvider {
  String get name;

  /// 是否已配置可用（如讯飞需要 key）
  Future<bool> isConfigured();

  /// 对一段录音按参考文本评分。
  /// [pcm16k]：16kHz 16bit 单声道 PCM（不含 wav 头）。
  /// 失败抛 [ScoringException]，调用方保留录音供重试。
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  });
}
