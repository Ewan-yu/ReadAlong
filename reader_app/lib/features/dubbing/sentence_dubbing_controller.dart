import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/recording/recording_preparation.dart';
import '../../services/audio/dubbing_mix_service.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_player.dart';
import '../reader/original_audio_repository.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import '../reader/timeline_lyrics.dart';
import 'dubbing_repository.dart';

const sentenceDubbingMaximumDemonstrationPreroll = Duration(milliseconds: 900);
const sentenceDubbingDemonstrationTail = Duration(milliseconds: 650);
const sentenceDubbingMinimumGapPadding = Duration(milliseconds: 350);

/// Microphone capture can briefly reroute Android audio. Tests override this
/// to zero; production waits before play so the first spoken sound is audible.
final sentenceDubbingPlaybackSettleProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 350),
);

/// Android's media position can reach the last decoded frame before it has
/// reached the speaker, especially just after microphone routing changes.
/// Keep the output path alive briefly before switching into recording.
final sentenceDubbingDemonstrationOutputDrainProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 350),
);

enum SentenceDubbingPhase {
  ready,
  demonstrating,
  preparing,
  countdown,
  recording,
  scoring,
  result,
  mixing,
  restarting,
  failed,
}

final class SentenceDubbingState {
  const SentenceDubbingState({
    required this.project,
    required this.original,
    required this.sentenceIndex,
    required this.takes,
    required this.mixes,
    required this.completedSentenceCount,
    this.phase = SentenceDubbingPhase.ready,
    this.level = 0,
    this.elapsed = Duration.zero,
    this.countdown = 0,
    this.playbackPosition = Duration.zero,
    this.activeWordIndex,
    this.result,
    this.failure,
    this.lastGeneratedMixId,
  });

  final DubbingProject project;
  final OriginalAudioBook original;
  final int sentenceIndex;
  final List<DubbingTake> takes;
  final List<DubbingMix> mixes;
  final int completedSentenceCount;
  final SentenceDubbingPhase phase;
  final double level;
  final Duration elapsed;
  final int countdown;
  final Duration playbackPosition;
  final int? activeWordIndex;
  final ScoreResult? result;
  final String? failure;
  final String? lastGeneratedMixId;

  OriginalAudioSentence get sentence => original.sentences[sentenceIndex];
  bool get isRecording => phase == SentenceDubbingPhase.recording;
  bool get isBusy =>
      isRecording ||
      phase == SentenceDubbingPhase.demonstrating ||
      phase == SentenceDubbingPhase.preparing ||
      phase == SentenceDubbingPhase.countdown ||
      phase == SentenceDubbingPhase.scoring ||
      phase == SentenceDubbingPhase.mixing ||
      phase == SentenceDubbingPhase.restarting;

  /// Keep recording available after several attempts. The page exposes a
  /// direct per-take delete action, while Settings remains for parent cleanup.
  bool get canRecord => !isBusy;
  bool get canGoPrevious => !isBusy && sentenceIndex > 0;
  bool get canGoNext =>
      !isBusy && sentenceIndex + 1 < original.sentences.length;
  bool get canCreateMix => completedSentenceCount == original.sentences.length;
  bool get hasSelectedTake => takes.any((take) => take.isSelected);

