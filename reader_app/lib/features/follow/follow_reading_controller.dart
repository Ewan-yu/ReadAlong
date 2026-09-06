import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/recording/recording_service.dart';
import '../../services/recording/recording_preparation.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';
import '../reader/subtitle_timing.dart' as subtitle_timing;

enum FollowReadingPhase {
  idle,
  demonstrating,
  preparing,
  countdown,
  recording,
  scoring,
  scored,
  failed,
}

const followSpeechLevelThreshold = 0.08;
const _speechFramesRequired = 2;

/// MediaRecorder can begin writing PCM a little after `start()` resolves on
/// Android. Never trim the full visual countdown from a follow-reading take:
/// doing so can cut the child's first spoken consonant. The remaining short
/// silence is safe for scoring and replay, while the first word is not.
const followRecordingContentOffsetSafetyLead = Duration(milliseconds: 650);

Duration followRecordingContentOffset(Duration preparationElapsed) {
  return preparationElapsed - followRecordingContentLeadIn(preparationElapsed);
}

Duration followRecordingContentLeadIn(Duration preparationElapsed) {
  if (preparationElapsed <= followRecordingContentOffsetSafetyLead) {
    return preparationElapsed;
  }
  return followRecordingContentOffsetSafetyLead;
}

final class FollowRecordingTiming {
  const FollowRecordingTiming({
    required this.referenceDuration,
    required this.minimumDuration,
    required this.trailingSilenceDuration,
    required this.maximumDuration,
  });

  final Duration referenceDuration;
  final Duration minimumDuration;
  final Duration trailingSilenceDuration;
  final Duration maximumDuration;
}

FollowRecordingTiming followRecordingTimingFor(ReaderSentence sentence) {
  final clipDuration = sentence.audio.end - sentence.audio.start;
  final reference = clipDuration > Duration.zero
      ? clipDuration
      : const Duration(milliseconds: 1500);
  return FollowRecordingTiming(
    referenceDuration: reference,
    minimumDuration: _clampDuration(
      _scaleDuration(reference, 0.85) + const Duration(milliseconds: 1200),
      const Duration(milliseconds: 2200),
      const Duration(seconds: 7),
    ),
    trailingSilenceDuration: _clampDuration(
      _scaleDuration(reference, 0.12) + const Duration(milliseconds: 1500),
      const Duration(milliseconds: 1700),
      const Duration(milliseconds: 2600),
    ),
    maximumDuration: _clampDuration(
      _scaleDuration(reference, 3) + const Duration(milliseconds: 3500),
      const Duration(seconds: 7),
      const Duration(seconds: 30),
    ),
  );
}

enum FollowVoiceActivityAction { cancelSilenceTimer, armSilenceTimer }

/// Initial room silence must never finish a take. The trailing-silence timer
/// can only be armed after speech was heard and the sentence-aware minimum
/// recording window has elapsed.
final class FollowVoiceActivityTracker {
  FollowVoiceActivityTracker(this.timing);

  final FollowRecordingTiming timing;
  bool heardSpeech = false;
  var _consecutiveSpeechFrames = 0;

  FollowVoiceActivityAction update({
    required Duration elapsed,
    required double level,
  }) {
    if (level >= followSpeechLevelThreshold) {
      _consecutiveSpeechFrames++;
      if (_consecutiveSpeechFrames >= _speechFramesRequired) {
        heardSpeech = true;
      }
      return FollowVoiceActivityAction.cancelSilenceTimer;
    }
    _consecutiveSpeechFrames = 0;
    if (!heardSpeech || elapsed < timing.minimumDuration) {
      return FollowVoiceActivityAction.cancelSilenceTimer;
    }
    return FollowVoiceActivityAction.armSilenceTimer;
  }
}

/// A short-lived practice take. Follow-reading audio is intentionally kept
/// outside the durable reading/dubbing data model and is deleted as soon as
/// the result flow finishes.
final class FollowRecording {
  const FollowRecording({
    required this.id,
    required this.audioPath,
    required this.referenceText,
    required this.contentOffset,
    required this.duration,
  });

  final int id;
  final String audioPath;
  final String referenceText;
  final Duration contentOffset;
  final Duration duration;
}

