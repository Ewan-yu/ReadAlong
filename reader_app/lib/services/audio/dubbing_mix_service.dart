import 'package:path/path.dart' as p;

import '../../data/appdb/dubbing_models.dart';

/// M5.4 的儿童配音混音契约。
///
/// 此文件有意不依赖 Android/FFmpeg 插件：先把输入选择和安全规则固定，
/// 等原生混音引擎接入时只需实现 [DubbingMixService]。这样，即使 feature flag
/// 被误打开，也不会退回把带原朗读人声的 `original/source.mp3` 叠进作品。
const bool dubbingMixFeatureEnabled =
    bool.fromEnvironment('READALONG_ENABLE_NATIVE_DUBBING_MIX');

const double defaultDubbingBackgroundGainDb = -18;
const double _minimumBackgroundGainDb = -36;
const double _maximumBackgroundGainDb = -6;

enum DubbingMixMode { voiceOnly, withConfirmedBackground }

/// A selected, durable sentence Take in book order.
///
/// The caller must resolve [DubbingTake.audioRelativePath] through
/// `DubbingRepository.resolveAudioPath`; imports are never used as child
/// recording locations.
final class DubbingMixSentenceTake {
  const DubbingMixSentenceTake({
    required this.sentenceId,
    required this.sequence,
    required this.take,
    required this.audioPath,
  });

  final String sentenceId;
  final int sequence;
  final DubbingTake take;
  final String audioPath;
}

/// A validated, declarative mix request. It is safe to construct and inspect
/// on every platform; actual rendering is delegated to [DubbingMixService].
final class DubbingMixPlan {
  DubbingMixPlan._({
    required this.mode,
    required List<DubbingMixSentenceTake> sentenceTakes,
    required this.outputPath,
    required this.backgroundPath,
    required this.backgroundGainDb,
  }) : sentenceTakes = List.unmodifiable(sentenceTakes);

  factory DubbingMixPlan.create({
    required List<DubbingMixSentenceTake> sentenceTakes,
    required String outputPath,
    required DubbingMixMode mode,
    String? confirmedBackgroundPath,
    String? originalSourcePath,
    double backgroundGainDb = defaultDubbingBackgroundGainDb,
  }) {
    if (sentenceTakes.isEmpty) {
      throw const DubbingMixInputException('请先为至少一句选择一个配音版本。');
    }
    if (!backgroundGainDb.isFinite ||
        backgroundGainDb < _minimumBackgroundGainDb ||
        backgroundGainDb > _maximumBackgroundGainDb) {
      throw const DubbingMixInputException('背景音量必须在 -36 dB 到 -6 dB 之间。');
    }

    final normalizedOutput = _absolute(outputPath, '混音输出路径');
    _requireOutputExtension(normalizedOutput);
    final normalizedSource = originalSourcePath == null
        ? null
        : _absolute(originalSourcePath, '原音路径');
    final normalizedBackground = confirmedBackgroundPath == null
        ? null
        : _absolute(confirmedBackgroundPath, '背景轨路径');
    switch (mode) {
      case DubbingMixMode.voiceOnly:
        if (normalizedBackground != null) {
          throw const DubbingMixInputException('纯人声作品不能选择背景轨。');
        }
      case DubbingMixMode.withConfirmedBackground:
        if (normalizedBackground == null) {
          throw const DubbingMixInputException(
              '背景版只能使用已确认导出的 original/background.ogg。');
        }
        if (!_isConfirmedBackground(normalizedBackground)) {
          throw const DubbingMixInputException(
              '背景轨必须是已确认导出的 original/background.ogg。');
        }
        if (_samePath(normalizedBackground, normalizedSource) ||
            _isSourceAudio(normalizedBackground)) {
          throw const DubbingMixInputException(
              '禁止把 original/source.mp3 作为背景叠加到儿童录音。');
        }
    }

    final seenSentenceIds = <String>{};
    final seenSequences = <int>{};
    final normalizedTakes = <DubbingMixSentenceTake>[];
    for (final entry in sentenceTakes) {
      if (entry.sentenceId.isEmpty ||
          entry.sentenceId != entry.take.sentenceId ||
          entry.sequence < 1 ||
          !seenSentenceIds.add(entry.sentenceId) ||
          !seenSequences.add(entry.sequence)) {
        throw const DubbingMixInputException('每句只能选用一个有效的配音版本。');
      }
      if (entry.take.takeKind != DubbingTakeKind.sentence ||
          !entry.take.isSelected) {
        throw const DubbingMixInputException('只能混入已选用的逐句 Take。');
      }
      final path = _absolute(entry.audioPath, '儿童录音路径');
      if (p.extension(path).toLowerCase() != '.wav') {
        throw const DubbingMixInputException('儿童录音必须是私有目录中的 WAV Take。');
      }
      if (_samePath(path, normalizedSource) || _isSourceAudio(path)) {
        throw const DubbingMixInputException('儿童录音不能指向 original/source.mp3。');
      }
      if (_samePath(path, normalizedOutput) ||
          _samePath(path, normalizedBackground)) {
        throw const DubbingMixInputException('混音输出和输入音频必须是不同文件。');
      }
      normalizedTakes.add(DubbingMixSentenceTake(
        sentenceId: entry.sentenceId,
        sequence: entry.sequence,
        take: entry.take,
        audioPath: path,
      ));
    }
    if (_samePath(normalizedOutput, normalizedSource) ||
        _samePath(normalizedOutput, normalizedBackground)) {
      throw const DubbingMixInputException('混音输出不能覆盖原音或背景轨。');
    }
    normalizedTakes
        .sort((left, right) => left.sequence.compareTo(right.sequence));
    return DubbingMixPlan._(
      mode: mode,
      sentenceTakes: normalizedTakes,
      outputPath: normalizedOutput,
      backgroundPath: normalizedBackground,
      backgroundGainDb: backgroundGainDb,
    );
  }

