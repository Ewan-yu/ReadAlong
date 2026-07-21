import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// Short, local voice prompts shown after a follow-reading result.  Keeping
/// these assets in the app makes the encouragement immediate and reliable
/// even when the scoring network is unavailable afterwards.
abstract interface class EncouragementAudioPlayer {
  Future<void> playForStars(double stars);

  Future<void> dispose();
}

final encouragementAudioPlayerProvider =
    Provider<EncouragementAudioPlayer>((ref) {
  final player = AssetEncouragementAudioPlayer();
  ref.onDispose(() => unawaited(player.dispose()));
  return player;
});

final class AssetEncouragementAudioPlayer implements EncouragementAudioPlayer {
  AssetEncouragementAudioPlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> playForStars(double stars) async {
    final asset = switch (stars) {
      < 2.5 => 'assets/audio/encouragement/keep_trying.wav',
      < 4.0 => 'assets/audio/encouragement/good_job.wav',
      _ => 'assets/audio/encouragement/great_job.wav',
    };
    try {
      await _player.stop();
      await _player.setAsset(asset);
      await _player.play();
    } on Object {
      // A missing platform decoder must never block the score confirmation.
    }
  }

  @override
  Future<void> dispose() => _player.dispose();
}
