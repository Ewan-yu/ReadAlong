import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../reader/original_audio_models.dart';
import '../reader/original_audio_repository.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import 'dubbing_repository.dart';

/// The continuous-recording surface deliberately stores a normal [DubbingTake]
/// with a pending score.  M5.5 can later attach sentence-range scoring data to
/// this take without moving a child's WAV or changing its project identity.
enum FullDubbingPhase { ready, countdown, recording, saving, failed }

final class FullDubbingState {
  const FullDubbingState({
    required this.project,
    required this.original,
    required this.takes,
    this.phase = FullDubbingPhase.ready,
    this.countdown = 0,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.failure,
  });

  final DubbingProject project;
  final OriginalAudioBook original;
  final List<DubbingTake> takes;
  final FullDubbingPhase phase;
  final int countdown;
  final Duration elapsed;
  final double level;
  final String? failure;

  bool get isRecording => phase == FullDubbingPhase.recording;
  bool get isBusy =>
      phase == FullDubbingPhase.countdown ||
      phase == FullDubbingPhase.recording ||
      phase == FullDubbingPhase.saving;
  bool get canStart => !isBusy;
  bool get isComplete => project.status == DubbingProjectStatus.complete;

  FullDubbingState copyWith({
    DubbingProject? project,
    List<DubbingTake>? takes,
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
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelAndStop());
    });
    return FullDubbingState(project: project, original: original, takes: takes);
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
    _set(current.copyWith(
        project: project,
        takes: takes,
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
