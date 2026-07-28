import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/features/follow/follow_reading_controller.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';
import 'package:reader_app/services/recording/recording_service.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/scoring_provider.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart';

final class _FakeRecorder implements AudioRecordingService {
  _FakeRecorder(this.path);

  final String path;
  var cancelCalls = 0;

  @override
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  }) async {
    await File(path).writeAsBytes(_wav());
    return RecordingSession(path: path, levels: const Stream.empty());
  }

  @override
  Future<String> stop() async => path;

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }

  @override
  Future<void> dispose() async {}
}

final class _FakePlayer implements SentenceAudioPlayer {
  final played = <SentenceAudioClip>[];
  Object? nextFailure;

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) async {
    played.add(clip);
    final failure = nextFailure;
    nextFailure = null;
    if (failure != null) throw failure;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

final class _FakeScorer implements ScoringProvider {
  @override
  String get name => 'fake';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async {
    expect(pcm16k, isNotEmpty);
    return const ScoreResult(
      childScore: 88,
      provider: 'fake',
      accuracy: 86,
      fluency: 90,
      integrity: 88,
    );
  }
}

final class _ImmediatePreparation implements RecordingPreparationProtocol {
  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    onUpdate(const RecordingPreparationUpdate.countdown(3));
    return Duration.zero;
  }
}

