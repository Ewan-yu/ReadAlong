import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../data/appdb/dubbing_models.dart';

/// The background is intentionally quieter than a child's narration.
const double defaultDubbingBackgroundGainDb = -18;
const double _minimumBackgroundGainDb = -36;
const double _maximumBackgroundGainDb = -6;

enum DubbingMixMode { voiceOnly, withConfirmedBackground }

/// A selected, durable sentence Take placed on the original-audio timeline.
final class DubbingMixSentenceTake {
  const DubbingMixSentenceTake({
    required this.sentenceId,
    required this.sequence,
    required this.start,
    required this.end,
    required this.take,
    required this.audioPath,
  });

  final String sentenceId;
  final int sequence;
  final Duration start;
  final Duration end;
  final DubbingTake take;
  final String audioPath;
}

/// A validated, declarative request.  It never has `source.mp3` as an input.
///
/// Sentence recordings are intentionally not cut to a reference sentence
/// window.  Their complete duration is retained and the rendered work grows
/// when needed, which is safer than cutting off a child mid-sentence.
final class DubbingMixPlan {
  DubbingMixPlan._({
    required this.mode,
    required List<DubbingMixSentenceTake> sentenceTakes,
    required this.outputPath,
    required this.backgroundPath,
    required this.backgroundGainDb,
    required this.timelineDuration,
    required this.renderDuration,
  }) : sentenceTakes = List.unmodifiable(sentenceTakes);

  factory DubbingMixPlan.create({
    required List<DubbingMixSentenceTake> sentenceTakes,
    required String outputPath,
    required DubbingMixMode mode,
    required Duration timelineDuration,
    String? confirmedBackgroundPath,
    String? originalSourcePath,
    double backgroundGainDb = defaultDubbingBackgroundGainDb,
  }) {
    if (sentenceTakes.isEmpty) {
      throw const DubbingMixInputException('请先为至少一句选择一个配音版本。');
    }
    if (timelineDuration <= Duration.zero) {
      throw const DubbingMixInputException('原音时间轴时长无效。');
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
    _validateBackground(
      mode: mode,
      background: normalizedBackground,
      source: normalizedSource,
      output: normalizedOutput,
    );

    final seenSentenceIds = <String>{};
    final seenSequences = <int>{};
    final normalizedTakes = <DubbingMixSentenceTake>[];
    var renderDuration = timelineDuration;
    for (final entry in sentenceTakes) {
      if (entry.sentenceId.isEmpty ||
          entry.sentenceId != entry.take.sentenceId ||
          entry.sequence < 1 ||
          entry.start < Duration.zero ||
          entry.end <= entry.start ||
          entry.end > timelineDuration ||
          !seenSentenceIds.add(entry.sentenceId) ||
          !seenSequences.add(entry.sequence)) {
        throw const DubbingMixInputException('每句只能选用一个有效的配音版本。');
      }
      if (entry.take.takeKind != DubbingTakeKind.sentence ||
          !entry.take.isSelected) {
        throw const DubbingMixInputException('只能混入已选用的逐句 Take。');
      }
      final path = _validateVoicePath(
        entry.audioPath,
        output: normalizedOutput,
        background: normalizedBackground,
        source: normalizedSource,
      );
      final takeEnd = entry.start + entry.take.duration;
      if (takeEnd > renderDuration) renderDuration = takeEnd;
      normalizedTakes.add(DubbingMixSentenceTake(
        sentenceId: entry.sentenceId,
        sequence: entry.sequence,
        start: entry.start,
        end: entry.end,
        take: entry.take,
        audioPath: path,
      ));
    }
    normalizedTakes
        .sort((left, right) => left.sequence.compareTo(right.sequence));
    return DubbingMixPlan._(
      mode: mode,
      sentenceTakes: normalizedTakes,
      outputPath: normalizedOutput,
      backgroundPath: normalizedBackground,
      backgroundGainDb: backgroundGainDb,
      timelineDuration: timelineDuration,
      renderDuration: renderDuration,
    );
  }

  /// Converts one continuous full-book Take into the same safe renderer.
  factory DubbingMixPlan.forFullTake({
    required DubbingTake take,
    required String audioPath,
    required String outputPath,
    required DubbingMixMode mode,
    required Duration timelineDuration,
    String? confirmedBackgroundPath,
    String? originalSourcePath,
    double backgroundGainDb = defaultDubbingBackgroundGainDb,
  }) {
    if (take.takeKind != DubbingTakeKind.full || !take.isSelected) {
      throw const DubbingMixInputException('只能混入已选用的完整录音。');
    }
    // A synthetic sentence entry lets both modes share exactly one command
    // builder without permitting a full Take in a sentence project.
    return DubbingMixPlan.create(
      sentenceTakes: [
        DubbingMixSentenceTake(
          sentenceId: '__full_take__',
          sequence: 1,
          start: Duration.zero,
          end: timelineDuration,
          take: DubbingTake(
            id: take.id,
            projectId: take.projectId,
            sentenceId: '__full_take__',
            takeKind: DubbingTakeKind.sentence,
            audioRelativePath: take.audioRelativePath,
            duration: take.duration,
            isSelected: true,
            scoreStatus: take.scoreStatus,
            createdAt: take.createdAt,
          ),
          audioPath: audioPath,
        ),
      ],
      outputPath: outputPath,
      mode: mode,
      timelineDuration: timelineDuration,
      confirmedBackgroundPath: confirmedBackgroundPath,
      originalSourcePath: originalSourcePath,
      backgroundGainDb: backgroundGainDb,
    );
  }

  final DubbingMixMode mode;
  final List<DubbingMixSentenceTake> sentenceTakes;
  final String outputPath;
  final String? backgroundPath;
  final double backgroundGainDb;
  final Duration timelineDuration;
  final Duration renderDuration;

  bool get usesConfirmedBackground =>
      mode == DubbingMixMode.withConfirmedBackground;

  String get sourceTakeFingerprint => sentenceTakes
      .map((entry) => '${entry.take.id}@${entry.start.inMilliseconds}')
      .join(',');
}

abstract interface class DubbingMixService {
  Future<DubbingMixResult> render(DubbingMixPlan plan);
}

final class DubbingMixResult {
  const DubbingMixResult({
    required this.outputPath,
    required this.mode,
    required this.duration,
  });

