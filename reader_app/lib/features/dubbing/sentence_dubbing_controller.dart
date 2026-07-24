import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/audio/dubbing_mix_service.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_repository.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import 'dubbing_repository.dart';

const sentenceDubbingMaximumTakes = 3;

enum SentenceDubbingPhase { ready, recording, scoring, mixing, failed }

final class SentenceDubbingState {
  const SentenceDubbingState({
    required this.project,
    required this.original,
    required this.sentenceIndex,
    required this.takes,
    required this.mixes,
    this.phase = SentenceDubbingPhase.ready,
    this.level = 0,
    this.elapsed = Duration.zero,
    this.result,
    this.failure,
  });

  final DubbingProject project;
  final OriginalAudioBook original;
  final int sentenceIndex;
  final List<DubbingTake> takes;
  final List<DubbingMix> mixes;
  final SentenceDubbingPhase phase;
  final double level;
  final Duration elapsed;
  final ScoreResult? result;
  final String? failure;

  OriginalAudioSentence get sentence => original.sentences[sentenceIndex];
  bool get isRecording => phase == SentenceDubbingPhase.recording;
  bool get isBusy =>
      isRecording ||
      phase == SentenceDubbingPhase.scoring ||
      phase == SentenceDubbingPhase.mixing;
  bool get canRecord => !isBusy && takes.length < sentenceDubbingMaximumTakes;
  bool get canGoPrevious => !isBusy && sentenceIndex > 0;
  bool get canGoNext =>
      !isBusy && sentenceIndex + 1 < original.sentences.length;

  SentenceDubbingState copyWith({
    int? sentenceIndex,
    List<DubbingTake>? takes,
    List<DubbingMix>? mixes,
    SentenceDubbingPhase? phase,
    double? level,
    Duration? elapsed,
    Object? result = _dubbingUnset,
    Object? failure = _dubbingUnset,
  }) =>
      SentenceDubbingState(
        project: project,
        original: original,
        sentenceIndex: sentenceIndex ?? this.sentenceIndex,
        takes: takes ?? this.takes,
        mixes: mixes ?? this.mixes,
        phase: phase ?? this.phase,
        level: level ?? this.level,
        elapsed: elapsed ?? this.elapsed,
        result: identical(result, _dubbingUnset)
            ? this.result
            : result as ScoreResult?,
        failure: identical(failure, _dubbingUnset)
            ? this.failure
            : failure as String?,
      );
}

const _dubbingUnset = Object();

final sentenceDubbingControllerProvider =
    AutoDisposeAsyncNotifierProviderFamily<SentenceDubbingController,
        SentenceDubbingState, String>(
  SentenceDubbingController.new,
);

