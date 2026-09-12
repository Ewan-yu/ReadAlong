import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/features/dubbing/dubbing_repository.dart';
import 'package:reader_app/features/dubbing/sentence_dubbing_controller.dart';
import 'package:reader_app/features/dubbing/sentence_dubbing_page.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_player.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';
import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';
import 'package:reader_app/services/recording/recording_service.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/scoring_provider.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart';

void main() {
  late Directory temporary;
  late _Repository repository;
  late _Player player;
  late _OriginalPlayer originalPlayer;
  late _Recorder recorder;
  late List<String> events;
  late ProviderContainer container;
  ProviderSubscription<AsyncValue<SentenceDubbingState>>? subscription;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('sentence_dubbing_');
    repository = _Repository(temporary);
    events = [];
    player = _Player(events);
    originalPlayer = _OriginalPlayer(events);
    recorder = _Recorder(temporary, events);
    container = ProviderContainer(overrides: [
      dubbingRepositoryProvider.overrideWith((_) async => repository),
      recordingServiceProvider.overrideWith((_) async => recorder),
      sentenceDubbingPreparationProtocolProvider
          .overrideWithValue(_ImmediatePreparation()),
      sentenceDubbingPlaybackSettleProvider.overrideWithValue(Duration.zero),
      sentenceAudioPlayerProvider.overrideWithValue(player),
      originalAudioPlayerProvider.overrideWithValue(originalPlayer),
      scoringProvider.overrideWithValue(_Scorer()),
      originalAudioBookProvider('book-copy').overrideWith((_) async => _book()),
    ]);
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await pumpEventQueue(times: 20);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await originalPlayer.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<SentenceDubbingController> ready() async {
    subscription = container.listen(
      sentenceDubbingControllerProvider('book-copy'),
      (_, __) {},
      fireImmediately: true,
    );
    await container.read(sentenceDubbingControllerProvider('book-copy').future);
    return container
        .read(sentenceDubbingControllerProvider('book-copy').notifier);
  }

  SentenceDubbingState current() => container
      .read(sentenceDubbingControllerProvider('book-copy'))
      .requireValue;

  test('单次主操作自动完成示范、准备、录音、评分和选用', () async {
    final controller = await ready();

    await controller.startRecording();
    expect(current().phase, SentenceDubbingPhase.recording);
    expect(originalPlayer.loadedPaths.single, 'original.ogg');
    expect(originalPlayer.seeked.single, Duration.zero);
    expect(events.take(2), ['recorder.start', 'original.play']);

    await controller.stopRecording();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(current().phase, SentenceDubbingPhase.result);
    expect(current().completedSentenceCount, 1);
    expect(current().takes.single.isSelected, isTrue);
    expect(current().result?.childScore, 90);

    await controller.continueToNextSentence();
    expect(current().sentenceIndex, 1);
    expect(current().sentence.id, 's2');
  });

  test('Android 切后台会结束并保存正在录制的句子', () async {
    final controller = await ready();
    await controller.startRecording();

    await controller.handleAppBackgrounded();

    expect(current().takes, hasLength(1));
    expect(current().takes.single.isSelected, isTrue);
    expect(current().failure, contains('安全保存'));
  });

  test('示范播放期间切后台会停止整轨并取消预热录音', () async {
    final controller = await ready();
    originalPlayer.holdPlayback = true;

    final starting = controller.startRecording();
    for (var attempt = 0;
        attempt < 10 && !originalPlayer.playbackStarted;
        attempt++) {
      await pumpEventQueue(times: 20);
    }
    expect(current().phase, SentenceDubbingPhase.demonstrating);

    await controller.handleAppBackgrounded();
    await starting;

    expect(current().phase, SentenceDubbingPhase.ready);
    expect(current().activeWordIndex, isNull);
    expect(originalPlayer.stopCalls, greaterThanOrEqualTo(2));
    expect(recorder.cancelCalls, 1);
  });

  test('句末时间到达后继续播放安全尾音，不会立刻进入录音', () async {
    final controller = await ready();
    originalPlayer.holdPlayback = true;

    final starting = controller.startRecording();
    for (var attempt = 0;
        attempt < 10 && !originalPlayer.playbackStarted;
        attempt++) {
      await pumpEventQueue(times: 20);
    }
    originalPlayer.emit(const Duration(milliseconds: 800));
    await pumpEventQueue(times: 20);
    expect(current().phase, SentenceDubbingPhase.demonstrating);
    expect(current().activeWordIndex, isNull);

    originalPlayer.emit(const Duration(milliseconds: 1450));
    await starting;
    expect(current().phase, SentenceDubbingPhase.recording);
    await controller.stopRecording();
    await pumpEventQueue(times: 20);
  });

  test('示范音焦点提前中断时不会误导孩子直接开始录音', () async {
    final controller = await ready();
    originalPlayer.holdPlayback = true;

    final starting = controller.startRecording();
    for (var attempt = 0;
        attempt < 10 && !originalPlayer.playbackStarted;
        attempt++) {
      await pumpEventQueue(times: 20);
    }
    originalPlayer.emit(const Duration(milliseconds: 300));
    await pumpEventQueue(times: 20);
    originalPlayer.interrupt();
    await starting;

    expect(current().phase, SentenceDubbingPhase.failed);
    expect(current().isRecording, isFalse);
    expect(recorder.cancelCalls, 1);
  });

  test('非首句利用句间空档预滚并保留尾音，避免首尾被截断', () async {
    final controller = await ready();
    await controller.nextSentence();

    await controller.startRecording();

    expect(
      originalPlayer.seeked.single,
      const Duration(milliseconds: 1100),
    );
    expect(originalPlayer.pauseCalls, 1);
    expect(current().sentence.start, const Duration(seconds: 2));
    await controller.stopRecording();
    await pumpEventQueue(times: 20);
  });

  test('逐句示范复用整首绝对时钟，不再叠加固定视觉延迟', () async {
    final controller = await ready();
    await controller.nextSentence();
    originalPlayer.holdPlayback = true;

    final starting = controller.startRecording();
    await pumpEventQueue(times: 20);
    expect(current().phase, SentenceDubbingPhase.demonstrating);
    for (var attempt = 0;
        attempt < 10 && !originalPlayer.playbackStarted;
        attempt++) {
      await pumpEventQueue(times: 20);
    }
    expect(originalPlayer.playbackStarted, isTrue);

    originalPlayer.emit(const Duration(milliseconds: 1900));
    await pumpEventQueue(times: 20);
    expect(current().activeWordIndex, isNull);
    originalPlayer.emit(const Duration(seconds: 2));
    await pumpEventQueue(times: 20);
    expect(current().activeWordIndex, 0);

    originalPlayer.emit(const Duration(milliseconds: 3650));
    await starting;
    await controller.stopRecording();
    await pumpEventQueue(times: 20);
  });

  test('首次打开逐句页面不等待耗时的麦克风清理', () async {
    final delayedRecorder = Completer<AudioRecordingService>();
    final isolated = ProviderContainer(overrides: [
      dubbingRepositoryProvider.overrideWith((_) async => repository),
      recordingServiceProvider.overrideWith((_) => delayedRecorder.future),
      sentenceDubbingPreparationProtocolProvider
          .overrideWithValue(_ImmediatePreparation()),
      sentenceDubbingPlaybackSettleProvider.overrideWithValue(Duration.zero),
      sentenceAudioPlayerProvider.overrideWithValue(player),
      originalAudioPlayerProvider.overrideWithValue(originalPlayer),
      scoringProvider.overrideWithValue(_Scorer()),
      originalAudioBookProvider('book-copy').overrideWith((_) async => _book()),
    ]);
    final lease = isolated.listen(
      sentenceDubbingControllerProvider('book-copy'),
      (_, __) {},
      fireImmediately: true,
    );
    try {
      final value = await isolated
          .read(sentenceDubbingControllerProvider('book-copy').future)
          .timeout(const Duration(seconds: 1));
      expect(value.phase, SentenceDubbingPhase.ready);
      expect(delayedRecorder.isCompleted, isFalse);
    } finally {
      delayedRecorder.complete(recorder);
      lease.close();
      isolated.dispose();
      await pumpEventQueue(times: 20);
    }
  });

  test('删除录音时有剩余就保留结果操作，删空后才显示开始', () async {
    final controller = await ready();
    await controller.startRecording();
    await controller.stopRecording();
    await pumpEventQueue(times: 20);
    await controller.startRecording();
    await controller.stopRecording();
    await pumpEventQueue(times: 20);

    expect(current().takes, hasLength(2));
    final selected = current().takes.singleWhere((take) => take.isSelected);
    await controller.deleteTake(selected.id);

    expect(current().takes, hasLength(1));
    expect(current().takes.single.isSelected, isTrue);
    expect(current().phase, SentenceDubbingPhase.result);
    expect(current().result?.stars, 4.5);
    expect(current().completedSentenceCount, 1);

    await controller.deleteTake(current().takes.single.id);

    expect(current().takes, isEmpty);
    expect(current().phase, SentenceDubbingPhase.ready);
    expect(current().result, isNull);
    expect(current().completedSentenceCount, 0);
  });

  test('重新录整本时只保留最后的故事，清空逐句录音并回到第 1 句', () async {
    final controller = await ready();
    repository.mixes.add(_mix());
    repository.mixes.add(_mix(
      id: 'mix-2',
      createdAt: DateTime.utc(2026, 1, 2),
    ));
    await _finishStory(controller);

    await controller.restartStory(keepMixes: true);

    expect(repository.takes, isEmpty);
    expect(current().sentenceIndex, 0);
    expect(current().completedSentenceCount, 0);
    expect(current().takes, isEmpty);
    expect(current().mixes.map((mix) => mix.id), ['mix-2']);
    expect(current().phase, SentenceDubbingPhase.ready);
  });

  test('重新录整本时可一并清除最后的故事', () async {
    final controller = await ready();
    repository.mixes.add(_mix());
    await _finishStory(controller);

    await controller.restartStory(keepMixes: false);

    expect(repository.takes, isEmpty);
    expect(repository.mixes, isEmpty);
    expect(current().mixes, isEmpty);
    expect(current().sentenceIndex, 0);
    expect(current().phase, SentenceDubbingPhase.ready);
  });

  test('结果页一次点击进入下一句并自动开始示范和录音', () async {
    final controller = await ready();
    await controller.startRecording();
    await controller.stopRecording();

    await controller.continueAndStartNextSentence();

    expect(current().sentence.id, 's2');
    expect(current().phase, SentenceDubbingPhase.recording);
    expect(originalPlayer.seeked, hasLength(2));
    await controller.stopRecording();
  });

  testWidgets('逐句儿童流程适配窄屏和 Android 平板横屏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SentenceDubbingPage(libraryId: 'book-copy'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开始这一句'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1024, 600);
    await tester.pumpAndSettle();

    expect(find.text('开始这一句'), findsOneWidget);
    expect(find.text('下一句'), findsOneWidget);
    expect(tester.getBottomRight(find.text('下一句')).dy, lessThanOrEqualTo(600));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _finishStory(SentenceDubbingController controller) async {
  await controller.startRecording();
  await controller.stopRecording();
  await controller.continueToNextSentence();
  await controller.startRecording();
  await controller.stopRecording();
}

DubbingMix _mix({String id = 'mix-1', DateTime? createdAt}) => DubbingMix(
      id: id,
      projectId: 'project',
      audioRelativePath: 'mix-1.m4a',
      variant: DubbingMixVariant.background,
      sourceTakeFingerprint: 'fingerprint',
      duration: const Duration(seconds: 4),
      createdAt: createdAt ?? DateTime.utc(2026),
    );

OriginalAudioBook _book() => OriginalAudioBook(
      libraryId: 'book-copy',
      audioPath: 'original.ogg',
      duration: const Duration(seconds: 4),
      sourceBookId: 'source-book',
      resourceSha256: 'a' * 64,
      timelineSha256: 'b' * 64,
      sentences: [
        OriginalAudioSentence(
          id: 's1',
          sequence: 1,
          text: 'Hello.',
          start: Duration.zero,
          end: const Duration(milliseconds: 800),
          words: const [
            OriginalAudioWord(
              sequence: 1,
              text: 'Hello',
              start: Duration.zero,
              end: Duration(milliseconds: 800),
            ),
          ],
        ),
        OriginalAudioSentence(
          id: 's2',
          sequence: 2,
          text: 'Goodbye.',
          start: const Duration(seconds: 2),
          end: const Duration(seconds: 3),
          words: const [
            OriginalAudioWord(
              sequence: 1,
              text: 'Goodbye',
              start: Duration(seconds: 2),
              end: Duration(seconds: 3),
            ),
          ],
        ),
      ],
    );

final class _ImmediatePreparation implements RecordingPreparationProtocol {
  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    onUpdate(const RecordingPreparationUpdate.countdown(1));
    return Duration.zero;
  }
}

