import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/recording/recording_preparation.dart';
import '../../services/audio/dubbing_mix_service.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_repository.dart';
import '../reader/original_audio_player.dart';
import 'dubbing_repository.dart';
import 'full_take_scoring.dart';

/// The continuous-recording surface deliberately stores a normal [DubbingTake]
/// with a pending score.  M5.5 can later attach sentence-range scoring data to
/// this take without moving a child's WAV or changing its project identity.
enum FullDubbingPhase {
  ready,
  preparing,
  countdown,
  recording,
  saving,
  scoring,
  mixing,
  failed
}

enum FullDubbingPlaybackKind { none, original, take, mix }

final class FullDubbingState {
  const FullDubbingState({
    required this.project,
    required this.original,
    required this.takes,
    required this.mixes,
    this.phase = FullDubbingPhase.ready,
    this.countdown = 0,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.playbackKind = FullDubbingPlaybackKind.none,
    this.playbackPosition = Duration.zero,
    this.audioPlaying = false,
    this.playbackId,
    this.failure,
  });

  final DubbingProject project;
  final OriginalAudioBook original;
  final List<DubbingTake> takes;
  final List<DubbingMix> mixes;
  final FullDubbingPhase phase;
  final int countdown;
  final Duration elapsed;
  final double level;
  final FullDubbingPlaybackKind playbackKind;
  final Duration playbackPosition;
  final bool audioPlaying;
  final String? playbackId;
  final String? failure;

  bool get isRecording => phase == FullDubbingPhase.recording;
  bool get isBusy =>
      phase == FullDubbingPhase.countdown ||
      phase == FullDubbingPhase.preparing ||
      phase == FullDubbingPhase.recording ||
      phase == FullDubbingPhase.saving ||
      phase == FullDubbingPhase.scoring ||
      phase == FullDubbingPhase.mixing;
  bool get canStart => !isBusy;
  bool get isComplete => project.status == DubbingProjectStatus.complete;
  bool get isPreviewingOriginal =>
      playbackKind == FullDubbingPlaybackKind.original;

  FullDubbingState copyWith({
    DubbingProject? project,
    List<DubbingTake>? takes,
    List<DubbingMix>? mixes,
    FullDubbingPhase? phase,
    int? countdown,
    Duration? elapsed,
    double? level,
    FullDubbingPlaybackKind? playbackKind,
    Duration? playbackPosition,
    bool? audioPlaying,
    Object? playbackId = _fullUnset,
    Object? failure = _fullUnset,
  }) =>
      FullDubbingState(
        project: project ?? this.project,
        original: original,
        takes: takes ?? this.takes,
        mixes: mixes ?? this.mixes,
        phase: phase ?? this.phase,
        countdown: countdown ?? this.countdown,
        elapsed: elapsed ?? this.elapsed,
        level: level ?? this.level,
        playbackKind: playbackKind ?? this.playbackKind,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        audioPlaying: audioPlaying ?? this.audioPlaying,
        playbackId: identical(playbackId, _fullUnset)
            ? this.playbackId
            : playbackId as String?,
        failure:
            identical(failure, _fullUnset) ? this.failure : failure as String?,
      );
}

const _fullUnset = Object();

final fullDubbingControllerProvider = AutoDisposeAsyncNotifierProviderFamily<
    FullDubbingController, FullDubbingState, String>(FullDubbingController.new);