/// A durable, sentence-by-sentence recorder. The temporary WAV is copied to
/// DubbingFileStore before scoring starts, so a network score failure never
/// costs the child a take.
final class SentenceDubbingController
    extends AutoDisposeFamilyAsyncNotifier<SentenceDubbingState, String> {
  late final AudioRecordingService _recorder;
  late final DubbingRepository _repository;
  late final ScoringProvider _scorer;
  late final SentenceAudioPlayer _player;
  late final DubbingMixService _mixService;
  StreamSubscription<RecordingLevel>? _levels;
  Timer? _elapsedTimer;
  Timer? _limitTimer;
  Stopwatch? _stopwatch;
  var _generation = 0;
  var _stopping = false;
  var _disposed = false;

  @override
  Future<SentenceDubbingState> build(String libraryId) async {
    _repository = await ref.watch(dubbingRepositoryProvider.future);
    _recorder = await ref.watch(recordingServiceProvider.future);
    _scorer = ref.watch(scoringProvider);
    _player = ref.watch(sentenceAudioPlayerProvider);
    _mixService = ref.watch(dubbingMixServiceProvider);
    final original =
        await ref.watch(originalAudioBookProvider(libraryId).future);
    if (original.sourceBookId.isEmpty ||
        original.resourceSha256.isEmpty ||
        original.timelineSha256.isEmpty) {
      throw StateError('原音时间轴身份不完整，请重新导入绘本');
    }
    final projects = await _repository.listProjects(libraryId);
    final existing = projects.where((project) =>
        project.mode == DubbingMode.sentence &&
        project.status != DubbingProjectStatus.incompatible &&
        project.sourceBookId == original.sourceBookId &&
        project.resourceSha256 == original.resourceSha256 &&
        project.timelineSha256 == original.timelineSha256);
    final project = existing.isNotEmpty
        ? existing.first
        : await _repository.createProject(DubbingProjectDraft(
            libraryId: libraryId,
            sourceBookId: original.sourceBookId,
            resourceSha256: original.resourceSha256,
            timelineSha256: original.timelineSha256,
            mode: DubbingMode.sentence,
          ));
    final takes = await _repository.listTakes(project.id,
        sentenceId: original.sentences.first.id);
    final mixes = await _repository.listMixes(project.id);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelAndStop());
    });
    return SentenceDubbingState(
        project: project,
        original: original,
        sentenceIndex: 0,
        takes: takes,
        mixes: mixes);
  }

  Future<void> previousSentence() =>
      _selectSentence((state.valueOrNull?.sentenceIndex ?? 0) - 1);
  Future<void> nextSentence() =>
      _selectSentence((state.valueOrNull?.sentenceIndex ?? 0) + 1);

  Future<void> _selectSentence(int index) async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isBusy ||
        index < 0 ||
        index >= current.original.sentences.length) return;
    final takes = await _repository.listTakes(current.project.id,
        sentenceId: current.original.sentences[index].id);
    _set(current.copyWith(
        sentenceIndex: index,
        takes: takes,
        phase: SentenceDubbingPhase.ready,
        level: 0,
        elapsed: Duration.zero,
        result: null,
        failure: null));
  }

  Future<void> startRecording() async {
    final current = state.valueOrNull;
    if (current == null || !current.canRecord) return;
    final generation = ++_generation;
    try {
      await _player.stop();
      final session = await _recorder.start(
          libraryId: arg, sentenceId: current.sentence.id);
      if (!_isCurrent(generation)) {
        await _recorder.cancel();
        return;
      }
      _stopwatch = Stopwatch()..start();
      _levels = session.levels.listen((level) {
        final latest = state.valueOrNull;
        if (!_isCurrent(generation) || latest == null || !latest.isRecording)
          return;
        _set(latest.copyWith(
            level: level.value, elapsed: _stopwatch?.elapsed ?? Duration.zero));
      });
      _elapsedTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        final latest = state.valueOrNull;
        if (_isCurrent(generation) && latest?.isRecording == true) {
          _set(latest!.copyWith(elapsed: _stopwatch?.elapsed ?? Duration.zero));
        }
      });
      // A generous sentence-aware cap protects disk and a forgotten recorder.
      final reference = current.sentence.end - current.sentence.start;
      final cap = Duration(
          milliseconds:
              (reference.inMilliseconds * 3 + 3500).clamp(7000, 30000));
      _limitTimer = Timer(cap, () => unawaited(stopRecording()));
      _set(current.copyWith(
          phase: SentenceDubbingPhase.recording,
          level: 0,
          elapsed: Duration.zero,
          result: null,
          failure: null));
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _fail(error.message);
    } on Object {
      if (_isCurrent(generation)) _fail('录音没有开始，请稍后重试');
    }
  }

  Future<void> stopRecording() async {
    final current = state.valueOrNull;
    if (current == null || !current.isRecording || _stopping) return;
    _stopping = true;
    final generation = _generation;
    _stopwatch?.stop();
    try {
      _set(current.copyWith(
          phase: SentenceDubbingPhase.scoring,
          level: 0,
          elapsed: _stopwatch?.elapsed ?? current.elapsed));
      await _stopActivity();
      final path = await _recorder.stop();
      if (!_isCurrent(generation)) return;
      final duration = _stopwatch?.elapsed ?? current.elapsed;
      final take = await _repository.saveTake(
        projectId: current.project.id,
        kind: DubbingTakeKind.sentence,
        sentenceId: current.sentence.id,
        sourceAudio: File(path),
        duration: duration > Duration.zero
            ? duration
            : const Duration(milliseconds: 1),
      );
      try {
        await File(path).delete();
      } on Object {}
      await _score(take, current.sentence.text, generation);
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _fail(error.message);
    } on Object {
      if (_isCurrent(generation)) _fail('录音没有保存成功，请再试一次');
    } finally {
      _stopping = false;
    }
  }

  Future<void> retryScore(DubbingTake take) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final generation = ++_generation;
    _set(current.copyWith(phase: SentenceDubbingPhase.scoring, failure: null));
    await _score(take, current.sentence.text, generation);
  }

  Future<void> _score(DubbingTake take, String text, int generation) async {
    try {
      final pcm = parseWavPcm16(
              await File(_repository.resolveAudioPath(take)).readAsBytes())
          .pcm16k;
      final result = await _scorer.score(pcm16k: pcm, refText: text);
      await _repository.updateTakeScore(
          takeId: take.id,
          status: DubbingTakeScoreStatus.scored,
          scoreJson: _scoreJson(result));
      if (!_isCurrent(generation)) return;
      await _refreshAfterScore(result: result);
    } on ScoringException catch (error) {
      await _markScoreFailed(take, error.message, generation);
    } on RecordingException catch (error) {
      await _markScoreFailed(take, error.message, generation);
    } on Object {
      await _markScoreFailed(take, '分数马上来～录音已经保留，可以稍后重试', generation);
    }
  }

  Future<void> _markScoreFailed(
      DubbingTake take, String message, int generation) async {
    await _repository.updateTakeScore(
        takeId: take.id,
        status: DubbingTakeScoreStatus.failed,
        scoreError: message);
    if (!_isCurrent(generation)) return;
    await _refreshAfterScore(failure: message);
  }

  Future<void> _refreshAfterScore(
      {ScoreResult? result, String? failure}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final takes = await _repository.listTakes(current.project.id,
        sentenceId: current.sentence.id);
    if (failure != null) {
      _set(current.copyWith(
          takes: takes,
          phase: SentenceDubbingPhase.failed,
          result: null,
          failure: failure));
    } else {
      _set(current.copyWith(
          takes: takes,
          phase: SentenceDubbingPhase.ready,
          result: result,
          failure: null));
    }
  }

  Future<void> selectTake(String takeId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.selectTake(takeId);
    await _refreshAfterScore();
  }

  Future<void> deleteTake(String takeId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.deleteTake(takeId);
    await _refreshAfterScore();
  }

  Future<bool> playTake(DubbingTake take) async {
    try {
      await _player.stop();
      await _player.play(SentenceAudioClip(
          path: _repository.resolveAudioPath(take),
          start: Duration.zero,
          end: take.duration,
          wholeFile: true));
      return true;
    } on Object {
      return false;
    }
  }

  /// Renders only after every sentence has an explicitly selected Take.
  /// Missing confirmed background is a supported voice-only path, never a
  /// reason to read `source.mp3` into the command.
  Future<void> createMix() async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final allTakes = await _repository.listTakes(current.project.id);
    final selectedBySentence = <String, DubbingTake>{
      for (final take in allTakes)
        if (take.takeKind == DubbingTakeKind.sentence && take.isSelected)
          take.sentenceId!: take,
    };
    if (selectedBySentence.length != current.original.sentences.length) {
      _fail('每一句都选用一个录音后，才能生成完整作品。');
      return;
    }
    final output = await _repository.prepareMixOutput(current.project.id);
    final mode = current.original.backgroundPath == null
        ? DubbingMixMode.voiceOnly
        : DubbingMixMode.withConfirmedBackground;
    final entries = current.original.sentences.map((sentence) {
      final take = selectedBySentence[sentence.id]!;
      return DubbingMixSentenceTake(
        sentenceId: sentence.id,
        sequence: sentence.sequence,
        start: sentence.start,
        end: sentence.end,
        take: take,
        audioPath: _repository.resolveAudioPath(take),
      );
    }).toList(growable: false);
    final plan = DubbingMixPlan.create(
      sentenceTakes: entries,
      outputPath: output.absolutePath,
      mode: mode,
      timelineDuration: current.original.duration,
      confirmedBackgroundPath: current.original.backgroundPath,
      originalSourcePath: current.original.audioPath,
    );
    _set(current.copyWith(phase: SentenceDubbingPhase.mixing, failure: null));
    try {
      final result = await _mixService.render(plan);
      await _repository.saveMix(
        output: output,
        variant: result.variant,
        sourceTakeFingerprint: plan.sourceTakeFingerprint,
        duration: result.duration,
      );
      await _refreshMixes();
    } on DubbingMixInputException catch (error) {
      _fail(error.message);
    } on DubbingMixRenderException catch (error) {
      _fail(error.message);
    } on Object {
      _fail('作品没有生成成功，录音都还在，可以再试一次。');
    }
  }

  Future<bool> playMix(DubbingMix mix) async {
    try {
      await _player.stop();
      await _player.play(SentenceAudioClip(
        path: _repository.resolveMixAudioPath(mix),
        start: Duration.zero,
        end: mix.duration,
        wholeFile: true,
      ));
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> deleteMix(String mixId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.deleteMix(mixId);
    await _refreshMixes();
  }

  Future<void> _refreshMixes() async {
    final current = state.valueOrNull;
    if (current == null) return;
    final mixes = await _repository.listMixes(current.project.id);
    _set(current.copyWith(
      mixes: mixes,
      phase: SentenceDubbingPhase.ready,
      failure: null,
    ));
  }

  void _fail(String message) {
    final current = state.valueOrNull;
    if (current != null)
      _set(current.copyWith(
          phase: SentenceDubbingPhase.failed, level: 0, failure: message));
  }

  Future<void> _cancelAndStop() async {
    await _stopActivity();
    try {
      await _recorder.cancel();
    } on Object {}
    try {
      await _player.stop();
    } on Object {}
  }

  Future<void> _stopActivity() async {
    _limitTimer?.cancel();
    _limitTimer = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    await _levels?.cancel();
    _levels = null;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _set(SentenceDubbingState value) {
    if (!_disposed) state = AsyncData(value);
  }
}

String _scoreJson(ScoreResult score) => jsonEncode({
      'child_score': score.childScore,
      'provider': score.provider,
      'total': score.total,
      'accuracy': score.accuracy,
      'fluency': score.fluency,
      'standard': score.standard,
      'integrity': score.integrity,
      'words': score.words
          .map((word) => {'word': word.word, 'accuracy': word.accuracy})
          .toList(),
    });