final class FollowReadingState {
  const FollowReadingState({
    this.phase = FollowReadingPhase.idle,
    this.sentence,
    this.record,
    this.result,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.countdown = 0,
    this.recordingLimit = const Duration(seconds: 30),
    this.heardSpeech = false,
    this.playbackPosition = Duration.zero,
    this.playbackDuration = Duration.zero,
    this.activeWordIndex,
    this.failure,
  });

  final FollowReadingPhase phase;
  final ReaderSentence? sentence;
  final FollowRecording? record;
  final ScoreResult? result;
  final Duration elapsed;
  final double level;
  final int countdown;
  final Duration recordingLimit;
  final bool heardSpeech;
  final Duration playbackPosition;
  final Duration playbackDuration;
  final int? activeWordIndex;
  final String? failure;

  bool get isRecording => phase == FollowReadingPhase.recording;
  bool get isPreparing =>
      phase == FollowReadingPhase.preparing ||
      phase == FollowReadingPhase.countdown;
  bool get canRetry => record != null && phase == FollowReadingPhase.failed;

  FollowReadingState copyWith({
    FollowReadingPhase? phase,
    Object? sentence = _unset,
    Object? record = _unset,
    Object? result = _unset,
    Duration? elapsed,
    double? level,
    int? countdown,
    Duration? recordingLimit,
    bool? heardSpeech,
    Duration? playbackPosition,
    Duration? playbackDuration,
    Object? activeWordIndex = _unset,
    Object? failure = _unset,
  }) =>
      FollowReadingState(
        phase: phase ?? this.phase,
        sentence: identical(sentence, _unset)
            ? this.sentence
            : sentence as ReaderSentence?,
        record: identical(record, _unset)
            ? this.record
            : record as FollowRecording?,
        result:
            identical(result, _unset) ? this.result : result as ScoreResult?,
        elapsed: elapsed ?? this.elapsed,
        level: level ?? this.level,
        countdown: countdown ?? this.countdown,
        recordingLimit: recordingLimit ?? this.recordingLimit,
        heardSpeech: heardSpeech ?? this.heardSpeech,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        playbackDuration: playbackDuration ?? this.playbackDuration,
        activeWordIndex: identical(activeWordIndex, _unset)
            ? this.activeWordIndex
            : activeWordIndex as int?,
        failure: identical(failure, _unset) ? this.failure : failure as String?,
      );
}

const _unset = Object();

final followReadingControllerProvider = AutoDisposeAsyncNotifierProviderFamily<
    FollowReadingController, FollowReadingState, String>(
  FollowReadingController.new,
);