final class _Recorder implements AudioRecordingService {
  _Recorder(this.directory, this.events);
  final Directory directory;
  final List<String> events;
  late String path;
  var cancelCalls = 0;

  @override
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  }) async {
    events.add('recorder.start');
    path = p.join(directory.path, 'capture.wav');
    await File(path).writeAsBytes(_wav());
    return RecordingSession(path: path, levels: const Stream.empty());
  }

  @override
  Future<String> stop() async => path;
  @override
  Future<void> cancel() async => cancelCalls++;
  @override
  Future<void> dispose() async {}
}

final class _Player implements SentenceAudioPlayer {
  _Player(this.events);

  final List<String> events;
  final played = <SentenceAudioClip>[];
  var holdPlayback = false;
  void Function(Duration elapsed)? _onPosition;
  Completer<void>? _playback;
  bool get playbackStarted => _playback != null;

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) async {
    events.add('player.play');
    played.add(clip);
    onPosition?.call(Duration.zero);
    if (holdPlayback) {
      _onPosition = onPosition;
      _playback = Completer<void>();
      await _playback!.future;
      return;
    }
    onPosition?.call(clip.end - clip.start);
  }

  void emit(Duration elapsed) => _onPosition?.call(elapsed);

  void finish() {
    final playback = _playback;
    if (playback != null && !playback.isCompleted) playback.complete();
    _playback = null;
    _onPosition = null;
  }

  @override
  Future<void> stop() async => finish();
  @override
  Future<void> dispose() async {}
}

