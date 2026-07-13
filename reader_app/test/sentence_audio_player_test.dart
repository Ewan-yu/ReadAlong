import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/sentence_audio_player.dart';

final class _FakeSentenceAudioEngine implements SentenceAudioEngine {
  final configured = <({String path, Duration start, Duration end})>[];
  var stopCalls = 0;
  var disposeCalls = 0;
  Object? configureFailure;
  Completer<void>? playCompleter;

  @override
  Future<void> configureClip({
    required String path,
    required Duration start,
    required Duration end,
  }) async {
    final failure = configureFailure;
    if (failure != null) throw failure;
    configured.add((path: path, start: start, end: end));
  }

  @override
  Future<void> play() => playCompleter?.future ?? Future.value();

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

void main() {
  late Directory tempDir;
  late File audioFile;
  late _FakeSentenceAudioEngine engine;
  late JustAudioSentencePlayer player;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sentence_audio_');
    audioFile = await File('${tempDir.path}/sentence.ogg').writeAsBytes([1, 2]);
    engine = _FakeSentenceAudioEngine();
    player = JustAudioSentencePlayer(engine: engine);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  SentenceAudioClip clip({String? path}) => SentenceAudioClip(
        path: path ?? audioFile.path,
        start: const Duration(milliseconds: 250),
        end: const Duration(milliseconds: 1400),
      );

  test('配置本地文件裁剪区间后等待播放完成', () async {
    engine.playCompleter = Completer<void>();
    var completed = false;

    final playing = player.play(clip()).then((_) => completed = true);
    await pumpEventQueue();

    expect(
      engine.configured,
      [
        (
          path: audioFile.path,
          start: const Duration(milliseconds: 250),
          end: const Duration(milliseconds: 1400),
        ),
      ],
    );
    expect(completed, isFalse);

    engine.playCompleter!.complete();
    await playing;
    expect(completed, isTrue);
  });

  test('stop 委托给音频引擎', () async {
    await player.stop();

    expect(engine.stopCalls, 1);
  });

  test('dispose 幂等且释放后拒绝再次播放', () async {
    await player.dispose();
    await player.dispose();

    expect(engine.disposeCalls, 1);
    expect(
      () => player.play(clip()),
      throwsA(isA<SentencePlaybackException>()),
    );
  });

  test('音频文件缺失时不调用平台引擎', () async {
    final missing = '${tempDir.path}/missing.ogg';

    expect(
      () => player.play(clip(path: missing)),
      throwsA(isA<SentencePlaybackException>()),
    );
    expect(engine.configured, isEmpty);
  });

  test('解码或平台异常映射为不泄露路径的播放异常', () async {
    engine.configureFailure = StateError('decoder failed at ${audioFile.path}');

    try {
      await player.play(clip());
      fail('Expected SentencePlaybackException');
    } on SentencePlaybackException catch (error) {
      expect(error.message, isNot(contains(audioFile.path)));
      expect(error.message, isNot(contains('decoder')));
    }
  });
}