final class FullDubbingController
    extends AutoDisposeFamilyAsyncNotifier<FullDubbingState, String> {
  late final AudioRecordingService _recorder;
  late final DubbingRepository _repository;
  late final ScoringProvider _scorer;
  late final DubbingMixService _mixService;
  late final RecordingPreparationProtocol _preparation;
  late final OriginalAudioPlayer _audioPlayer;
  StreamSubscription<RecordingLevel>? _levels;
  StreamSubscription<Duration>? _audioPositions;
  StreamSubscription<bool>? _audioPlaying;
  Timer? _elapsedTimer;
  Timer? _limitTimer;
  Stopwatch? _stopwatch;
  Duration _contentOffset = Duration.zero;
  var _backgroundLoaded = false;
  var _audioMode = _FullAudioMode.none;
  String? _audioId;
  Duration _playbackStart = Duration.zero;
  Duration _playbackEnd = Duration.zero;
  var _finishingPlayback = false;
  var _changingPlayback = false;
  var _generation = 0;
  var _stopping = false;
  var _disposed = false;

  @override
  Future<FullDubbingState> build(String libraryId) async {
    _repository = await ref.watch(dubbingRepositoryProvider.future);
    _recorder = await ref.watch(recordingServiceProvider.future);
    _scorer = ref.watch(scoringProvider);
    _mixService = ref.watch(dubbingMixServiceProvider);
    _preparation = ref.watch(recordingPreparationProtocolProvider);
    _audioPlayer = ref.watch(originalAudioPlayerProvider);
    final original =
        await ref.watch(originalAudioBookProvider(libraryId).future);
    if (original.sourceBookId.isEmpty ||
        original.resourceSha256.isEmpty ||
        original.timelineSha256.isEmpty) {
      throw StateError('原音时间轴身份不完整，请重新导入绘本');
    }
    final projects = await _repository.listProjects(libraryId);
    final matches = projects.where((project) =>
        project.mode == DubbingMode.full &&
        project.status != DubbingProjectStatus.incompatible &&
        project.sourceBookId == original.sourceBookId &&
        project.resourceSha256 == original.resourceSha256 &&
        project.timelineSha256 == original.timelineSha256);
    final project = matches.isNotEmpty
        ? matches.first
        : await _repository.createProject(DubbingProjectDraft(
            libraryId: libraryId,
            sourceBookId: original.sourceBookId,
            resourceSha256: original.resourceSha256,
            timelineSha256: original.timelineSha256,
            mode: DubbingMode.full,
          ));
    final takes = await _repository.listTakes(project.id);
    final mixes = await _repository.listMixes(project.id);
    _audioPositions = _audioPlayer.positionStream.listen(_onAudioPosition);
    _audioPlaying = _audioPlayer.playingStream.listen(_onAudioPlaying);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelAndStop());
    });
    return FullDubbingState(
      project: project,
      original: original,
      takes: takes,
      mixes: mixes,
    );
  }

  /// Starts Android capture first, then stabilizes the microphone and gives
  /// the child three clear beats. [DubbingTake.contentOffset] records the
  /// exact content zero so existing score/mix rules remain aligned.
  Future<void> startCountdown() async {
    var current = state.valueOrNull;
    if (current == null || !current.canStart) return;
    final generation = ++_generation;
    try {
      await _stopPlayback(clearState: true);
    } on Object {
      // A stale preview must not prevent recording a new version.
    }
    if (!_isCurrent(generation)) return;
    current = state.valueOrNull;
    if (current == null) return;
    // Recording again after handing in a work starts a new editable draft.
    if (current.isComplete) {
      await _repository.updateProjectStatus(
          current.project.id, DubbingProjectStatus.draft);
      final draftProject = await _repository.findProject(current.project.id);
      if (!_isCurrent(generation) || draftProject == null) return;
      current = current.copyWith(project: draftProject);
    }
    try {
      final session = await _recorder.start(libraryId: arg, sentenceId: 'full');
      if (!_isCurrent(generation)) {
        await _recorder.cancel();
        return;
      }
      _backgroundLoaded = false;
      final background = current.original.backgroundPath;
      if (background != null) {
        try {
          _audioMode = _FullAudioMode.recordingBackground;
          _audioId = null;
          await _audioPlayer.stop();
          await _audioPlayer.load(background);
          await _audioPlayer.seek(Duration.zero);
          await _audioPlayer.setVolume(_recordingBackgroundVolume);
          _backgroundLoaded = true;
        } on Object {
          _audioMode = _FullAudioMode.none;
          // Silent lyrics are a supported fallback. Never substitute the
          // original narration when a confirmed background cannot play.
        }
      }
      _set(current.copyWith(
        phase: FullDubbingPhase.preparing,
        countdown: 0,
        elapsed: Duration.zero,
        level: 0,
        failure: background != null && !_backgroundLoaded
            ? '背景音乐暂时不能播放，歌词仍会按时间继续。'
            : null,
      ));
      _contentOffset = await _preparation.run(
        isActive: () => _isCurrent(generation),
        onUpdate: (update) {
          final latest = state.valueOrNull;
          if (!_isCurrent(generation) || latest == null) return;
          _set(latest.copyWith(
            phase: update.stage == RecordingPreparationStage.stabilizing
                ? FullDubbingPhase.preparing
                : FullDubbingPhase.countdown,
            countdown: update.countdown,
          ));
        },
      );
      if (!_isCurrent(generation)) {
        await _recorder.cancel();
        return;
      }
      await _beginRecording(generation, session);
    } on RecordingPreparationCancelled {
      try {
        await _recorder.cancel();
      } on Object {}
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _fail(error.message);
    } on Object {
      if (_isCurrent(generation)) _fail('录音没有开始，请稍后重试');
    }
  }

  Future<void> cancelCountdown() async {
    final current = state.valueOrNull;
    if (current == null ||
        (current.phase != FullDubbingPhase.preparing &&
            current.phase != FullDubbingPhase.countdown)) {
      return;
    }
    ++_generation;
    await _recorder.cancel();
    try {
      await _audioPlayer.stop();
    } on Object {}
    _audioMode = _FullAudioMode.none;
    _set(current.copyWith(phase: FullDubbingPhase.ready, countdown: 0));
  }

  Future<void> _beginRecording(
    int generation,
    RecordingSession session,
  ) async {
    final current = state.valueOrNull;
    if (current == null || !_isCurrent(generation)) return;
    try {
      _stopwatch = Stopwatch()..start();
      _levels = session.levels.listen((level) {
        final latest = state.valueOrNull;
        if (_isCurrent(generation) && latest?.isRecording == true) {
          _set(latest!.copyWith(
              level: level.value,
              elapsed: _stopwatch?.elapsed ?? Duration.zero));
        }
      });
      _elapsedTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        final latest = state.valueOrNull;
        if (_isCurrent(generation) && latest?.isRecording == true) {
          _set(latest!.copyWith(elapsed: _stopwatch?.elapsed ?? Duration.zero));
        }
      });
      // The lyric timeline is authoritative. Five seconds of tail room lets a
      // child finish naturally without allowing an abandoned recorder to run.
      final cap = current.original.duration + const Duration(seconds: 5);
      _limitTimer = Timer(cap, () => unawaited(stopRecording()));
      _set(current.copyWith(
          phase: FullDubbingPhase.recording,
          countdown: 0,
          elapsed: Duration.zero,
          level: 0));
      if (_backgroundLoaded) unawaited(_playBackground());
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
          phase: FullDubbingPhase.saving,
          level: 0,
          elapsed: _stopwatch?.elapsed ?? current.elapsed));
      await _stopActivity();
      try {
        await _audioPlayer.stop();
      } on Object {}
      _audioMode = _FullAudioMode.none;
      final path = await _recorder.stop();
      if (!_isCurrent(generation)) return;
      final duration = _stopwatch?.elapsed ?? current.elapsed;
      final take = await _repository.saveTake(
        projectId: current.project.id,
        kind: DubbingTakeKind.full,
        sourceAudio: File(path),
        duration: duration > Duration.zero
            ? duration
            : const Duration(milliseconds: 1),
        contentOffset: _contentOffset,
      );
      try {
        await File(path).delete();
      } on Object {}
      await _repository.selectTake(take.id);
      await _refresh(phase: FullDubbingPhase.ready);
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _fail(error.message);
    } on Object {
      if (_isCurrent(generation)) _fail('录音没有保存成功，请再试一次');
    } finally {
      _stopping = false;
    }
  }

  Future<void> selectTake(String takeId) async {
    if (state.valueOrNull?.isBusy ?? true) return;
    await _repository.selectTake(takeId);
    await _refresh();
  }

  Future<void> deleteTake(String takeId) async {
    if (state.valueOrNull?.isBusy ?? true) return;
    if (_audioMode == _FullAudioMode.take && _audioId == takeId) {
      await _stopPlayback(clearState: true);
    }
    await _repository.deleteTake(takeId);
    await _refresh();
  }

  Future<bool> playTake(DubbingTake take) => _togglePlayback(
        mode: _FullAudioMode.take,
        id: take.id,
        path: _repository.resolveAudioPath(take),
        start: take.contentOffset,
        end: take.contentOffset + take.duration,
      );

  Future<bool> toggleOriginalPreview() {
    final current = state.valueOrNull;
    if (current == null) return Future.value(false);
    return _togglePlayback(
      mode: _FullAudioMode.original,
      path: current.original.audioPath,
      start: Duration.zero,
      end: current.original.duration,
    );
  }

  Future<void> saveDraft() => _setStatus(DubbingProjectStatus.draft);
  Future<void> complete() => _setStatus(DubbingProjectStatus.complete);

  /// Android may remove audio focus or suspend the process at any time. Never
  /// let recording continue invisibly: cancel a preparation, or stop and
  /// persist an active Take before the page is backgrounded.
  Future<void> handleAppBackgrounded() async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (current.phase == FullDubbingPhase.preparing ||
        current.phase == FullDubbingPhase.countdown) {
      await cancelCountdown();
      return;
    }
    if (current.isRecording) {
      await stopRecording();
      final latest = state.valueOrNull;
      if (latest != null) {
        _set(latest.copyWith(
          failure: '应用刚才暂停了，录音已经安全保存，可以先回放再继续。',
        ));
      }
      return;
    }
    try {
      await _stopPlayback(clearState: true);
    } on Object {}
  }

  Future<void> prepareToLeave() => handleAppBackgrounded();

  Future<void> createMix() async {
    var current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final selected = current.takes.where((take) => take.isSelected).firstOrNull;
    if (selected == null || selected.takeKind != DubbingTakeKind.full) {
      _fail('请先选用一条完整录音。');
      return;
    }
    await _stopPlayback(clearState: true);
    final latest = state.valueOrNull;
    if (latest == null) return;
    current = latest;
    final output = await _repository.prepareMixOutput(current.project.id);
    final mode = current.original.backgroundPath == null
        ? DubbingMixMode.voiceOnly
        : DubbingMixMode.withConfirmedBackground;
    final plan = DubbingMixPlan.forFullTake(
      take: selected,
      audioPath: _repository.resolveAudioPath(selected),
      outputPath: output.absolutePath,
      mode: mode,
      timelineDuration: current.original.duration,
      confirmedBackgroundPath: current.original.backgroundPath,
      originalSourcePath: current.original.audioPath,
    );
    _set(current.copyWith(phase: FullDubbingPhase.mixing, failure: null));
    try {
      final result = await _mixService.render(plan);
      await _repository.saveMix(
        output: output,
        variant: result.variant,
        sourceTakeFingerprint: plan.sourceTakeFingerprint,
        duration: result.duration,
      );
      await _refresh();
    } on DubbingMixInputException catch (error) {
      _fail(error.message);
    } on DubbingMixRenderException catch (error) {
      _fail(error.message);
    } on Object {
      _fail('作品没有生成成功，录音都还在，可以再试一次。');
    }
  }

  Future<bool> playMix(DubbingMix mix) => _togglePlayback(
        mode: _FullAudioMode.mix,
        id: mix.id,
        path: _repository.resolveMixAudioPath(mix),
        start: Duration.zero,
        end: mix.duration,
      );

  Future<void> deleteMix(String mixId) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    if (_audioMode == _FullAudioMode.mix && _audioId == mixId) {
      await _stopPlayback(clearState: true);
    }
    await _repository.deleteMix(mixId);
    await _refresh();
  }

  /// Scores one full Take sequentially using in-memory PCM sentence slices.
  /// Score failures are persisted in the report and never delete the Take.
  Future<void> scoreTake(DubbingTake take) async {
    var current = state.valueOrNull;
    if (current == null ||
        current.isBusy ||
        take.takeKind != DubbingTakeKind.full) {
      return;
    }
    await _stopPlayback(clearState: true);
    final latest = state.valueOrNull;
    if (latest == null) return;
    current = latest;
    final generation = ++_generation;
    _set(current.copyWith(phase: FullDubbingPhase.scoring, failure: null));
    try {
      final report = await FullTakeScorer(_scorer).score(
        audio: File(_repository.resolveAudioPath(take)),
        sentences: current.original.sentences,
        contentOffset: take.contentOffset,
      );
      await _repository.updateTakeScore(
        takeId: take.id,
        status: DubbingTakeScoreStatus.scored,
        scoreJson: jsonEncode(report.toJson()),
      );
      if (_isCurrent(generation)) await _refresh();
    } on Object {
      if (!_isCurrent(generation)) return;
      await _repository.updateTakeScore(
        takeId: take.id,
        status: DubbingTakeScoreStatus.failed,
        scoreError: '完整录音评分暂时不可用，录音已保留。',
      );
      await _refresh(phase: FullDubbingPhase.failed);
    }
  }

  Future<void> _setStatus(DubbingProjectStatus status) async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    await _repository.updateProjectStatus(current.project.id, status);
    await _refresh();
  }

  Future<void> _refresh(
      {FullDubbingPhase phase = FullDubbingPhase.ready}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final project = await _repository.findProject(current.project.id);
    if (project == null) return;
    final takes = await _repository.listTakes(project.id);
    final mixes = await _repository.listMixes(project.id);
    _set(current.copyWith(
        project: project,
        takes: takes,
        mixes: mixes,
        phase: phase,
        countdown: 0,
        level: 0,
        failure: null));
  }

  void _fail(String message) {
    final current = state.valueOrNull;
    if (current != null) {
      _set(current.copyWith(
          phase: FullDubbingPhase.failed,
          countdown: 0,
          level: 0,
          failure: message));
    }
  }

  Future<void> _cancelAndStop() async {
    await _stopActivity();
    await _audioPositions?.cancel();
    _audioPositions = null;
    await _audioPlaying?.cancel();
    _audioPlaying = null;
    try {
      await _recorder.cancel();
    } on Object {}
    try {
      await _audioPlayer.stop();
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
  void _set(FullDubbingState value) {
    if (!_disposed) state = AsyncData(value);
  }

  Future<void> _playBackground() async {
    try {
      await _audioPlayer.play();
    } on Object {
      final current = state.valueOrNull;
      if (current?.isRecording == true) {
        _set(current!.copyWith(
          failure: '背景音乐播放中断，录音和歌词仍会安全继续。',
        ));
      }
    }
  }

  Future<bool> _togglePlayback({
    required _FullAudioMode mode,
    required String path,
    required Duration start,
    required Duration end,
    String? id,
  }) async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isBusy ||
        end <= start ||
        _changingPlayback) {
      return false;
    }
    _changingPlayback = true;
    final sameAudio = _audioMode == mode && _audioId == id;
    try {
      if (sameAudio && current.audioPlaying) {
        await _audioPlayer.pause();
        _set(current.copyWith(audioPlaying: false));
        return true;
      }
      if (sameAudio) {
        final duration = end - start;
        if (current.playbackPosition >=
            duration - const Duration(milliseconds: 50)) {
          await _audioPlayer.seek(start);
          _set(current.copyWith(playbackPosition: Duration.zero));
        }
        await _audioPlayer.setVolume(1);
        await _audioPlayer.play();
        final latest = state.valueOrNull;
        if (latest != null) _set(latest.copyWith(audioPlaying: true));
        return true;
      }

      _audioMode = _FullAudioMode.none;
      _audioId = null;
      await _stopPlayback(clearState: false);
      await _audioPlayer.setVolume(1);
      await _audioPlayer.load(path);
      await _audioPlayer.seek(start);
      _audioMode = mode;
      _audioId = id;
      _playbackStart = start;
      _playbackEnd = end;
      _set(current.copyWith(
        playbackKind: _publicPlaybackKind(mode),
        playbackId: id,
        playbackPosition: Duration.zero,
        audioPlaying: false,
        failure: null,
      ));
      await _audioPlayer.play();
      final latest = state.valueOrNull;
      if (latest != null) _set(latest.copyWith(audioPlaying: true));
      return true;
    } on Object {
      _audioMode = _FullAudioMode.none;
      _audioId = null;
      _playbackStart = Duration.zero;
      _playbackEnd = Duration.zero;
      final latest = state.valueOrNull;
      if (latest != null) {
        _set(latest.copyWith(
          playbackKind: FullDubbingPlaybackKind.none,
          playbackId: null,
          playbackPosition: Duration.zero,
          audioPlaying: false,
          failure: '声音暂时不能播放，录音仍然安全保留。',
        ));
      }
      return false;
    } finally {
      _changingPlayback = false;
    }
  }

  void _onAudioPosition(Duration position) {
    if (_audioMode == _FullAudioMode.none ||
        _audioMode == _FullAudioMode.recordingBackground) {
      return;
    }
    if (_playbackEnd > _playbackStart && position >= _playbackEnd) {
      unawaited(_finishPlayback());
      return;
    }
    final current = state.valueOrNull;
    if (current == null) return;
    final relative =
        position <= _playbackStart ? Duration.zero : position - _playbackStart;
    _set(current.copyWith(playbackPosition: relative));
  }

  void _onAudioPlaying(bool playing) {
    if (_audioMode == _FullAudioMode.none ||
        _audioMode == _FullAudioMode.recordingBackground) {
      return;
    }
    final current = state.valueOrNull;
    if (current != null && current.audioPlaying != playing) {
      _set(current.copyWith(audioPlaying: playing));
    }
  }

  Future<void> _finishPlayback() async {
    if (_finishingPlayback) return;
    _finishingPlayback = true;
    final finishingMode = _audioMode;
    final finishingId = _audioId;
    final finishingStart = _playbackStart;
    final finishingEnd = _playbackEnd;
    try {
      await _audioPlayer.pause();
    } on Object {
      // The platform may already have reached its stopped state.
    } finally {
      final current = state.valueOrNull;
      if (current != null &&
          _audioMode == finishingMode &&
          _audioId == finishingId) {
        _set(current.copyWith(
          playbackPosition: finishingEnd - finishingStart,
          audioPlaying: false,
        ));
      }
      _finishingPlayback = false;
    }
  }

  Future<void> _stopPlayback({required bool clearState}) async {
    _audioMode = _FullAudioMode.none;
    _audioId = null;
    _playbackStart = Duration.zero;
    _playbackEnd = Duration.zero;
    try {
      await _audioPlayer.stop();
    } on Object {
      // Clearing UI state must not be blocked by a stale Android decoder.
    }
    if (!clearState) return;
    final current = state.valueOrNull;
    if (current != null) {
      _set(current.copyWith(
        playbackKind: FullDubbingPlaybackKind.none,
        playbackId: null,
        playbackPosition: Duration.zero,
        audioPlaying: false,
      ));
    }
  }

  FullDubbingPlaybackKind _publicPlaybackKind(_FullAudioMode mode) =>
      switch (mode) {
        _FullAudioMode.original => FullDubbingPlaybackKind.original,
        _FullAudioMode.take => FullDubbingPlaybackKind.take,
        _FullAudioMode.mix => FullDubbingPlaybackKind.mix,
        _ => FullDubbingPlaybackKind.none,
      };
}

enum _FullAudioMode { none, original, take, mix, recordingBackground }

const double _recordingBackgroundVolume = .35;