final class _OriginalPlayer implements OriginalAudioPlayer {
  _OriginalPlayer(this.events);

  final List<String> events;
  final loadedPaths = <String>[];
  final seeked = <Duration>[];
  final _positions = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  var holdPlayback = false;
  var pauseCalls = 0;
  var stopCalls = 0;
  Completer<void>? _playback;

  bool get playbackStarted => _playback != null;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Future<void> load(String path) async => loadedPaths.add(path);

  @override
  Future<void> play() async {
    events.add('original.play');
    _playback = Completer<void>();
    _playing.add(true);
    if (holdPlayback) return _playback!.future;
    _positions.add(seeked.last);
    await pumpEventQueue(times: 20);
    _positions.add(const Duration(seconds: 10));
    _playing.add(false);
    _playback!.complete();
    _playback = null;
  }

  void emit(Duration position) => _positions.add(position);

  void interrupt() => _playing.add(false);

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
    final playback = _playback;
    if (playback != null && !playback.isCompleted) playback.complete();
    _playback = null;
  }

  @override
  Future<void> seek(Duration position) async => seeked.add(position);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    final playback = _playback;
    if (playback != null && !playback.isCompleted) playback.complete();
    _playback = null;
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {}

  Future<void> close() async {
    await _positions.close();
    await _playing.close();
  }
}

