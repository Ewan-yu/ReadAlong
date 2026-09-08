import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

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

  static const _cachePrefix = 'ra_encouragement_';

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
      // just_audio's Android asset loader keeps its extracted copy in the app
      // cache across updates, so an upgraded APK can keep playing the
      // previous version's audio. Load the bytes ourselves and play from a
      // content-addressed temp file: a changed clip always gets a new name.
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final file = await _materializeCachedClip(bytes);
      await _player.setFilePath(file.path);
      await _player.play();
    } on Object {
      // A missing platform decoder must never block the score confirmation.
    }
  }

  @override
  Future<void> dispose() => _player.dispose();

  Future<File> _materializeCachedClip(Uint8List bytes) async {
    final directory = await getTemporaryDirectory();
    final name = '$_cachePrefix${md5.convert(bytes).toString()}.wav';
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
      await _removeOtherCachedClips(directory, keep: file);
    }
    return file;
  }

  Future<void> _removeOtherCachedClips(
    Directory directory, {
    required File keep,
  }) async {
    try {
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final basename = entity.uri.pathSegments.last;
        if (!basename.startsWith(_cachePrefix) || entity.path == keep.path) {
          continue;
        }
        await entity.delete();
      }
    } on Object {
      // Cache housekeeping is best-effort; stale clips are tiny.
    }
  }
}
