import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as just_audio;

import 'point_reading_models.dart';

abstract interface class SentenceAudioPlayer {
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  });

  Future<void> stop();

  Future<void> dispose();
}

abstract interface class SentenceAudioEngine {
  Stream<Duration> get positionStream;

  Future<void> configureClip({
    required String path,
    required Duration start,
    required Duration end,
    required bool wholeFile,
  });

  Future<void> play();

  Future<void> stop();

  Future<void> dispose();
}

final class SentencePlaybackException implements Exception {
  const SentencePlaybackException([
    this.message = 'This sentence cannot be played',
  ]);

  final String message;

  @override
  String toString() => 'SentencePlaybackException: $message';
}

final sentenceAudioPlayerProvider =
    Provider.autoDispose<SentenceAudioPlayer>((ref) {
  final player = JustAudioSentencePlayer();
  ref.onDispose(() => unawaited(_stopAndDispose(player)));
  return player;
});

Future<void> _stopAndDispose(SentenceAudioPlayer player) async {
  try {
    await player.stop();
  } on Object {
    // Provider cleanup must not surface plugin failures after the page closes.
  }
  try {
    await player.dispose();
  } on Object {
    // The player is already unreachable; there is no recovery action here.
  }
}

final class JustAudioSentencePlayer implements SentenceAudioPlayer {
  JustAudioSentencePlayer({SentenceAudioEngine? engine})
      : _engine = engine ?? _JustAudioSentenceAudioEngine();

  final SentenceAudioEngine _engine;
  var _disposed = false;

  @override
  Future<void> play(
    SentenceAudioClip clip, {
    void Function(Duration elapsed)? onPosition,
  }) async {
    if (_disposed) throw const SentencePlaybackException();
    StreamSubscription<Duration>? positionSubscription;
    try {
      if (!await File(clip.path).exists()) {
        throw const SentencePlaybackException();
      }
      await _engine.configureClip(
        path: clip.path,
        start: clip.start,
        end: clip.end,
        wholeFile: clip.wholeFile,
      );
      final positionFailure = Completer<void>();
      if (onPosition != null) {
        final clipDuration = clip.end - clip.start;
        var lastPosition = Duration.zero;
        positionSubscription = _engine.positionStream.listen(
          (position) {
            final clamped = _clampPosition(position, clipDuration);
            if (clamped == lastPosition) return;
            lastPosition = clamped;
            onPosition(clamped);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!positionFailure.isCompleted) {
              positionFailure.completeError(error, stackTrace);
            }
          },
        );
        onPosition(Duration.zero);
        await Future.any([_engine.play(), positionFailure.future]);
      } else {
        await _engine.play();
      }
    } on SentencePlaybackException {
      rethrow;
    } on Object {
      try {
        await _engine.stop();
      } on Object {
        // Preserve the original playback/position failure.
      }
      throw const SentencePlaybackException();
    } finally {
      await positionSubscription?.cancel();
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await _engine.stop();
    } on Object {
      throw const SentencePlaybackException();
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _engine.dispose();
    } on Object {
      throw const SentencePlaybackException();
    }
  }
}

final class _JustAudioSentenceAudioEngine implements SentenceAudioEngine {
  final just_audio.AudioPlayer _player = just_audio.AudioPlayer();

  @override
  Stream<Duration> get positionStream => _player.createPositionStream(
        minPeriod: const Duration(milliseconds: 60),
        maxPeriod: const Duration(milliseconds: 60),
      );

  @override
  Future<void> configureClip({
    required String path,
    required Duration start,
    required Duration end,
    required bool wholeFile,
  }) async {
    if (wholeFile) {
      await _player.setAudioSource(just_audio.AudioSource.file(path));
      return;
    }
    await _player.setAudioSource(
      just_audio.ClippingAudioSource(
        child: just_audio.AudioSource.file(path),
        start: start,
        end: end,
      ),
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

Duration _clampPosition(Duration position, Duration clipDuration) {
  if (position < Duration.zero) return Duration.zero;
  if (position > clipDuration) return clipDuration;
  return position;
}
