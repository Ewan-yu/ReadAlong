/// 统一评分结果模型 — 所有 ScoringProvider 归一化到这个结构。
class ScoreResult {
  /// 儿童加权分 0–100（functional-design B4 公式，PoC-B3 双样本验证）：
  /// child_score = fluency×0.45 + integrity×0.45 + accuracy×0.10
  final double childScore;

  /// 星级 0–5，保留半星（childScore ÷ 20）
  double get stars => (childScore / 20 * 2).roundToDouble() / 2;

  /// 原始 4 维（家长详情折叠区展示；standard 对儿童参考价值有限）
  final double? total;
  final double? accuracy;
  final double? fluency;
  final double? standard;
  final double? integrity;

  /// 读错的词（accuracy<60），用于错词标红
  final List<WordScore> words;

  final String provider; // 'xfyun_ise' | 'whisper_local'

  const ScoreResult({
    required this.childScore,
    required this.provider,
    this.total,
    this.accuracy,
    this.fluency,
    this.standard,
    this.integrity,
    this.words = const [],
  });

  static double weighted({
    required double fluency,
    required double integrity,
    required double accuracy,
  }) =>
      fluency * 0.45 + integrity * 0.45 + accuracy * 0.10;
}

class WordScore {
  final String word;
  final double? accuracy;
  const WordScore(this.word, this.accuracy);

  bool get isError => accuracy != null && accuracy! < 60;
}

/// 评分异常：网络/额度/鉴权失败等。跟读流程捕获后保留录音、提示重试。
class ScoringException implements Exception {
  final String message;
  final Object? cause;
  const ScoringException(this.message, [this.cause]);

  @override
  String toString() => 'ScoringException: $message';
}