Uint8List _wav() {
  const pcm = [0, 0, 1, 0];
  final bytes = Uint8List(44 + pcm.length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, 36 + pcm.length, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 16000, Endian.little);
  view.setUint32(28, 32000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

ReaderSentence _sentence(
  String id, {
  Duration clipDuration = const Duration(seconds: 1),
}) =>
    ReaderSentence(
      id: id,
      pageNumber: 1,
      sequence: 1,
      text: 'My dad.',
      bbox: const NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
      sharedBbox: false,
      audio: SentenceAudioClip(
        path: '$id.ogg',
        start: Duration.zero,
        end: clipDuration,
      ),
      wordTimings: const [],
    );

void main() {
  late Directory tempDir;
  late _FakeRecorder recorder;
  late _FakePlayer player;
  late ProviderContainer container;
  ProviderSubscription<AsyncValue<FollowReadingState>>? subscription;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('follow_controller_test_');
    subscription = null;
    recorder = _FakeRecorder(p.join(tempDir.path, 'take.wav'));
    player = _FakePlayer();
    container = ProviderContainer(
      overrides: [
        recordingServiceProvider.overrideWith((_) async => recorder),
        sentenceAudioPlayerProvider.overrideWithValue(player),
        scoringProvider.overrideWithValue(_FakeScorer()),
        recordingPreparationProtocolProvider
            .overrideWithValue(_ImmediatePreparation()),
      ],
    );
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await pumpEventQueue();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<FollowReadingController> readyController() async {
    subscription ??= container.listen(
      followReadingControllerProvider('book-copy'),
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(followReadingControllerProvider('book-copy').future);
    return container
        .read(followReadingControllerProvider('book-copy').notifier);
  }

  FollowReadingState currentState() =>
      container.read(followReadingControllerProvider('book-copy')).requireValue;

  Future<void> scoreOneTake(FollowReadingController controller) async {
    controller.selectSentence(_sentence('sentence-one'));
    await controller.startRecording();
    expect(currentState().recordingLimit, const Duration(seconds: 7));
    await controller.stopRecording();
    expect(currentState().phase, FollowReadingPhase.scored);
    expect(currentState().result?.childScore, 88);
  }

  test('评分窗口期间可重复试听且状态和临时文件保持不变', () async {
    final controller = await readyController();
    await scoreOneTake(controller);
    final record = currentState().record!;

    expect(await File(record.audioPath).exists(), isTrue);
    expect(await controller.playMyRecording(), isTrue);
    expect(await controller.playMyRecording(), isTrue);
    expect(currentState().phase, FollowReadingPhase.scored);
    expect(currentState().record?.id, record.id);
    expect(player.played, hasLength(2));
    expect(player.played.every((clip) => !clip.wholeFile), isTrue);
    expect(await File(record.audioPath).exists(), isTrue);

    player.nextFailure = StateError('decoder failed');
    expect(await controller.playMyRecording(), isFalse);
    expect(currentState().phase, FollowReadingPhase.scored);
    expect(await File(record.audioPath).exists(), isTrue);
  });

  test('录音时长按示范音长度缩放并保持儿童合理上下限', () {
    final short = followRecordingTimingFor(_sentence('short'));
    expect(short.referenceDuration, const Duration(seconds: 1));
    expect(short.minimumDuration, const Duration(milliseconds: 2200));
    expect(short.trailingSilenceDuration, const Duration(milliseconds: 1700));
    expect(short.maximumDuration, const Duration(seconds: 7));

    final long = followRecordingTimingFor(
      _sentence('long', clipDuration: const Duration(seconds: 8)),
    );
    expect(long.minimumDuration, const Duration(seconds: 7));
    expect(long.trailingSilenceDuration, const Duration(milliseconds: 2460));
    expect(long.maximumDuration, const Duration(milliseconds: 27500));
  });

  test('跟读内容零点保留 Android 录音启动安全前导，避免裁掉首词', () {
    expect(
      followRecordingContentOffset(const Duration(milliseconds: 3650)),
      const Duration(seconds: 3),
    );
    expect(
      followRecordingContentLeadIn(const Duration(milliseconds: 3650)),
      const Duration(milliseconds: 650),
    );
    expect(
      followRecordingContentOffset(const Duration(milliseconds: 500)),
      Duration.zero,
    );
    expect(
      followRecordingContentLeadIn(const Duration(milliseconds: 500)),
      const Duration(milliseconds: 500),
    );
  });

  test('初始静音不会结束录音且开口后过最短时长才允许收尾', () {
    final timing = followRecordingTimingFor(_sentence('my-mom'));
    final tracker = FollowVoiceActivityTracker(timing);

    expect(
      tracker.update(
        elapsed: const Duration(seconds: 5),
        level: 0.01,
      ),
      FollowVoiceActivityAction.cancelSilenceTimer,
    );
    expect(tracker.heardSpeech, isFalse);

    expect(
      tracker.update(
        elapsed: const Duration(milliseconds: 800),
        level: 0.2,
      ),
      FollowVoiceActivityAction.cancelSilenceTimer,
    );
    expect(tracker.heardSpeech, isFalse);
    expect(
      tracker.update(
        elapsed: const Duration(seconds: 1),
        level: 0.2,
      ),
      FollowVoiceActivityAction.cancelSilenceTimer,
    );
    expect(tracker.heardSpeech, isTrue);
    expect(
      tracker.update(
        elapsed: const Duration(seconds: 2),
        level: 0.01,
      ),
      FollowVoiceActivityAction.cancelSilenceTimer,
    );
    expect(
      tracker.update(
        elapsed: const Duration(milliseconds: 2200),
        level: 0.01,
      ),
      FollowVoiceActivityAction.armSilenceTimer,
    );
    expect(
      tracker.update(
        elapsed: const Duration(milliseconds: 2300),
        level: 0.2,
      ),
      FollowVoiceActivityAction.cancelSilenceTimer,
    );
  });

  test('确认结果后删除一次性录音且不影响当前句', () async {
    final controller = await readyController();
    await scoreOneTake(controller);
    final record = currentState().record!;

    await controller.acknowledgeResult();

    expect(currentState().phase, FollowReadingPhase.idle);
    expect(currentState().sentence?.id, 'sentence-one');
    expect(currentState().record, isNull);
    expect(currentState().result, isNull);
    expect(await File(record.audioPath).exists(), isFalse);
  });

  test('换句和 Provider 销毁都会清理已停止的临时录音', () async {
    final controller = await readyController();
    await scoreOneTake(controller);
    final firstPath = currentState().record!.audioPath;

    controller.selectSentence(_sentence('sentence-two'));
    await pumpEventQueue();
    expect(await File(firstPath).exists(), isFalse);

    await controller.startRecording();
    await controller.stopRecording();
    final secondPath = currentState().record!.audioPath;
    expect(await File(secondPath).exists(), isTrue);

    subscription!.close();
    subscription = null;
    await pumpEventQueue();
    expect(await File(secondPath).exists(), isFalse);
  });

  test('Android 切到后台会取消隐形录音并保留当前句', () async {
    final controller = await readyController();
    controller.selectSentence(_sentence('sentence-one'));
    await controller.startRecording();

    await controller.handleAppBackgrounded();

    expect(currentState().phase, FollowReadingPhase.idle);
    expect(currentState().sentence?.id, 'sentence-one');
    expect(recorder.cancelCalls, greaterThan(0));
  });
}