  final String outputPath;
  final DubbingMixMode mode;
  final Duration duration;

  DubbingMixVariant get variant =>
      mode == DubbingMixMode.withConfirmedBackground
          ? DubbingMixVariant.background
          : DubbingMixVariant.voiceOnly;
}

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

final class DubbingMixRenderException implements Exception {
  const DubbingMixRenderException(this.message);
  final String message;
  @override
  String toString() => 'DubbingMixRenderException: $message';
}

final class DubbingMixCommandResult {
  const DubbingMixCommandResult({required this.success, this.output = ''});
  final bool success;
  final String output;
}

abstract interface class DubbingMixCommandExecutor {
  Future<DubbingMixCommandResult> execute(String command);
}

/// The reviewed LGPL package is kept behind this tiny adapter so it can be
/// replaced without changing a product rule or its tests.
final class FfmpegKitCommandExecutor implements DubbingMixCommandExecutor {
  const FfmpegKitCommandExecutor();

  @override
  Future<DubbingMixCommandResult> execute(String command) async {
    final session = await FFmpegKit.execute(command);
    final code = await session.getReturnCode();
    return DubbingMixCommandResult(
      success: ReturnCode.isSuccess(code),
      output: await session.getOutput() ?? '',
    );
  }
}

final dubbingMixServiceProvider = Provider<DubbingMixService>(
  (_) => const FfmpegKitDubbingMixService(),
);

/// Android/iOS offline renderer. It writes to a same-directory `.part` file
/// and renames only after FFmpeg returns success and the file is non-empty.
final class FfmpegKitDubbingMixService implements DubbingMixService {
  const FfmpegKitDubbingMixService({
    DubbingMixCommandExecutor? executor,
  }) : _executor = executor ?? const FfmpegKitCommandExecutor();

  final DubbingMixCommandExecutor _executor;

  @override
  Future<DubbingMixResult> render(DubbingMixPlan plan) async {
    final target = File(plan.outputPath);
    final temporary = File(_temporaryOutputPath(plan.outputPath));
    try {
      await _checkReadableInputs(plan);
      if (await target.exists()) {
        throw const DubbingMixRenderException('作品文件已存在，请重新生成。');
      }
      await target.parent.create(recursive: true);
      if (await temporary.exists()) await temporary.delete();
      final result =
          await _executor.execute(_buildCommand(plan, temporary.path));
      if (!result.success) {
        throw DubbingMixRenderException(_failureMessage(result.output));
      }
      if (!await temporary.exists() || await temporary.length() == 0) {
        throw const DubbingMixRenderException('混音没有生成有效作品文件。');
      }
      if (await target.exists()) {
        throw const DubbingMixRenderException('作品文件已存在，请重新生成。');
      }
      await temporary.rename(target.path);
      return DubbingMixResult(
        outputPath: target.path,
        mode: plan.mode,
        duration: plan.renderDuration,
      );
    } finally {
      if (await temporary.exists()) {
        try {
          await temporary.delete();
        } on Object {}
      }
    }
  }

  static String buildCommandForTest(
          DubbingMixPlan plan, String temporaryPath) =>
      _buildCommand(plan, temporaryPath);

