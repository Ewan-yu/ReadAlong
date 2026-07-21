import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import '../../services/recording/recording_service.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../../services/scoring/xfyun_ise_provider.dart';
import '../reader/point_reading_models.dart';
import '../reader/sentence_audio_player.dart';

enum FollowReadingPhase {
  idle,
  demonstrating,
  recording,
  scoring,
  scored,
  failed,
}

final class FollowReadingState {
  const FollowReadingState({
    this.phase = FollowReadingPhase.idle,
    this.sentence,
    this.record,
    this.result,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.failure,
  });

  final FollowReadingPhase phase;
  final ReaderSentence? sentence;
  final ReadingRecord? record;
  final ScoreResult? result;
  final Duration elapsed;
  final double level;
  final String? failure;

  bool get isRecording => phase == FollowReadingPhase.recording;
  bool get canRetry => record != null && phase == FollowReadingPhase.failed;

  FollowReadingState copyWith({
    FollowReadingPhase? phase,
    Object? sentence = _unset,
    Object? record = _unset,
    Object? result = _unset,
    Duration? elapsed,
    double? level,
    Object? failure = _unset,
  }) =>
      FollowReadingState(
        phase: phase ?? this.phase,
        sentence: identical(sentence, _unset)
            ? this.sentence
            : sentence as ReaderSentence?,
        record: identical(record, _unset) ? this.record : record as ReadingRecord?,
        result: identical(result, _unset) ? this.result : result as ScoreResult?,
        elapsed: elapsed ?? this.elapsed,
        level: level ?? this.level,
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
  late final AudioRecordingService _recorder;
  late final SentenceAudioPlayer _player;
  late final ScoringProvider _scorer;
  late final ShelfIndex _records;
  StreamSubscription<RecordingLevel>? _levels;
  Timer? _limitTimer;
  Timer? _silenceTimer;
  Stopwatch? _stopwatch;
  var _generation = 0;
  var _disposed = false;

  @override
  Future<FollowReadingState> build(String libraryId) async {
    _player = ref.watch(sentenceAudioPlayerProvider);
    _scorer = ref.watch(scoringProvider);
    _recorder = await ref.watch(recordingServiceProvider.future);
    _records = await ref.watch(shelfIndexProvider.future);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cancelActiveRecording());
    });
    return const FollowReadingState();
  }

  void selectSentence(ReaderSentence sentence) {
    _generation++;
    unawaited(_cancelActiveRecording());
    final current = state.valueOrNull;
    if (current == null) return;
    _setState(
      FollowReadingState(sentence: sentence),
    );
  }

  Future<void> stopForPageChange() async {
    _generation++;
    await _cancelActiveRecording();
    if (_disposed || state.valueOrNull == null) return;
    _setState(const FollowReadingState());
  }

  Future<void> playDemonstration() async {
    final current = state.valueOrNull;
    final sentence = current?.sentence;
    if (current == null || sentence == null) return;
    final generation = ++_generation;
    _setState(current.copyWith(
      phase: FollowReadingPhase.demonstrating,
      failure: null,
    ));
    try {
      await _player.stop();
      if (!_isCurrent(generation)) return;
      await _player.play(sentence.audio);
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(latest.copyWith(phase: FollowReadingPhase.idle));
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(latest.copyWith(
          phase: FollowReadingPhase.failed,
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
    try {
      await _player.stop();
      if (!_isCurrent(generation)) return;
      final session = await _recorder.start(
        libraryId: arg,
        sentenceId: sentence.id,
      );
      if (!_isCurrent(generation)) {
        await _recorder.cancel();
        return;
      }
      _stopwatch = Stopwatch()..start();
      _setState(current.copyWith(
        phase: FollowReadingPhase.recording,
        record: null,
        result: null,
        elapsed: Duration.zero,
        level: 0,
        failure: null,
      ));
      _levels = session.levels.listen((level) {
        if (!_isCurrent(generation)) return;
        final latest = state.valueOrNull;
        if (latest == null || !latest.isRecording) return;
        final elapsed = _stopwatch?.elapsed ?? Duration.zero;
        _setState(latest.copyWith(elapsed: elapsed, level: level.value));
        if (level.value < 0.05) {
          _silenceTimer ??= Timer(const Duration(milliseconds: 1500), () {
            unawaited(stopRecording());
          });
        } else {
          _silenceTimer?.cancel();
          _silenceTimer = null;
        }
      });
      _limitTimer = Timer(const Duration(seconds: 30), () {
        unawaited(stopRecording());
      });
    } on RecordingException catch (error) {
      if (_isCurrent(generation)) _setFailure(error.message);
    } on Object {
      if (_isCurrent(generation)) _setFailure('录音没有开始，请稍后重试');
    }
  }

  Future<void> stopRecording() async {
    final current = state.valueOrNull;
    final sentence = current?.sentence;
    if (current == null || sentence == null || !current.isRecording) return;
    final generation = _generation;
    _stopwatch?.stop();
    await _stopTimersAndLevels();
    try {
      final audioPath = await _recorder.stop();
      if (!_isCurrent(generation)) return;
      final record = await _records.createRecord(
        libraryId: arg,
        sentenceId: sentence.id,
        referenceText: sentence.text,
        audioPath: audioPath,
        provider: _scorer.name,
      );
      if (!_isCurrent(generation)) return;
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
    }
  }

  Future<void> retryScoring() async {
    final current = state.valueOrNull;
    final record = current?.record;
    if (current == null || record == null || current.phase != FollowReadingPhase.failed) {
      return;
    }
    final generation = ++_generation;
    _setState(current.copyWith(
      phase: FollowReadingPhase.scoring,
      failure: null,
    ));
    await _score(record, generation);
  }

  Future<void> playMyRecording() async {
    final record = state.valueOrNull?.record;
    if (record == null) return;
    try {
      await _player.stop();
      await _player.play(
        SentenceAudioClip(
          path: record.audioPath,
          start: Duration.zero,
          end: const Duration(seconds: 30),
          wholeFile: true,
        ),
      );
    } on Object {
      _setFailure('我的录音暂时无法播放，请再录一次');
    }
  }

  Future<void> _score(ReadingRecord record, int generation) async {
    try {
      await _records.updateRecord(
        id: record.id,
        status: ReadingRecordStatus.scoring,
      );
      final bytes = await File(record.audioPath).readAsBytes();
      final pcm = parseWavPcm16(bytes).pcm16k;
      final result = await _scorer.score(
        pcm16k: pcm,
        refText: record.referenceText,
      );
      if (!_isCurrent(generation)) return;
      await _records.updateRecord(
        id: record.id,
        status: ReadingRecordStatus.scored,
        childScore: result.childScore,
        detailJson: jsonEncode(_scoreDetails(result)),
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
    ReadingRecord record,
    String message,
    int generation,
  ) async {
    try {
      await _records.updateRecord(
        id: record.id,
        status: ReadingRecordStatus.failed,
        detailJson: jsonEncode({'error': message}),
      );
    } on Object {
      // Keep the local WAV even if a transient database operation fails.
    }
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
      await _recorder.cancel();
    } on Object {
      // The service may not have initialized when auto-dispose runs.
    }
  }

  Future<void> _stopTimersAndLevels() async {
    _limitTimer?.cancel();
    _limitTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    await _levels?.cancel();
    _levels = null;
  }

  void _setFailure(String message) {
    final current = state.valueOrNull;
    if (current == null) return;
    _setState(current.copyWith(
      phase: FollowReadingPhase.failed,
      failure: message,
      level: 0,
    ));
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _setState(FollowReadingState value) {
    if (!_disposed) state = AsyncData(value);
  }
}

Map<String, Object?> _scoreDetails(ScoreResult score) => {
      'total': score.total,
      'accuracy': score.accuracy,
      'fluency': score.fluency,
      'standard': score.standard,
      'integrity': score.integrity,
      'words': [
        for (final word in score.words)
          {'word': word.word, 'accuracy': word.accuracy},
      ],
    };
