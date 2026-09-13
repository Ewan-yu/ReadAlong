import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:reader_app/features/dubbing/dubbing_repository.dart';
import 'package:reader_app/features/dubbing/full_dubbing_controller.dart';
import 'package:reader_app/features/dubbing/full_dubbing_page.dart';
import 'package:reader_app/features/reader/original_audio_models.dart';
import 'package:reader_app/features/reader/original_audio_repository.dart';
import 'package:reader_app/features/reader/original_audio_player.dart';
import 'package:reader_app/services/audio/dubbing_mix_service.dart';
import 'package:reader_app/services/recording/recording_service.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/scoring_provider.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart'
    show scoringProvider;

void main() {
  late Directory temporary;
  late _MemoryDubbingRepository repository;
  late ProviderContainer container;
  late _ControlledPreparation preparation;
  late _OriginalPlayer audioPlayer;
  late _GatedScorer scorer;
  late _MixService mixService;
  ProviderSubscription<AsyncValue<FullDubbingState>>? subscription;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('full_dubbing_test_');
    repository = _MemoryDubbingRepository(temporary);
    preparation = _ControlledPreparation();
    audioPlayer = _OriginalPlayer();
    scorer = _GatedScorer();
    mixService = _MixService();
    container = ProviderContainer(overrides: [
      dubbingRepositoryProvider.overrideWith((_) async => repository),
      recordingServiceProvider.overrideWith((_) async => _Recorder(temporary)),
      originalAudioPlayerProvider.overrideWithValue(audioPlayer),
      dubbingMixServiceProvider.overrideWithValue(mixService),
      recordingPreparationProtocolProvider.overrideWithValue(preparation),
      scoringProvider.overrideWithValue(scorer),
      originalAudioBookProvider('book-copy').overrideWith((_) async => _book()),
    ]);
  });

  tearDown(() async {
    subscription?.close();
    container.dispose();
    await pumpEventQueue();
    await audioPlayer.close();
    await temporary.delete(recursive: true);
  });

  Future<FullDubbingController> ready() async {
    subscription = container.listen(
        fullDubbingControllerProvider('book-copy'), (_, __) {},
        fireImmediately: true);
    await container.read(fullDubbingControllerProvider('book-copy').future);
    return container.read(fullDubbingControllerProvider('book-copy').notifier);
  }

  FullDubbingState current() =>
      container.read(fullDubbingControllerProvider('book-copy')).requireValue;

  test('完整配音创建独立 full 项目，录音默认自动保存为草稿', () async {
    await ready();

    expect(current().project.mode, DubbingMode.full);
    expect(current().project.status, DubbingProjectStatus.draft);
    expect(repository.statuses, isEmpty);
  });

  test('三秒倒计时可取消，未触发录音', () async {
    final controller = await ready();

    final starting = controller.startCountdown();
    for (var attempt = 0;
        attempt < 20 && current().phase != FullDubbingPhase.countdown;
        attempt++) {
      await pumpEventQueue();
    }
    expect(current().phase, FullDubbingPhase.countdown);
    expect(current().countdown, 3);
    await controller.cancelCountdown();
    preparation.release();
    await starting;

    expect(current().phase, FullDubbingPhase.ready);
    expect(current().countdown, 0);
  });

  test('内容零点覆盖背景加载耗时，不再只等于准备时长', () async {
    final controller = await ready();
    audioPlayer.loadDelayMs = 300;

    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;

    expect(current().phase, FullDubbingPhase.recording);
    await controller.stopRecording();

    expect(current().phase, FullDubbingPhase.ready);
    expect(current().takes, hasLength(1));
    // 模拟低端设备 300ms 的背景轨解码:存出的内容零点必须包含它。
    final offsetMs = current().takes.single.contentOffset.inMilliseconds;
    expect(offsetMs, greaterThanOrEqualTo(300));
    expect(offsetMs, lessThan(10000));
    expect(current().takes.single.isSelected, isTrue);
  });

  test('Android 切后台会停止完整录音并保留 Take', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;

    await controller.handleAppBackgrounded();

    expect(current().takes, hasLength(1));
    expect(current().failure, contains('安全保存'));
  });

  test('原音在完整配音页内试听并可暂停继续', () async {
    final controller = await ready();

    await controller.toggleOriginalPreview();

    expect(current().playbackKind, FullDubbingPlaybackKind.original);
    expect(current().audioPlaying, isTrue);
    expect(audioPlayer.loadedPaths.last, 'original.mp3');
    expect(audioPlayer.volumes.last, 1);

    await controller.toggleOriginalPreview();
    expect(current().audioPlaying, isFalse);
    expect(audioPlayer.pauseCalls, 1);

    await controller.toggleOriginalPreview();
    expect(current().audioPlaying, isTrue);
    expect(audioPlayer.loadedPaths.where((path) => path == 'original.mp3'),
        hasLength(1));
  });

  test('完整 Take 从内容零点回放，同一按钮可暂停和继续', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();
    final take = current().takes.single;

    await controller.playTake(take);

    expect(current().playbackKind, FullDubbingPlaybackKind.take);
    expect(current().playbackId, take.id);
    expect(current().audioPlaying, isTrue);
    expect(audioPlayer.seeked.last, take.contentOffset);
    expect(audioPlayer.volumes.last, 1);

    await controller.playTake(take);
    expect(current().audioPlaying, isFalse);

    await controller.playTake(take);
    expect(current().audioPlaying, isTrue);
  });

  test('Android 播放 Future 未结束时，暂停按钮仍立即可用', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();
    final take = current().takes.single;
    audioPlayer.holdPlayback = true;

    expect(await controller.playTake(take), isTrue);
    expect(current().audioPlaying, isTrue);
    expect(audioPlayer.pendingPlayback, isNotNull);

    expect(await controller.playTake(take), isTrue);
    expect(current().audioPlaying, isFalse);
    expect(audioPlayer.pauseCalls, 1);
  });

  test('生成可回放作品后才把完整故事标为完成', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();

    await controller.createMix();

    expect(current().mixes, hasLength(1));
    expect(current().isComplete, isTrue);
    expect(repository.statuses.last, DubbingProjectStatus.complete);
  });

  test('录音伴奏自动降低到 35% 音量，减少扬声器回录', () async {
    final controller = await ready();

    final starting = controller.startCountdown();
    for (var attempt = 0;
        attempt < 20 && audioPlayer.loadedPaths.isEmpty;
        attempt++) {
      await pumpEventQueue();
    }

    expect(audioPlayer.loadedPaths.last, 'original/background.ogg');
    expect(audioPlayer.volumes.last, closeTo(.35, .0001));

    preparation.release();
    await starting;
    await controller.stopRecording();
  });

  test('整轨评分在页面退出后不再发起后续评分请求', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();
    final take = current().takes.single;
    await File(repository.resolveAudioPath(take))
        .writeAsBytes(_minimalWav(4000));

    final scoring = controller.scoreTake(take);
    await _until(() => scorer.requests.isNotEmpty);
    expect(scorer.requests, hasLength(1));

    container.invalidate(fullDubbingControllerProvider('book-copy'));
    scorer.releaseAll();
    await scoring;

    expect(scorer.requests, hasLength(1));
  });

  test('评分准备窗口内重复触发不会并发两轮评分', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();
    final take = current().takes.single;
    await File(repository.resolveAudioPath(take))
        .writeAsBytes(_minimalWav(4000));

    audioPlayer.holdStop = true;
    final first = controller.scoreTake(take);
    await pumpEventQueue();
    // 第二次触发落在停止回放的 await 窗口内，phase 尚未进入 scoring。
    await controller.scoreTake(take);
    audioPlayer.releaseStop();
    scorer.autoRelease = true;
    await first;

    expect(scorer.requests, hasLength(3));
  });

  test('生成作品准备窗口内连点只渲染一次作品', () async {
    final controller = await ready();
    final starting = controller.startCountdown();
    await pumpEventQueue();
    preparation.release();
    await starting;
    await controller.stopRecording();

    audioPlayer.holdStop = true;
    final first = controller.createMix();
    await pumpEventQueue();
    // 第二次点击落在停止回放的 await 窗口内，phase 尚未进入 mixing。
    await controller.createMix();
    audioPlayer.releaseStop();
    await first;

    expect(mixService.renderCalls, 1);
    expect(current().mixes, hasLength(1));
  });

  testWidgets('完整配音入口适配窄屏和 Android 平板横屏', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: FullDubbingPage(libraryId: 'book-copy'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('开始完整配音'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1024, 600);
    await tester.pumpAndSettle();

    expect(find.text('开始完整配音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

OriginalAudioBook _book() => OriginalAudioBook(
      libraryId: 'book-copy',
      audioPath: 'original.mp3',
      duration: const Duration(minutes: 1),
      sourceBookId: 'source-book',
      resourceSha256: 'a' * 64,
      timelineSha256: 'b' * 64,
      backgroundPath: 'original/background.ogg',
      sentences: [
        OriginalAudioSentence(
            id: 's1',
            sequence: 1,
            text: 'Hello.',
            start: Duration.zero,
            end: const Duration(seconds: 1),
            words: [
              const OriginalAudioWord(
                  sequence: 1,
                  text: 'Hello',
                  start: Duration.zero,
                  end: const Duration(seconds: 1))
            ]),
        OriginalAudioSentence(
            id: 's2',
            sequence: 2,
            text: 'World.',
            start: const Duration(seconds: 1),
            end: const Duration(seconds: 2),
            words: [
              const OriginalAudioWord(
                  sequence: 1,
                  text: 'World',
                  start: const Duration(seconds: 1),
                  end: const Duration(seconds: 2))
            ]),
        OriginalAudioSentence(
            id: 's3',
            sequence: 3,
            text: 'Again.',
            start: const Duration(seconds: 2),
            end: const Duration(seconds: 3),
            words: [
              const OriginalAudioWord(
                  sequence: 1,
                  text: 'Again',
                  start: const Duration(seconds: 2),
                  end: const Duration(seconds: 3))
            ]),
      ],
    );

/// Minimal 16 kHz / mono / 16-bit PCM WAV accepted by [parseWavPcm16].
Uint8List _minimalWav(int milliseconds) {
  final dataBytes = milliseconds * 32; // 16 kHz × 2 bytes per sample.
  final bytes = ByteData(44 + dataBytes);
  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes.setUint8(offset + index, value.codeUnitAt(index));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  return bytes.buffer.asUint8List();
}

final class _GatedScorer implements ScoringProvider {
  final requests = <String>[];
  final _gates = <Completer<void>>[];
  var autoRelease = false;

  void releaseAll() {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  String get name => 'gated';

  @override
  Future<bool> isConfigured() async => true;

  @override
  Future<ScoreResult> score({
    required Uint8List pcm16k,
    required String refText,
  }) async {
    requests.add(refText);
    if (autoRelease) {
      return ScoreResult(childScore: 80, provider: name);
    }
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    return ScoreResult(childScore: 80, provider: name);
  }
}

/// Real file IO cannot be advanced by microtask pumping alone, so bounded
/// 1 ms real yields are required (same pattern as sentence dubbing tests).
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('条件等待超时');
    }
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

final class _Recorder implements AudioRecordingService {
  _Recorder(this.directory);
  final Directory directory;
  @override
  Future<RecordingSession> start(
      {required String libraryId, required String sentenceId}) async {
    final path = p.join(directory.path, 'temporary.wav');
    await File(path).writeAsBytes([1, 2, 3]);
    return RecordingSession(path: path, levels: const Stream.empty());
  }

  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<String> stop() async => p.join(directory.path, 'temporary.wav');
}

final class _OriginalPlayer implements OriginalAudioPlayer {
  final positions = StreamController<Duration>.broadcast(sync: true);
  final playing = StreamController<bool>.broadcast(sync: true);
  final loadedPaths = <String>[];
  final seeked = <Duration>[];
  final volumes = <double>[];
  var playCalls = 0;
  var pauseCalls = 0;
  var holdPlayback = false;
  var holdStop = false;
  var loadDelayMs = 0;
  Completer<void>? pendingPlayback;
  Completer<void>? _stopGate;

  void releaseStop() {
    final gate = _stopGate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Stream<bool> get playingStream => playing.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Future<void> dispose() async {}
  @override
  Future<void> load(String path) async {
    if (loadDelayMs > 0) {
      // Simulates the decoder preparation cost of a low-end device.
      await Future<void>.delayed(Duration(milliseconds: loadDelayMs));
    }
    loadedPaths.add(path);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    final pending = pendingPlayback;
    if (pending != null) {
      if (!pending.isCompleted) pending.complete();
      pendingPlayback = null;
    }
    playing.add(false);
  }

  @override
  Future<void> play() async {
    playCalls++;
    playing.add(true);
    if (holdPlayback) {
      pendingPlayback = Completer<void>();
      await pendingPlayback!.future;
    }
  }

  @override
  Future<void> seek(Duration position) async => seeked.add(position);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> stop() async {
    if (holdStop) {
      _stopGate = Completer<void>();
      await _stopGate!.future;
    }
    final pending = pendingPlayback;
    if (pending != null) {
      if (!pending.isCompleted) pending.complete();
      pendingPlayback = null;
    }
    playing.add(false);
  }

  Future<void> close() async {
    await positions.close();
    await playing.close();
  }
}

final class _ControlledPreparation implements RecordingPreparationProtocol {
  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    onUpdate(const RecordingPreparationUpdate.countdown(3));
    await _gate.future;
    if (!isActive()) throw const RecordingPreparationCancelled();
    return const Duration(milliseconds: 650);
  }
}

final class _MixService implements DubbingMixService {
  var renderCalls = 0;

  @override
  Future<DubbingMixResult> render(DubbingMixPlan plan) async {
    renderCalls++;
    final output = File(plan.outputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes([1, 2, 3]);
    return DubbingMixResult(
      outputPath: output.path,
      mode: plan.mode,
      duration: plan.renderDuration,
    );
  }
}

final class _MemoryDubbingRepository implements DubbingRepository {
  _MemoryDubbingRepository(this.directory);
  final Directory directory;
  final projects = <DubbingProject>[];
  final takes = <DubbingTake>[];
  final mixes = <DubbingMix>[];
  final statuses = <DubbingProjectStatus>[];

  @override
  Future<DubbingProject> createProject(DubbingProjectDraft draft) async {
    final project = DubbingProject(
        id: 'full-project',
        libraryId: draft.libraryId,
        sourceBookId: draft.sourceBookId,
        resourceSha256: draft.resourceSha256,
        timelineSha256: draft.timelineSha256,
        mode: draft.mode,
        status: DubbingProjectStatus.draft,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026));
    projects.add(project);
    return project;
  }

  @override
  Future<void> deleteProject(String projectId) async {}
  @override
  Future<void> deleteTake(String takeId) async {}
  @override
  Future<void> deleteMix(String mixId) async {}
  @override
  Future<DubbingProject?> findProject(String projectId) async =>
      projects.where((value) => value.id == projectId).firstOrNull;
  @override
  Future<List<DubbingProject>> listProjects(String libraryId) async => projects;
  @override
  Future<List<DubbingTake>> listTakes(String projectId,
          {String? sentenceId}) async =>
      takes;
  @override
  Future<List<DubbingMix>> listMixes(String projectId) async => mixes;
  @override
  Future<DubbingMixOutput> prepareMixOutput(String projectId,
          {String extension = '.m4a'}) async =>
      DubbingMixOutput(
        id: 'mix-1',
        projectId: projectId,
        relativePath: 'dubbing/book/$projectId/mixes/mix-1$extension',
        absolutePath: p.join(
          directory.path,
          'dubbing',
          'book',
          projectId,
          'mixes',
          'mix-1$extension',
        ),
      );
  @override
  String resolveAudioPath(DubbingTake take) =>
      p.join(directory.path, take.audioRelativePath);
  @override
  String resolveMixAudioPath(DubbingMix mix) =>
      p.join(directory.path, mix.audioRelativePath);
  @override
  Future<DubbingTake> saveTake({
    required String projectId,
    required DubbingTakeKind kind,
    required File sourceAudio,
    required Duration duration,
    Duration contentOffset = Duration.zero,
    String? sentenceId,
  }) async {
    final filename = 'take-${takes.length + 1}.wav';
    final relativePath = kind == DubbingTakeKind.full
        ? 'dubbing/book/$projectId/takes/full/$filename'
        : 'dubbing/book/$projectId/takes/${sentenceId!}/$filename';
    final absolutePath =
        p.joinAll([directory.path, ...relativePath.split('/')]);
    await File(absolutePath).parent.create(recursive: true);
    await sourceAudio.copy(absolutePath);
    final take = DubbingTake(
      id: 'take-${takes.length + 1}',
      projectId: projectId,
      sentenceId: sentenceId,
      takeKind: kind,
      audioRelativePath: relativePath,
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
  Future<DubbingMix> saveMix({
    required DubbingMixOutput output,
    required DubbingMixVariant variant,
    required String sourceTakeFingerprint,
    required Duration duration,
  }) async {
    final mix = DubbingMix(
      id: output.id,
      projectId: output.projectId,
      audioRelativePath: output.relativePath,
      variant: variant,
      sourceTakeFingerprint: sourceTakeFingerprint,
      duration: duration,
      createdAt: DateTime.utc(2026),
    );
    mixes.insert(0, mix);
    return mix;
  }

  @override
  Future<void> selectTake(String takeId) async {
    for (var index = 0; index < takes.length; index++) {
      final old = takes[index];
      takes[index] = DubbingTake(
        id: old.id,
        projectId: old.projectId,
        sentenceId: old.sentenceId,
        takeKind: old.takeKind,
        audioRelativePath: old.audioRelativePath,
        duration: old.duration,
        contentOffset: old.contentOffset,
        isSelected: old.id == takeId,
        scoreStatus: old.scoreStatus,
        scoreJson: old.scoreJson,
        scoreError: old.scoreError,
        createdAt: old.createdAt,
      );
    }
  }

  @override
  Future<void> updateProjectStatus(
      String projectId, DubbingProjectStatus status) async {
    statuses.add(status);
    final index = projects.indexWhere((value) => value.id == projectId);
    final old = projects[index];
    projects[index] = DubbingProject(
        id: old.id,
        libraryId: old.libraryId,
        sourceBookId: old.sourceBookId,
        resourceSha256: old.resourceSha256,
        timelineSha256: old.timelineSha256,
        mode: old.mode,
        status: status,
        createdAt: old.createdAt,
        updatedAt: DateTime.utc(2026, 1, 2));
  }

  @override
  Future<void> updateTakeScore(
      {required String takeId,
      required DubbingTakeScoreStatus status,
      String? scoreJson,
      String? scoreError}) async {}
}