  SentenceDubbingState copyWith({
    int? sentenceIndex,
    List<DubbingTake>? takes,
    List<DubbingMix>? mixes,
    int? completedSentenceCount,
    SentenceDubbingPhase? phase,
    double? level,
    Duration? elapsed,
    int? countdown,
    Duration? playbackPosition,
    Object? activeWordIndex = _dubbingUnset,
    Object? result = _dubbingUnset,
    Object? failure = _dubbingUnset,
    Object? lastGeneratedMixId = _dubbingUnset,
  }) =>
      SentenceDubbingState(
        project: project,
        original: original,
        sentenceIndex: sentenceIndex ?? this.sentenceIndex,
        takes: takes ?? this.takes,
        mixes: mixes ?? this.mixes,
        completedSentenceCount:
            completedSentenceCount ?? this.completedSentenceCount,
        phase: phase ?? this.phase,
        level: level ?? this.level,
        elapsed: elapsed ?? this.elapsed,
        countdown: countdown ?? this.countdown,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        activeWordIndex: identical(activeWordIndex, _dubbingUnset)
            ? this.activeWordIndex
            : activeWordIndex as int?,
        result: identical(result, _dubbingUnset)
            ? this.result
            : result as ScoreResult?,
        failure: identical(failure, _dubbingUnset)
            ? this.failure
            : failure as String?,
        lastGeneratedMixId: identical(lastGeneratedMixId, _dubbingUnset)
            ? this.lastGeneratedMixId
            : lastGeneratedMixId as String?,
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
  late final Future<AudioRecordingService> _recorderFuture;
  AudioRecordingService? _recorder;
  late final DubbingRepository _repository;
  late final ScoringProvider _scorer;
  late final SentenceAudioPlayer _player;
  late final OriginalAudioPlayer _demonstrationPlayer;
  late final DubbingMixService _mixService;
  late final RecordingPreparationProtocol _preparation;
  late final Duration _playbackSettle;
  late final Duration _demonstrationOutputDrain;
  StreamSubscription<RecordingLevel>? _levels;
  StreamSubscription<Duration>? _demonstrationPositions;
  StreamSubscription<bool>? _demonstrationPlaying;
  Completer<void>? _demonstrationCompletion;
  Timer? _demonstrationTimeout;
  Timer? _elapsedTimer;
  Timer? _limitTimer;
  Stopwatch? _stopwatch;
  Duration _contentOffset = Duration.zero;
  String? _loadedDemonstrationPath;
  var _generation = 0;
  var _starting = false;
  var _stopping = false;
  var _disposed = false;

  @override
  Future<SentenceDubbingState> build(String libraryId) async {
    _repository = await ref.watch(dubbingRepositoryProvider.future);
    // Microphone cleanup and native plug-in initialization can take noticeable
    // time on the first Android entry. Keep the provider alive, but do not
    // block the whole page behind it; the first record action awaits it.
    _recorderFuture = ref.watch(recordingServiceProvider.future);
    _scorer = ref.watch(scoringProvider);
    _player = ref.watch(sentenceAudioPlayerProvider);
    _demonstrationPlayer = ref.watch(originalAudioPlayerProvider);
    _mixService = ref.watch(dubbingMixServiceProvider);
    _preparation = ref.watch(sentenceDubbingPreparationProtocolProvider);
    _playbackSettle = ref.watch(sentenceDubbingPlaybackSettleProvider);
    _demonstrationOutputDrain =
        ref.watch(sentenceDubbingDemonstrationOutputDrainProvider);
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
    final allTakes = await _repository.listTakes(project.id);
    final completed = _completedSentenceIds(allTakes);
    final initialIndex = original.sentences.indexWhere(
      (sentence) => !completed.contains(sentence.id),
    );
    final sentenceIndex = initialIndex < 0 ? 0 : initialIndex;
    final takes = allTakes
        .where(
            (take) => take.sentenceId == original.sentences[sentenceIndex].id)
        .toList(growable: false);
    final mixes = await _repository.listMixes(project.id);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelAndStop());
    });
    return SentenceDubbingState(
        project: project,
        original: original,
        sentenceIndex: sentenceIndex,
        takes: takes,
        mixes: mixes,
        completedSentenceCount: completed.length,
        phase: _restingPhase(takes),
        result: _selectedTakeScore(takes));
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
    final allTakes = await _repository.listTakes(current.project.id);
    _set(current.copyWith(
        sentenceIndex: index,
        takes: takes,
        completedSentenceCount: _completedSentenceIds(allTakes).length,
        phase: _restingPhase(takes),
        level: 0,
        elapsed: Duration.zero,
        countdown: 0,
        playbackPosition: Duration.zero,
        activeWordIndex: null,
        result: _selectedTakeScore(takes),
        failure: null));
  }

  Future<void> startRecording() async {
    final current = state.valueOrNull;
    if (current == null || !current.canRecord || _starting) return;
    _starting = true;
    final generation = ++_generation;
    var recorderStarted = false;
    try {
      await _player.stop();
      await _cancelDemonstration();
      if (!_isCurrent(generation)) return;
      final demonstration = _demonstrationBounds(current);
      await _prepareDemonstration(
        current.original.audioPath,
        demonstration.start,
      );
      if (!_isCurrent(generation)) return;
      _set(current.copyWith(
        phase: SentenceDubbingPhase.demonstrating,
        playbackPosition: Duration.zero,
        activeWordIndex: null,
        result: null,
        failure: null,
      ));
      // Capture begins before the demonstration. The discarded demonstration
      // period doubles as Android microphone warm-up, removing the repeated
      // 650ms + 3-2-1 wait without keeping a global microphone open.
      final recorder = _recorder ??= await _recorderFuture;
      if (!_isCurrent(generation)) return;
      final session = await recorder.start(
        libraryId: arg,
        sentenceId: current.sentence.id,
      );
      recorderStarted = true;
      final captureClock = Stopwatch()..start();
      if (!_isCurrent(generation)) {
        await recorder.cancel();
        return;
      }
      if (_playbackSettle > Duration.zero) {
        await Future<void>.delayed(_playbackSettle);
        if (!_isCurrent(generation)) {
          await recorder.cancel();
          return;
        }
      }
      await _playDemonstration(current, generation, demonstration);
      if (!_isCurrent(generation)) return;
      _set(current.copyWith(
        phase: SentenceDubbingPhase.preparing,
        countdown: 0,
        playbackPosition: Duration.zero,
        activeWordIndex: null,
        result: null,
        failure: null,
      ));
      await _preparation.run(
        isActive: () => _isCurrent(generation),
        onUpdate: (update) {
          final latest = state.valueOrNull;
          if (!_isCurrent(generation) || latest == null) return;
          _set(latest.copyWith(
            phase: update.stage == RecordingPreparationStage.stabilizing
                ? SentenceDubbingPhase.preparing
                : SentenceDubbingPhase.countdown,
            countdown: update.countdown,
          ));
        },
      );
      if (!_isCurrent(generation)) {
        await recorder.cancel();
        return;
      }
      captureClock.stop();
      _contentOffset = captureClock.elapsed;
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
          countdown: 0,
          playbackPosition: Duration.zero,
          activeWordIndex: null,
          result: null,
          failure: null));
    } on RecordingPreparationCancelled {
      try {
        await _recorder?.cancel();
      } on Object {}
    } on RecordingException catch (error) {
      if (recorderStarted) {
        try {
          await _recorder?.cancel();
        } on Object {}
      }
      if (_isCurrent(generation)) _fail(error.message);
    } on Object {
      if (recorderStarted) {
        try {
          await _recorder?.cancel();
        } on Object {}
      }
      if (_isCurrent(generation)) _fail('录音没有开始，请稍后重试');
    } finally {
      _starting = false;
    }
  }

  Future<void> cancelPreparation() async {
    final current = state.valueOrNull;
    if (current == null ||
        (current.phase != SentenceDubbingPhase.preparing &&
            current.phase != SentenceDubbingPhase.countdown)) {
      return;
    }
    ++_generation;
    await _recorder?.cancel();
    _set(current.copyWith(
      phase: _restingPhase(current.takes),
      countdown: 0,
      level: 0,
      result: _selectedTakeScore(current.takes),
      failure: null,
    ));
  }

  Future<void> handleAppBackgrounded() async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.phase == SentenceDubbingPhase.preparing ||
        current.phase == SentenceDubbingPhase.countdown) {
      await cancelPreparation();
      return;
    }
    if (current.isRecording) {
      await stopRecording();
      final latest = state.valueOrNull;
      if (latest != null && latest.phase != SentenceDubbingPhase.failed) {
        _set(latest.copyWith(
          failure: '应用刚才暂停了，这一句已经安全保存。',
        ));
      }
      return;
    }
    if (current.phase == SentenceDubbingPhase.demonstrating) {
      ++_generation;
      await _cancelDemonstration();
      try {
        await _recorder?.cancel();
      } on Object {}
      _set(current.copyWith(
        phase: _restingPhase(current.takes),
        activeWordIndex: null,
        playbackPosition: Duration.zero,
        result: _selectedTakeScore(current.takes),
      ));
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
      final recorder = _recorder;
      if (recorder == null) {
        throw const RecordingException('录音服务尚未准备好，请再试一次');
      }
      final path = await recorder.stop();
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
        contentOffset: _contentOffset,
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
      final contentPcm = pcm16SliceFromOffset(pcm, take.contentOffset);
      final result = await _scorer.score(pcm16k: contentPcm, refText: text);
      await _repository.updateTakeScore(
          takeId: take.id,
          status: DubbingTakeScoreStatus.scored,
          scoreJson: _scoreJson(result));
      if (!_isCurrent(generation)) return;
      await _repository.selectTake(take.id);
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
    final allTakes = await _repository.listTakes(current.project.id);
    final completedCount = _completedSentenceIds(allTakes).length;
    if (failure != null) {
      _set(current.copyWith(
          takes: takes,
          completedSentenceCount: completedCount,
          phase: SentenceDubbingPhase.failed,
          result: null,
          failure: failure));
    } else {
      final restoredResult = result ?? _selectedTakeScore(takes);
      _set(current.copyWith(
          takes: takes,
          completedSentenceCount: completedCount,
          phase: _restingPhase(takes),
          result: restoredResult,
          failure: null));
    }
  }

  Future<void> selectTake(String takeId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.selectTake(takeId);
    await _refreshAfterScore();
  }

  Future<void> continueToNextSentence() async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final allTakes = await _repository.listTakes(current.project.id);
    final completed = _completedSentenceIds(allTakes);
    final nextIndex = current.original.sentences.indexWhere(
      (sentence) => !completed.contains(sentence.id),
    );
    if (nextIndex >= 0) {
      await _selectSentence(nextIndex);
      return;
    }
    _set(current.copyWith(
      phase: _restingPhase(current.takes),
      completedSentenceCount: completed.length,
      result: _selectedTakeScore(current.takes),
      failure: null,
    ));
  }

  /// The result screen's primary action advances and immediately starts the
  /// next listen-and-record cycle. The child no longer needs a separate
  /// "next" tap followed by another "start" tap for every sentence.
  Future<void> continueAndStartNextSentence() async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final previousSentenceId = current.sentence.id;
    await continueToNextSentence();
    final next = state.valueOrNull;
    if (next != null &&
        next.sentence.id != previousSentenceId &&
        next.canRecord) {
      await startRecording();
    }
  }

  Future<void> deleteTake(String takeId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.deleteTake(takeId);
    final remaining = await _repository.listTakes(
      current.project.id,
      sentenceId: current.sentence.id,
    );
    // Deleting the selected version must not leave a non-empty sentence in an
    // ambiguous state. Keep the newest remaining take selected so the child's
    // progress and the result actions remain intact.
    if (remaining.isNotEmpty && !remaining.any((take) => take.isSelected)) {
      await _repository.selectTake(remaining.first.id);
    }
    await _refreshAfterScore();
  }

  Future<bool> playTake(DubbingTake take) async {
    try {
      await _player.stop();
      await _player.play(SentenceAudioClip(
          path: _repository.resolveAudioPath(take),
          start: take.contentOffset,
          end: take.contentOffset + take.duration));
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
    if (!current.canCreateMix) {
      _fail('每一句都完成后，就可以生成故事作品。');
      return;
    }
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
      final mix = await _repository.saveMix(
        output: output,
        variant: result.variant,
        sourceTakeFingerprint: plan.sourceTakeFingerprint,
        duration: result.duration,
      );
      await _refreshMixes(createdMixId: mix.id);
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

  /// Starts the whole story over without making the latest finished work
  /// disappear by accident. The UI asks whether that latest mix is kept.
  Future<void> restartStory({required bool keepMixes}) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy || !current.canCreateMix) return;

    // Invalidate any late audio/scoring callback before deleting its files.
    ++_generation;
    _set(current.copyWith(
      phase: SentenceDubbingPhase.restarting,
      level: 0,
      elapsed: Duration.zero,
      countdown: 0,
      playbackPosition: Duration.zero,
      activeWordIndex: null,
      result: null,
      failure: null,
    ));
    try {
      await _cancelAndStop();
      final takes = await _repository.listTakes(current.project.id);
      for (final take in takes) {
        await _repository.deleteTake(take.id);
      }
      final mixes = await _repository.listMixes(current.project.id);
      if (keepMixes && mixes.length > 1) {
        // The reader displays the most recently generated story. Retaining
        // only that one avoids silently accumulating obsolete versions.
        final latest = mixes.reduce((latest, candidate) =>
            candidate.createdAt.isAfter(latest.createdAt) ? candidate : latest);
        for (final mix in mixes.where((mix) => mix.id != latest.id)) {
          await _repository.deleteMix(mix.id);
        }
      } else if (!keepMixes) {
        for (final mix in mixes) {
          await _repository.deleteMix(mix.id);
        }
      }
      if (!_isCurrent(_generation)) return;
      final remainingMixes = await _repository.listMixes(current.project.id);
      _set(current.copyWith(
        sentenceIndex: 0,
        takes: const [],
        mixes: remainingMixes,
        completedSentenceCount: 0,
        phase: SentenceDubbingPhase.ready,
        level: 0,
        elapsed: Duration.zero,
        countdown: 0,
        playbackPosition: Duration.zero,
        activeWordIndex: null,
        result: null,
        failure: null,
        lastGeneratedMixId: null,
      ));
    } on Object {
      // A file/database failure can happen part-way through a deletion. Never
      // pretend the old recordings are gone: reload the durable state and
      // leave the user on the first unfinished sentence.
      await _restoreAfterRestartFailure(current);
    }
  }

  Future<void> _restoreAfterRestartFailure(
      SentenceDubbingState previous) async {
    try {
      final allTakes = await _repository.listTakes(previous.project.id);
      final completed = _completedSentenceIds(allTakes);
      final firstUnfinished = previous.original.sentences.indexWhere(
        (sentence) => !completed.contains(sentence.id),
      );
      final sentenceIndex = firstUnfinished < 0 ? 0 : firstUnfinished;
      final takes = allTakes
          .where((take) =>
              take.sentenceId == previous.original.sentences[sentenceIndex].id)
          .toList(growable: false);
      final mixes = await _repository.listMixes(previous.project.id);
      _set(previous.copyWith(
        sentenceIndex: sentenceIndex,
        takes: takes,
        mixes: mixes,
        completedSentenceCount: completed.length,
        phase: SentenceDubbingPhase.failed,
        level: 0,
        elapsed: Duration.zero,
        countdown: 0,
        playbackPosition: Duration.zero,
        activeWordIndex: null,
        result: _selectedTakeScore(takes),
        failure: '没有完全清除录音，请稍后再试；现有内容已保留。',
        lastGeneratedMixId: null,
      ));
    } on Object {
      // The state is still truthful about the attempted operation and remains
      // non-busy, so the user can leave and safely reopen the project.
      _set(previous.copyWith(
        phase: SentenceDubbingPhase.failed,
        failure: '没有完全清除录音，请稍后再试；现有内容已保留。',
        lastGeneratedMixId: null,
      ));
    }
  }

  Future<void> _refreshMixes({String? createdMixId}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final mixes = await _repository.listMixes(current.project.id);
    _set(current.copyWith(
      mixes: mixes,
      phase: _restingPhase(current.takes),
      result: _selectedTakeScore(current.takes),
      failure: null,
      lastGeneratedMixId: createdMixId,
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
    await _cancelDemonstration();
    try {
      await _recorder?.cancel();
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

  /// Plays a sentence from the full original track and drives highlighting
  /// with that player's absolute position. This is deliberately the same
  /// clock used by the accurate whole-story preview; a clipped source reports
  /// a relative Android position whose output timing can drift ahead of sound.
  Future<void> _playDemonstration(
    SentenceDubbingState current,
    int generation,
    _DemonstrationBounds bounds,
  ) async {
    final sentenceStart = current.sentence.start;
    final sentenceEnd = current.sentence.end;
    if (sentenceEnd <= sentenceStart || bounds.end <= bounds.start) {
      throw const _SentenceDemonstrationException('示范音时间范围无效');
    }
    if (!_isCurrent(generation)) return;

    final completion = Completer<void>();
    _demonstrationCompletion = completion;
    var heardPlaying = false;
    var lastPosition = bounds.start;
    var terminalReached = false;

    void complete() {
      if (!completion.isCompleted) completion.complete();
    }

    void completeAfterOutputDrain() {
      if (terminalReached || completion.isCompleted) return;
      terminalReached = true;
      unawaited(Future<void>.delayed(_demonstrationOutputDrain).then((_) {
        if (_isCurrent(generation)) complete();
      }));
    }

    void fail(Object error, StackTrace stackTrace) {
      if (!completion.isCompleted) completion.completeError(error, stackTrace);
    }

    _demonstrationPositions = _demonstrationPlayer.positionStream.listen(
      (absolutePosition) {
        lastPosition = absolutePosition;
        if (!_isCurrent(generation)) {
          complete();
          return;
        }
        if (absolutePosition >= bounds.end) {
          final latest = state.valueOrNull;
          if (latest?.phase == SentenceDubbingPhase.demonstrating) {
            _set(latest!.copyWith(
              playbackPosition: sentenceEnd - sentenceStart,
              activeWordIndex: null,
            ));
          }
          completeAfterOutputDrain();
          return;
        }
        if (absolutePosition < sentenceStart) {
          final latest = state.valueOrNull;
          if (latest?.phase == SentenceDubbingPhase.demonstrating) {
            _set(latest!.copyWith(
              playbackPosition: Duration.zero,
              activeWordIndex: null,
            ));
          }
          return;
        }
        final latest = state.valueOrNull;
        if (latest?.phase != SentenceDubbingPhase.demonstrating) return;
        final sentencePosition =
            absolutePosition > sentenceEnd ? sentenceEnd : absolutePosition;
        _set(latest!.copyWith(
          playbackPosition: sentencePosition - sentenceStart,
          activeWordIndex:
              timelineActiveWordIndex(current.sentence, absolutePosition),
        ));
      },
      onError: fail,
    );
    _demonstrationPlaying = _demonstrationPlayer.playingStream.listen(
      (playing) {
        if (playing) {
          heardPlaying = true;
        } else if (heardPlaying) {
          if (lastPosition >= bounds.end - const Duration(milliseconds: 120)) {
            completeAfterOutputDrain();
          } else {
            fail(
              const _SentenceDemonstrationException('示范音播放被中断'),
              StackTrace.current,
            );
          }
        }
      },
      onError: fail,
    );
    final maximumWait = bounds.end - bounds.start + const Duration(seconds: 3);
    _demonstrationTimeout = Timer(maximumWait, () {
      if (!completion.isCompleted) {
        completion.completeError(
          const _SentenceDemonstrationException('示范音播放超时'),
        );
      }
    });
    unawaited(
      _demonstrationPlayer.play().then<void>(
        (_) async {
          // The position stream reaches listeners asynchronously. Give its
          // final event one turn before interpreting a returned play Future.
          await Future<void>.delayed(Duration.zero);
          if (lastPosition >= bounds.end - const Duration(milliseconds: 120)) {
            completeAfterOutputDrain();
          } else {
            fail(
              const _SentenceDemonstrationException('示范音播放被中断'),
              StackTrace.current,
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) =>
            fail(error, stackTrace),
      ),
    );
    try {
      await completion.future;
    } finally {
      await _clearDemonstrationListeners();
      try {
        await _demonstrationPlayer.pause();
      } on Object {
        // Decoder cleanup below or the next command can still recover.
      }
    }
  }

  Future<void> _prepareDemonstration(String path, Duration start) async {
    if (_loadedDemonstrationPath != path) {
      await _demonstrationPlayer.load(path);
      _loadedDemonstrationPath = path;
    }
    await _demonstrationPlayer.setVolume(1);
    await _demonstrationPlayer.seek(start);
  }

  _DemonstrationBounds _demonstrationBounds(SentenceDubbingState current) {
    final index = current.sentenceIndex;
    final sentence = current.sentence;
    var start = sentence.start;
    if (index > 0) {
      final previousEnd = current.original.sentences[index - 1].end;
      final availableGap = sentence.start - previousEnd;
      if (availableGap >= sentenceDubbingMinimumGapPadding) {
        final preroll =
            availableGap < sentenceDubbingMaximumDemonstrationPreroll
                ? availableGap
                : sentenceDubbingMaximumDemonstrationPreroll;
        start = sentence.start - preroll;
      }
    }

    final availableAfter = current.original.duration - sentence.end;
    var tail = availableAfter < sentenceDubbingDemonstrationTail
        ? availableAfter
        : sentenceDubbingDemonstrationTail;
    if (index + 1 < current.original.sentences.length) {
      final gapToNext =
          current.original.sentences[index + 1].start - sentence.end;
      if (gapToNext > Duration.zero && gapToNext < tail) {
        tail = gapToNext;
      } else if (gapToNext <= Duration.zero &&
          sentenceDubbingMinimumGapPadding < tail) {
        tail = sentenceDubbingMinimumGapPadding;
      }
    }
    if (tail < Duration.zero) tail = Duration.zero;
    return _DemonstrationBounds(start: start, end: sentence.end + tail);
  }

  Future<void> _cancelDemonstration() async {
    final completion = _demonstrationCompletion;
    if (completion != null && !completion.isCompleted) completion.complete();
    await _clearDemonstrationListeners();
    try {
      await _demonstrationPlayer.stop();
    } on Object {
      // A stale demonstration must never block recording or route teardown.
    }
  }

  Future<void> _clearDemonstrationListeners() async {
    _demonstrationTimeout?.cancel();
    _demonstrationTimeout = null;
    await _demonstrationPositions?.cancel();
    _demonstrationPositions = null;
    await _demonstrationPlaying?.cancel();
    _demonstrationPlaying = null;
    _demonstrationCompletion = null;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
  void _set(SentenceDubbingState value) {
    if (!_disposed) state = AsyncData(value);
  }
}

final class _SentenceDemonstrationException implements Exception {
  const _SentenceDemonstrationException(this.message);

  final String message;
}

final class _DemonstrationBounds {
  const _DemonstrationBounds({required this.start, required this.end});

  final Duration start;
  final Duration end;
}

Set<String> _completedSentenceIds(List<DubbingTake> takes) => {
      for (final take in takes)
        if (take.takeKind == DubbingTakeKind.sentence &&
            take.isSelected &&
            take.sentenceId != null)
          take.sentenceId!,
    };

SentenceDubbingPhase _restingPhase(List<DubbingTake> takes) =>
    takes.isEmpty ? SentenceDubbingPhase.ready : SentenceDubbingPhase.result;

ScoreResult? _selectedTakeScore(List<DubbingTake> takes) {
  DubbingTake? selected;
  for (final take in takes) {
    if (take.isSelected) {
      selected = take;
      break;
    }
  }
  final raw = selected?.scoreJson;
  if (raw == null) return null;
  try {
    final value = jsonDecode(raw) as Map<String, dynamic>;
    return ScoreResult(
      childScore: (value['child_score'] as num).toDouble(),
      provider: value['provider'] as String? ?? 'saved',
    );
  } on Object {
    return null;
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
