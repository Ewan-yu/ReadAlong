import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_repository.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import 'dubbing_repository.dart';

const sentenceDubbingMaximumTakes = 3;

enum SentenceDubbingPhase { ready, recording, scoring, failed }

final class SentenceDubbingState {
  const SentenceDubbingState({
    required this.project,
    required this.original,
    required this.sentenceIndex,
    required this.takes,
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
  final SentenceDubbingPhase phase;
  final double level;
  final Duration elapsed;
  final ScoreResult? result;
  final String? failure;

  OriginalAudioSentence get sentence => original.sentences[sentenceIndex];
  bool get isRecording => phase == SentenceDubbingPhase.recording;
  bool get isBusy => isRecording || phase == SentenceDubbingPhase.scoring;
  bool get canRecord => !isBusy && takes.length < sentenceDubbingMaximumTakes;
  bool get canGoPrevious => !isBusy && sentenceIndex > 0;
  bool get canGoNext =>
      !isBusy && sentenceIndex + 1 < original.sentences.length;

  SentenceDubbingState copyWith({
    int? sentenceIndex,
    List<DubbingTake>? takes,
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
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelAndStop());
    });
    return SentenceDubbingState(
        project: project, original: original, sentenceIndex: 0, takes: takes);
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
