import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/audio/dubbing_mix_service.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_repository.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import 'dubbing_repository.dart';
import 'full_take_scoring.dart';

/// The continuous-recording surface deliberately stores a normal [DubbingTake]
/// with a pending score.  M5.5 can later attach sentence-range scoring data to
/// this take without moving a child's WAV or changing its project identity.
enum FullDubbingPhase {
  ready,
  countdown,
  recording,
  saving,
  scoring,
  mixing,
  failed
}

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
  final String? failure;

  bool get isRecording => phase == FullDubbingPhase.recording;
  bool get isBusy =>
      phase == FullDubbingPhase.countdown ||
      phase == FullDubbingPhase.recording ||
      phase == FullDubbingPhase.saving ||
      phase == FullDubbingPhase.scoring ||
      phase == FullDubbingPhase.mixing;
  bool get canStart => !isBusy;
  bool get isComplete => project.status == DubbingProjectStatus.complete;

  FullDubbingState copyWith({
    DubbingProject? project,
    List<DubbingTake>? takes,
    List<DubbingMix>? mixes,
    FullDubbingPhase? phase,
    int? countdown,
    Duration? elapsed,
    double? level,
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
  late final SentenceAudioPlayer _player;
  late final ScoringProvider _scorer;
  late final DubbingMixService _mixService;
  StreamSubscription<RecordingLevel>? _levels;
  Timer? _countdownTimer;
  Timer? _elapsedTimer;
  Timer? _limitTimer;
  Stopwatch? _stopwatch;
  var _generation = 0;
  var _stopping = false;
  var _disposed = false;

  @override
  Future<FullDubbingState> build(String libraryId) async {
    _repository = await ref.watch(dubbingRepositoryProvider.future);
    _recorder = await ref.watch(recordingServiceProvider.future);
    _player = ref.watch(sentenceAudioPlayerProvider);
    _scorer = ref.watch(scoringProvider);
    _mixService = ref.watch(dubbingMixServiceProvider);
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

  /// Gives the child three clear beats before the microphone starts.
  Future<void> startCountdown() async {
    var current = state.valueOrNull;
    if (current == null || !current.canStart) return;
    final generation = ++_generation;
    try {
      await _player.stop();
    } on Object {
      // A stale preview must not prevent recording a new version.
    }
    if (!_isCurrent(generation)) return;
    // Recording again after handing in a work starts a new editable draft.
    if (current.isComplete) {
      await _repository.updateProjectStatus(
          current.project.id, DubbingProjectStatus.draft);
      final draftProject = await _repository.findProject(current.project.id);
      if (!_isCurrent(generation) || draftProject == null) return;
      current = current.copyWith(project: draftProject);
    }
    _set(current.copyWith(
      phase: FullDubbingPhase.countdown,
      countdown: 3,
      elapsed: Duration.zero,
      level: 0,
      failure: null,
    ));
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final latest = state.valueOrNull;
      if (!_isCurrent(generation) ||
          latest?.phase != FullDubbingPhase.countdown) {
        return;
      }
      if (latest!.countdown <= 1) {
        _countdownTimer?.cancel();
        _countdownTimer = null;
        unawaited(_beginRecording(generation));
      } else {
        _set(latest.copyWith(countdown: latest.countdown - 1));
      }
    });
  }

  Future<void> cancelCountdown() async {
    final current = state.valueOrNull;
    if (current?.phase != FullDubbingPhase.countdown) return;
    ++_generation;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _set(current!.copyWith(phase: FullDubbingPhase.ready, countdown: 0));
  }

  Future<void> _beginRecording(int generation) async {
    final current = state.valueOrNull;
    if (current == null || !_isCurrent(generation)) return;
    try {
      final session = await _recorder.start(libraryId: arg, sentenceId: 'full');
      if (!_isCurrent(generation)) {
        await _recorder.cancel();
        return;
      }
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
      // Protect storage if a recording is forgotten, while allowing a child a
      // relaxed second pass over the whole book.
      final cap = Duration(
          milliseconds: (current.original.duration.inMilliseconds * 2 + 30000)
              .clamp(60000, 15 * 60 * 1000));
      _limitTimer = Timer(cap, () => unawaited(stopRecording()));
      _set(current.copyWith(
          phase: FullDubbingPhase.recording,
          countdown: 0,
          elapsed: Duration.zero,
          level: 0));
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
    await _repository.deleteTake(takeId);
    await _refresh();
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

  Future<void> saveDraft() => _setStatus(DubbingProjectStatus.draft);
  Future<void> complete() => _setStatus(DubbingProjectStatus.complete);

  Future<void> createMix() async {
    final current = state.valueOrNull;
    if (current == null || current.isBusy) return;
    final selected = current.takes.where((take) => take.isSelected).firstOrNull;
    if (selected == null || selected.takeKind != DubbingTakeKind.full) {
      _fail('请先选用一条完整录音。');
      return;
    }
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
    await _refresh();
  }

  /// Scores one full Take sequentially using in-memory PCM sentence slices.
  /// Score failures are persisted in the report and never delete the Take.
  Future<void> scoreTake(DubbingTake take) async {
    final current = state.valueOrNull;
    if (current == null ||
        current.isBusy ||
        take.takeKind != DubbingTakeKind.full) {
      return;
    }
    final generation = ++_generation;
    _set(current.copyWith(phase: FullDubbingPhase.scoring, failure: null));
    try {
      final report = await FullTakeScorer(_scorer).score(
        audio: File(_repository.resolveAudioPath(take)),
        sentences: current.original.sentences,
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
    try {
      await _recorder.cancel();
    } on Object {}
    try {
      await _player.stop();
    } on Object {}
  }

  Future<void> _stopActivity() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
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
}
