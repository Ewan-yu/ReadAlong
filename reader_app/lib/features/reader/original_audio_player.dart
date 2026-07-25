import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

abstract interface class OriginalAudioPlayer {
  Stream<Duration> get positionStream;
  Stream<bool> get playingStream;

  Future<void> load(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// 停止并释放系统解码资源。页面返回和进入后台都必须调用它。
  Future<void> stop();
  Future<void> dispose();
}

abstract interface class OriginalAudioEngine {
  Stream<Duration> get positionStream;
  Stream<bool> get playingStream;

  Future<void> setFile(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

final originalAudioPlayerProvider =
    Provider.autoDispose<OriginalAudioPlayer>((ref) {
  final player = JustAudioOriginalAudioPlayer();
  ref.onDispose(() => unawaited(_release(player)));
  return player;
});

Future<void> _release(OriginalAudioPlayer player) async {
  try {
    await player.stop();
  } on Object {
    // Route teardown cannot report a platform decoder error to the child.
  }
  try {
    await player.dispose();
  } on Object {
    // The player is no longer reachable.
  }
}

final class OriginalAudioPlaybackException implements Exception {
  const OriginalAudioPlaybackException(
      [this.message = 'Original audio cannot be played']);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

final class JustAudioOriginalAudioPlayer implements OriginalAudioPlayer {
  JustAudioOriginalAudioPlayer({OriginalAudioEngine? engine})
      : _engine = engine ?? _JustAudioOriginalAudioEngine();

  final OriginalAudioEngine _engine;
  var _disposed = false;

  @override
  Stream<Duration> get positionStream => _engine.positionStream;

  @override
  Stream<bool> get playingStream => _engine.playingStream;

  void _ensureActive() {
    if (_disposed) throw const OriginalAudioPlaybackException();
  }

  @override
  Future<void> load(String path) async {
    _ensureActive();
    if (!await File(path).exists()) {
      throw OriginalAudioPlaybackException('Playback file is missing: $path');
    }
    try {
      await _engine.setFile(path);
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Audio decoder failed: $error');
    }
  }

  @override
  Future<void> pause() async {
    _ensureActive();
    try {
      await _engine.pause();
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Pause failed: $error');
    }
  }

  @override
  Future<void> play() async {
    _ensureActive();
    try {
      await _engine.play();
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Play failed: $error');
    }
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureActive();
    try {
      await _engine.seek(position);
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Seek failed: $error');
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _engine.stop();
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Stop failed: $error');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _engine.dispose();
    } on Object catch (error) {
      throw OriginalAudioPlaybackException('Dispose failed: $error');
    }
  }
}

final class _JustAudioOriginalAudioEngine implements OriginalAudioEngine {
  final just_audio.AudioPlayer _player = just_audio.AudioPlayer();

  @override
  Stream<Duration> get positionStream => _player.createPositionStream(
        minPeriod: const Duration(milliseconds: 60),
        maxPeriod: const Duration(milliseconds: 60),
      );

  @override
  Stream<bool> get playingStream =>
      _player.playerStateStream.map((state) => state.playing).distinct();

  @override
  Future<void> setFile(String path) =>
      _player.setAudioSource(just_audio.AudioSource.file(path));

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}