final class FollowReadingController
    extends AutoDisposeFamilyAsyncNotifier<FollowReadingState, String> {
  late final Future<AudioRecordingService> _recorderFuture;
  AudioRecordingService? _recorder;
  late final SentenceAudioPlayer _player;
  late final ScoringProvider _scorer;
  late final RecordingPreparationProtocol _preparation;
  StreamSubscription<RecordingLevel>? _levels;
  Timer? _limitTimer;
  Timer? _silenceTimer;
  Stopwatch? _stopwatch;
  FollowVoiceActivityTracker? _voiceActivity;
  var _stoppingRecording = false;
  var _recordSequence = 0;
  var _generation = 0;
  var _disposed = false;
  ReaderSentence? _pendingSentence;
  Duration _contentOffset = Duration.zero;
  Duration _contentLeadIn = Duration.zero;

  @override
  FollowReadingState build(String libraryId) {
    _player = ref.watch(sentenceAudioPlayerProvider);
    _scorer = ref.watch(scoringProvider);
    // The reading surface should be interactive before the microphone's
    // cleanup/initialization finishes. Recording awaits this future when the
    // child actually presses the record button.
    _recorderFuture = ref.watch(recordingServiceProvider.future);
    _preparation = ref.watch(recordingPreparationProtocolProvider);
    ref.onDispose(() {
      final record = state.valueOrNull?.record;
      _disposed = true;
      _generation++;
      unawaited(_disposeTransientState(record));
    });
    final pendingSentence = _pendingSentence;
    _pendingSentence = null;
    return FollowReadingState(sentence: pendingSentence);
  }

  void selectSentence(ReaderSentence sentence) {
    // The reader can resolve alignment before this async notifier has
    // published its initial state. Keep the selection instead of dropping
    // it, so opening a page never falls back to the "tap a sentence" prompt.
    _pendingSentence = sentence;
    _generation++;
    unawaited(_cancelActiveRecording());
    final current = state.valueOrNull;
    if (current == null) return;
    _pendingSentence = null;
    unawaited(_deleteRecording(current.record));
    _setState(
      FollowReadingState(sentence: sentence),
    );
  }

  Future<void> stopForPageChange() async {
    _generation++;
    final record = state.valueOrNull?.record;
    await _cancelActiveRecording();
    await _deleteRecording(record);
    if (_disposed || state.valueOrNull == null) return;
    _setState(const FollowReadingState());
  }

  Future<void> handleAppBackgrounded() async {
    final current = state.valueOrNull;
    if (current == null) return;
    _generation++;
    await _cancelActiveRecording();
    try {
      await _player.stop();
    } on Object {}
    await _deleteRecording(current.record);
    final sentence = current.sentence;
    if (_disposed || sentence == null) return;
    _setState(FollowReadingState(sentence: sentence));
  }

  Future<void> playDemonstration() async {
    final current = state.valueOrNull;
    final sentence = current?.sentence;
    if (current == null || sentence == null) return;
    final generation = ++_generation;
    _setState(current.copyWith(
      phase: FollowReadingPhase.demonstrating,
      playbackPosition: Duration.zero,
      playbackDuration: sentence.audio.end - sentence.audio.start,
      activeWordIndex: subtitle_timing.activeWordIndex(sentence, Duration.zero),
      failure: null,
    ));
    try {
      await _player.stop();
      if (!_isCurrent(generation)) return;
      await _player.play(
        sentence.audio,
        onPosition: (elapsed) => _handleDemonstrationPosition(
          generation,
          sentence,
          elapsed,
        ),
      );
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(latest.copyWith(
          phase: FollowReadingPhase.idle,
          playbackPosition: latest.playbackDuration,
          activeWordIndex: null,
        ));
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(latest.copyWith(
          phase: FollowReadingPhase.failed,
          activeWordIndex: null,
          failure: '示范音暂时无法播放，请重新导入绘本后再试',
        ));
      }
    }
  }

  Future<void> startRecording() async {
    final current = state.valueOrNull;
    final sentence = current?.sentence;
    if (current == null || sentence == null || current.isRecording) return;
    final generation = ++_generation;
    final timing = followRecordingTimingFor(sentence);
    try {
      await _player.stop();
      if (!_isCurrent(generation)) return;
      final recorder = _recorder = await _recorderFuture;
      if (!_isCurrent(generation)) {
        await recorder.cancel();
        return;
      }
      await _deleteRecording(current.record);
      if (!_isCurrent(generation)) return;
      final session = await recorder.start(
        libraryId: arg,
        sentenceId: sentence.id,
      );
      if (!_isCurrent(generation)) {
        await recorder.cancel();
        return;
      }
      _setState(current.copyWith(
        phase: FollowReadingPhase.preparing,
        record: null,
        result: null,
        elapsed: Duration.zero,
        level: 0,
        countdown: 0,
        recordingLimit: timing.maximumDuration,
        heardSpeech: false,
        playbackPosition: Duration.zero,
        playbackDuration: Duration.zero,
        activeWordIndex: null,
        failure: null,
      ));
      final preparationElapsed = await _preparation.run(
        isActive: () => _isCurrent(generation),
        onUpdate: (update) {
          final latest = state.valueOrNull;
          if (!_isCurrent(generation) || latest == null) return;
          _setState(latest.copyWith(
            phase: update.stage == RecordingPreparationStage.stabilizing
                ? FollowReadingPhase.preparing
                : FollowReadingPhase.countdown,
            countdown: update.countdown,
          ));
        },
      );
      _contentOffset = followRecordingContentOffset(preparationElapsed);
      _contentLeadIn = followRecordingContentLeadIn(preparationElapsed);
      if (!_isCurrent(generation)) {
        await recorder.cancel();
        return;
      }
      _stopwatch = Stopwatch()..start();
      _voiceActivity = FollowVoiceActivityTracker(timing);
      _setState(current.copyWith(
        phase: FollowReadingPhase.recording,
        record: null,
        result: null,
        elapsed: Duration.zero,
        level: 0,
        countdown: 0,
        recordingLimit: timing.maximumDuration,
        heardSpeech: false,
        playbackPosition: Duration.zero,
        playbackDuration: Duration.zero,
        activeWordIndex: null,
        failure: null,
      ));
      _levels = session.levels.listen((level) {
        if (!_isCurrent(generation)) return;
        final latest = state.valueOrNull;
        if (latest == null || !latest.isRecording) return;
        final elapsed = _stopwatch?.elapsed ?? Duration.zero;
        final voiceActivity = _voiceActivity;
        if (voiceActivity == null) return;
        final action = voiceActivity.update(
          elapsed: elapsed,
          level: level.value,
        );
        _setState(latest.copyWith(
          elapsed: elapsed,
          level: level.value,
          heardSpeech: voiceActivity.heardSpeech,
        ));
        if (action == FollowVoiceActivityAction.armSilenceTimer) {
          _silenceTimer ??= Timer(timing.trailingSilenceDuration, () {
            unawaited(stopRecording());
          });
        } else {
          _silenceTimer?.cancel();
          _silenceTimer = null;
        }
      });
      _limitTimer = Timer(timing.maximumDuration, () {
        unawaited(stopRecording());
      });
    } on RecordingPreparationCancelled {
      try {
        await _recorder?.cancel();
      } on Object {}
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _setFailure(error.message);
    } on Object {
      if (_isCurrent(generation)) _setFailure('录音没有开始，请稍后重试');
    }
  }

  Future<void> cancelPreparation() async {
    final current = state.valueOrNull;
    if (current == null || !current.isPreparing) return;
    ++_generation;
    await _recorder?.cancel();
    _setState(current.copyWith(
      phase: FollowReadingPhase.idle,
      countdown: 0,
      level: 0,
      failure: null,
    ));
  }

  Future<void> stopRecording() async {
    final current = state.valueOrNull;
    final sentence = current?.sentence;
    if (current == null ||
        sentence == null ||
        !current.isRecording ||
        _stoppingRecording) {
      return;
    }
    // The silence timer and the visible stop button may fire in the same
    // frame.  Native MediaRecorder is not safe to stop twice concurrently.
    _stoppingRecording = true;
    final generation = _generation;
    _stopwatch?.stop();
    try {
      _setState(current.copyWith(
        phase: FollowReadingPhase.scoring,
        elapsed: _stopwatch?.elapsed ?? current.elapsed,
        level: 0,
      ));
      await _stopTimersAndLevels();
      final recorder = _recorder;
      if (recorder == null) {
        throw const RecordingException('录音服务尚未准备好，请再试一次');
      }
      final audioPath = await recorder.stop();
      if (!_isCurrent(generation)) return;
      final record = FollowRecording(
        id: ++_recordSequence,
        audioPath: audioPath,
        referenceText: sentence.text,
        contentOffset: _contentOffset,
        duration: (_stopwatch?.elapsed ?? current.elapsed) + _contentLeadIn,
      );
      final latest = state.valueOrNull;
      if (latest == null) return;
      _setState(latest.copyWith(
        phase: FollowReadingPhase.scoring,
        record: record,
        elapsed: _stopwatch?.elapsed ?? latest.elapsed,
        level: 0,
        failure: null,
      ));
      await _score(record, generation);
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _setFailure(error.message);
    } on Object {
      if (_isCurrent(generation)) _setFailure('录音没有保存成功，请再试一次');
    } finally {
      _stoppingRecording = false;
    }
  }

  Future<void> retryScoring() async {
    final current = state.valueOrNull;
    final record = current?.record;
    if (current == null ||
        record == null ||
        current.phase != FollowReadingPhase.failed) {
      return;
    }
    final generation = ++_generation;
    _setState(current.copyWith(
      phase: FollowReadingPhase.scoring,
      failure: null,
    ));
    await _score(record, generation);
  }

  /// Finishes the one-off practice flow and removes its temporary WAV.
  Future<void> acknowledgeResult() async {
    final current = state.valueOrNull;
    if (current == null || current.phase != FollowReadingPhase.scored) return;
    _setState(current.copyWith(
      phase: FollowReadingPhase.idle,
      record: null,
      result: null,
      failure: null,
    ));
    try {
      await _player.stop();
    } on Object {
      // File cleanup remains useful even if native playback already stopped.
    }
    await _deleteRecording(current.record);
  }

  /// Plays in-place so the score dialog can stay open for repeated listening.
  Future<bool> playMyRecording() async {
    final record = state.valueOrNull?.record;
    if (record == null) return false;
    try {
      await _player.stop();
      await _player.play(
        SentenceAudioClip(
          path: record.audioPath,
          start: record.contentOffset,
          end: record.contentOffset + record.duration,
        ),
      );
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _score(FollowRecording record, int generation) async {
    try {
      final bytes = await File(record.audioPath).readAsBytes();
      final pcm = parseWavPcm16(bytes).pcm16k;
      final contentPcm = pcm16SliceFromOffset(pcm, record.contentOffset);
      final result = await _scorer.score(
        pcm16k: contentPcm,
        refText: record.referenceText,
      );
      if (!_isCurrent(generation)) return;
      final current = state.valueOrNull;
      if (current != null) {
        _setState(current.copyWith(
          phase: FollowReadingPhase.scored,
          result: result,
          failure: null,
        ));
      }
    } on ScoringException catch (error) {
      await _markScoreFailed(record, error.message, generation);
    } on RecordingException catch (error) {
      await _markScoreFailed(record, error.message, generation);
    } on Object {
      await _markScoreFailed(record, '分数马上来～ 录音已经保留，可以稍后重试', generation);
    }
  }

  Future<void> _markScoreFailed(
    FollowRecording record,
    String message,
    int generation,
  ) async {
    if (!_isCurrent(generation)) return;
    final current = state.valueOrNull;
    if (current != null) {
      _setState(current.copyWith(
        phase: FollowReadingPhase.failed,
        failure: message,
      ));
    }
  }

  Future<void> _cancelActiveRecording() async {
    await _stopTimersAndLevels();
    try {
      await _recorder?.cancel();
    } on Object {
      // The service may not have initialized when auto-dispose runs.
    }
  }

  Future<void> _disposeTransientState(FollowRecording? record) async {
    await _cancelActiveRecording();
    try {
      await _player.stop();
    } on Object {
      // The shared player may already be disposed by its provider.
    }
    await _deleteRecording(record);
  }

  Future<void> _deleteRecording(FollowRecording? record) async {
    if (record == null) return;
    try {
      final file = File(record.audioPath);
      if (await file.exists()) await file.delete();
    } on Object {
      // The cache directory is purged when the service starts again, so an
      // unavailable file never blocks the child from continuing to read.
    }
  }

  Future<void> _stopTimersAndLevels() async {
    _limitTimer?.cancel();
    _limitTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _levels?.cancel();
    _levels = null;
    _voiceActivity = null;
  }

  void _setFailure(String message) {
    final current = state.valueOrNull;
    if (current == null) return;
    _setState(current.copyWith(
      phase: FollowReadingPhase.failed,
      failure: message,
      level: 0,
      activeWordIndex: null,
    ));
  }

  void _handleDemonstrationPosition(
    int generation,
    ReaderSentence sentence,
    Duration elapsed,
  ) {
    if (!_isCurrent(generation)) return;
    final current = state.valueOrNull;
    if (current == null ||
        current.phase != FollowReadingPhase.demonstrating ||
        current.sentence?.id != sentence.id) {
      return;
    }
    final position = subtitle_timing.clampPlaybackPosition(
      elapsed,
      current.playbackDuration,
    );
    _setState(current.copyWith(
      playbackPosition: position,
      activeWordIndex: subtitle_timing.activeWordIndex(sentence, position),
    ));
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _setState(FollowReadingState value) {
    if (!_disposed) state = AsyncData(value);
  }
}

Duration _scaleDuration(Duration value, double factor) => Duration(
      milliseconds: (value.inMilliseconds * factor).round(),
    );

Duration _clampDuration(Duration value, Duration minimum, Duration maximum) {
  if (value < minimum) return minimum;
  if (value > maximum) return maximum;
  return value;
}