final class _Scorer implements ScoringProvider {
  @override
  String get name => 'fake';
  @override
  Future<bool> isConfigured() async => true;
  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async =>
      const ScoreResult(childScore: 90, provider: 'fake');
}

final class _Repository implements DubbingRepository {
  _Repository(this.directory);
  final Directory directory;
  final projects = <DubbingProject>[];
  final takes = <DubbingTake>[];
  final mixes = <DubbingMix>[];

  @override
  Future<DubbingProject> createProject(DubbingProjectDraft draft) async {
    final project = DubbingProject(
      id: 'project',
      libraryId: draft.libraryId,
      sourceBookId: draft.sourceBookId,
      resourceSha256: draft.resourceSha256,
      timelineSha256: draft.timelineSha256,
      mode: draft.mode,
      status: DubbingProjectStatus.draft,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    projects.add(project);
    return project;
  }

  @override
  Future<List<DubbingProject>> listProjects(String libraryId) async => projects;
  @override
  Future<DubbingProject?> findProject(String projectId) async => projects.first;
  @override
  Future<List<DubbingTake>> listTakes(String projectId,
          {String? sentenceId}) async =>
      takes
          .where((take) => sentenceId == null || take.sentenceId == sentenceId)
          .toList(growable: false);

  @override
  Future<DubbingTake> saveTake({
    required String projectId,
    required DubbingTakeKind kind,
    required File sourceAudio,
    required Duration duration,
    Duration contentOffset = Duration.zero,
    String? sentenceId,
  }) async {
    final path = p.join(directory.path, 'durable-${takes.length + 1}.wav');
    await sourceAudio.copy(path);
    final take = DubbingTake(
      id: 'take-${takes.length + 1}',
      projectId: projectId,
      sentenceId: sentenceId,
      takeKind: kind,
      audioRelativePath: p.basename(path),
      duration: duration,
      contentOffset: contentOffset,
      isSelected: false,
      scoreStatus: DubbingTakeScoreStatus.pending,
      createdAt: DateTime.utc(2026),
    );
    takes.add(take);
    return take;
  }

  @override
  Future<void> selectTake(String takeId) async {
    for (var index = 0; index < takes.length; index++) {
      final old = takes[index];
      if (old.sentenceId !=
          takes.firstWhere((take) => take.id == takeId).sentenceId) {
        continue;
      }
      takes[index] = _copyTake(old, selected: old.id == takeId);
    }
  }

  @override
  Future<void> updateTakeScore({
    required String takeId,
    required DubbingTakeScoreStatus status,
    String? scoreJson,
    String? scoreError,
  }) async {
    final index = takes.indexWhere((take) => take.id == takeId);
    if (index < 0) return;
    takes[index] = _copyTake(
      takes[index],
      scoreStatus: status,
      scoreJson: scoreJson,
      scoreError: scoreError,
    );
  }

  @override
  String resolveAudioPath(DubbingTake take) =>
      p.join(directory.path, take.audioRelativePath);
  @override
  Future<void> deleteTake(String takeId) async =>
      takes.removeWhere((take) => take.id == takeId);
  @override
  Future<void> deleteProject(String projectId) async {}
  @override
  Future<void> updateProjectStatus(
      String projectId, DubbingProjectStatus status) async {}
  @override
  Future<List<DubbingMix>> listMixes(String projectId) async =>
      mixes.where((mix) => mix.projectId == projectId).toList(growable: false);
  @override
  Future<DubbingMixOutput> prepareMixOutput(String projectId,
          {String extension = '.m4a'}) =>
      throw UnimplementedError();
  @override
  Future<DubbingMix> saveMix({
    required DubbingMixOutput output,
    required DubbingMixVariant variant,
    required String sourceTakeFingerprint,
    required Duration duration,
  }) =>
      throw UnimplementedError();
  @override
  Future<void> deleteMix(String mixId) async =>
      mixes.removeWhere((mix) => mix.id == mixId);
  @override
  String resolveMixAudioPath(DubbingMix mix) => '';
}

DubbingTake _copyTake(
  DubbingTake value, {
  bool? selected,
  DubbingTakeScoreStatus? scoreStatus,
  String? scoreJson,
  String? scoreError,
}) =>
    DubbingTake(
      id: value.id,
      projectId: value.projectId,
      sentenceId: value.sentenceId,
      takeKind: value.takeKind,
      audioRelativePath: value.audioRelativePath,
      duration: value.duration,
      contentOffset: value.contentOffset,
      isSelected: selected ?? value.isSelected,
      scoreStatus: scoreStatus ?? value.scoreStatus,
      scoreJson: scoreJson ?? value.scoreJson,
      scoreError: scoreError ?? value.scoreError,
      createdAt: value.createdAt,
    );

Uint8List _wav() {
  final pcm = Uint8List(3200);
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