  final DubbingMixMode mode;
  final List<DubbingMixSentenceTake> sentenceTakes;
  final String outputPath;

  /// Non-null only for [DubbingMixMode.withConfirmedBackground].
  final String? backgroundPath;
  final double backgroundGainDb;

  bool get usesConfirmedBackground =>
      mode == DubbingMixMode.withConfirmedBackground;
}

/// This is intentionally an interface rather than a silent no-op.
abstract interface class DubbingMixService {
  Future<DubbingMixResult> render(DubbingMixPlan plan);
}

final class DubbingMixResult {
  const DubbingMixResult({
    required this.outputPath,
    required this.mode,
  });

  final String outputPath;
  final DubbingMixMode mode;
}

/// Thrown rather than producing a fake "completed" master when no native
/// renderer is bundled in the current Android build.
final class DubbingMixUnavailableException implements Exception {
  const DubbingMixUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'DubbingMixUnavailableException: $message';
}

final class DubbingMixInputException implements Exception {
  const DubbingMixInputException(this.message);

  final String message;

  @override
  String toString() => 'DubbingMixInputException: $message';
}

/// Default implementation until a reviewed Android FFmpeg bridge is shipped.
///
/// It is feature-gated so callers can wire the flow now, while the explicit
/// error keeps M5.4 from claiming a background mix was rendered on devices
/// that cannot do so offline.
final class FeatureGatedDubbingMixService implements DubbingMixService {
  const FeatureGatedDubbingMixService(
      {this.enabled = dubbingMixFeatureEnabled});

  final bool enabled;

  @override
  Future<DubbingMixResult> render(DubbingMixPlan plan) {
    final detail =
        enabled ? '本构建未注册 Android 本地混音引擎。' : '本构建未启用 Android 本地混音功能。';
    return Future<DubbingMixResult>.error(DubbingMixUnavailableException(
      '$detail 已保留选用 Take；请生成纯人声回放或升级后重试。',
    ));
  }
}

String _absolute(String value, String label) {
  if (value.trim().isEmpty) {
    throw DubbingMixInputException('$label不能为空。');
  }
  return p.normalize(p.absolute(value));
}

bool _samePath(String? left, String? right) =>
    left != null && right != null && p.equals(left, right);

bool _isSourceAudio(String path) =>
    p.basename(path).toLowerCase() == 'source.mp3' &&
    p.basename(p.dirname(path)).toLowerCase() == 'original';

bool _isConfirmedBackground(String path) =>
    p.basename(path).toLowerCase() == 'background.ogg' &&
    p.basename(p.dirname(path)).toLowerCase() == 'original';

void _requireOutputExtension(String outputPath) {
  const allowed = {'.wav', '.m4a', '.ogg'};
  if (!allowed.contains(p.extension(outputPath).toLowerCase())) {
    throw const DubbingMixInputException('混音输出仅支持 .wav、.m4a 或 .ogg。');
  }
}