  static String _buildCommand(DubbingMixPlan plan, String temporaryPath) {
    final inputs = <String>[];
    var inputIndex = 0;
    if (plan.usesConfirmedBackground) {
      inputs.add("-stream_loop -1 -i ${_quote(plan.backgroundPath!)}");
      inputIndex = 1;
    }
    for (final take in plan.sentenceTakes) {
      inputs.add('-i ${_quote(take.audioPath)}');
    }
    final filters = <String>[];
    if (plan.usesConfirmedBackground) {
      filters.add(
        '[0:a]aresample=48000,volume=${_dbToLinear(plan.backgroundGainDb)},'
        'atrim=duration=${_seconds(plan.renderDuration)},asetpts=N/SR/TB[bed]',
      );
    } else {
      filters.add(
        'anullsrc=channel_layout=stereo:sample_rate=48000,'
        'atrim=duration=${_seconds(plan.renderDuration)},asetpts=N/SR/TB[bed]',
      );
    }
    final labels = <String>['[bed]'];
    for (var index = 0; index < plan.sentenceTakes.length; index++) {
      final take = plan.sentenceTakes[index];
      final delay = take.start.inMilliseconds;
      final sourceIndex = inputIndex + index;
      final label = 'voice$index';
      filters.add(
        '[$sourceIndex:a]aresample=48000,adelay=$delay:all=1,asetpts=N/SR/TB[$label]',
      );
      labels.add('[$label]');
    }
    filters.add(
      '${labels.join()}amix=inputs=${labels.length}:duration=first:normalize=0:'
      'dropout_transition=0,loudnorm=I=-16:TP=-1:LRA=11[mixed]',
    );
    final codec = switch (p.extension(plan.outputPath).toLowerCase()) {
      '.wav' => '-c:a pcm_s16le',
      '.ogg' => '-c:a libvorbis -q:a 5',
      _ => '-c:a aac -b:a 128k -movflags +faststart',
    };
    return '-hide_banner -nostdin -y ${inputs.join(' ')} '
        '-filter_complex ${_quote(filters.join(';'))} -map ${_quote('[mixed]')} '
        '$codec ${_quote(temporaryPath)}';
  }

  Future<void> _checkReadableInputs(DubbingMixPlan plan) async {
    for (final take in plan.sentenceTakes) {
      if (!await File(take.audioPath).exists()) {
        throw DubbingMixRenderException('找不到已选用的录音：${take.sentenceId}。');
      }
    }
    if (plan.backgroundPath case final background?) {
      if (!await File(background).exists()) {
        throw const DubbingMixRenderException('已确认的背景轨不存在，将以纯人声重新生成。');
      }
    }
  }
}

void _validateBackground({
  required DubbingMixMode mode,
  required String? background,
  required String? source,
  required String output,
}) {
  switch (mode) {
    case DubbingMixMode.voiceOnly:
      if (background != null) {
        throw const DubbingMixInputException('纯人声作品不能选择背景轨。');
      }
    case DubbingMixMode.withConfirmedBackground:
      if (background == null || !_isConfirmedBackground(background)) {
        throw const DubbingMixInputException(
            '背景版只能使用已确认导出的 original/background.ogg。');
      }
      if (_samePath(background, source) || _isSourceAudio(background)) {
        throw const DubbingMixInputException(
            '禁止把 original/source.mp3 作为背景叠加到儿童录音。');
      }
  }
  if (_samePath(output, source) || _samePath(output, background)) {
    throw const DubbingMixInputException('混音输出不能覆盖原音或背景轨。');
  }
}

String _validateVoicePath(
  String value, {
  required String output,
  required String? background,
  required String? source,
}) {
  final path = _absolute(value, '儿童录音路径');
  if (p.extension(path).toLowerCase() != '.wav') {
    throw const DubbingMixInputException('儿童录音必须是私有目录中的 WAV Take。');
  }
  if (_samePath(path, source) || _isSourceAudio(path)) {
    throw const DubbingMixInputException('儿童录音不能指向 original/source.mp3。');
  }
  if (_samePath(path, output) || _samePath(path, background)) {
    throw const DubbingMixInputException('混音输出和输入音频必须是不同文件。');
  }
  return path;
}

String _absolute(String value, String label) {
  if (value.trim().isEmpty) throw DubbingMixInputException('$label不能为空。');
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

String _temporaryOutputPath(String target) {
  final extension = p.extension(target);
  return p.join(p.dirname(target),
      '.${p.basenameWithoutExtension(target)}.part$extension');
}

String _quote(String value) => "'${value.replaceAll("'", r"'\\''")}'";
String _seconds(Duration duration) =>
    (duration.inMilliseconds / 1000).toStringAsFixed(3);
String _dbToLinear(double db) =>
    math.pow(10, db / 20).toDouble().toStringAsFixed(9);

String _failureMessage(String output) {
  final compact = output.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (compact.isEmpty) return '离线混音失败，请稍后重试。';
  return '离线混音失败：${compact.length > 240 ? compact.substring(compact.length - 240) : compact}';
}
