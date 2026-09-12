import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Shared child-facing microphone preparation protocol.
///
/// The recorder must already be capturing before [run] is called. This gives
/// Android audio processing time to settle before the child sees "开始", while
/// keeping the whole lead-in available in the WAV if the child speaks early.
enum RecordingPreparationStage { stabilizing, countdown }

final class RecordingPreparationUpdate {
  const RecordingPreparationUpdate._({
    required this.stage,
    this.countdown = 0,
  });

  const RecordingPreparationUpdate.stabilizing()
      : this._(stage: RecordingPreparationStage.stabilizing);

  const RecordingPreparationUpdate.countdown(int value)
      : this._(
          stage: RecordingPreparationStage.countdown,
          countdown: value,
        );

  final RecordingPreparationStage stage;
  final int countdown;
}

final class RecordingPreparationCancelled implements Exception {
  const RecordingPreparationCancelled();
}

abstract interface class RecordingPreparationProtocol {
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  });
}

final recordingPreparationProtocolProvider =
    Provider<RecordingPreparationProtocol>(
  (_) => const TimedRecordingPreparationProtocol(),
);

/// Follow reading uses the stabilization-only protocol for every take: the
/// WAV still captures everything from recorder start and the content zero is
/// the capture start, so a child who speaks early is never cut.
final followQuickPreparationProtocolProvider =
    Provider<RecordingPreparationProtocol>(
  (_) => const TimedRecordingPreparationProtocol(
    stabilization: Duration(milliseconds: 650),
    beatDuration: Duration.zero,
    countdownBeats: 0,
  ),
);

/// Sentence dubbing starts capture before playing the demonstration. By the
/// time the child has listened, Android's microphone is already stable, so a
/// single short hand-off beat is enough instead of repeating 3-2-1 every time.
final sentenceDubbingPreparationProtocolProvider =
    Provider<RecordingPreparationProtocol>(
  (_) => const TimedRecordingPreparationProtocol(
    stabilization: Duration.zero,
    beatDuration: Duration(milliseconds: 650),
    countdownBeats: 1,
  ),
);

final class TimedRecordingPreparationProtocol
    implements RecordingPreparationProtocol {
  const TimedRecordingPreparationProtocol({
    this.stabilization = const Duration(milliseconds: 650),
    this.beatDuration = const Duration(seconds: 1),
    this.countdownBeats = 3,
  });

  final Duration stabilization;
  final Duration beatDuration;
  final int countdownBeats;

  @override
  Future<Duration> run({
    required bool Function() isActive,
    required void Function(RecordingPreparationUpdate update) onUpdate,
  }) async {
    if (!isActive()) throw const RecordingPreparationCancelled();
    final clock = Stopwatch()..start();
    onUpdate(const RecordingPreparationUpdate.stabilizing());
    await Future<void>.delayed(stabilization);
    _requireActive(isActive);
    for (var beat = countdownBeats; beat >= 1; beat--) {
      onUpdate(RecordingPreparationUpdate.countdown(beat));
      await Future<void>.delayed(beatDuration);
      _requireActive(isActive);
    }
    clock.stop();
    return clock.elapsed;
  }
}

void _requireActive(bool Function() isActive) {
  if (!isActive()) throw const RecordingPreparationCancelled();
}
