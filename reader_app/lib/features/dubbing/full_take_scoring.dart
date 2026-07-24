import 'dart:io';
import 'dart:typed_data';

import '../../services/recording/recording_service.dart';
import '../../services/scoring/score_models.dart';
import '../../services/scoring/scoring_provider.dart';
import '../reader/original_audio_models.dart';

/// Scores a full-recording Take against original-audio absolute sentence
/// ranges.  The WAV is PCM16/16k/mono, so slices are held only in memory and
/// immediately discarded after each provider call.
final class FullTakeScorer {
  const FullTakeScorer(this._provider);

  final ScoringProvider _provider;

  Future<FullTakeScoreReport> score({
    required File audio,
    required List<OriginalAudioSentence> sentences,
  }) async {
    final pcm = parseWavPcm16(await audio.readAsBytes()).pcm16k;
    final results = <FullTakeSentenceScore>[];
    for (final sentence in sentences) {
      final slice = pcm16SliceForRange(pcm, sentence.start, sentence.end);
      if (slice.isEmpty) {
        results.add(FullTakeSentenceScore.failed(
          sentenceId: sentence.id,
          message: '这一句没有录到足够的声音。',
        ));
        continue;
      }
      try {
        final score =
            await _provider.score(pcm16k: slice, refText: sentence.text);
        results.add(FullTakeSentenceScore.scored(sentence.id, score));
      } on ScoringException catch (error) {
        results.add(FullTakeSentenceScore.failed(
          sentenceId: sentence.id,
          message: error.message,
        ));
      } on Object {
        results.add(FullTakeSentenceScore.failed(
          sentenceId: sentence.id,
          message: '评分暂时不可用，录音已保留。',
        ));
      }
    }
    return FullTakeScoreReport(results);
  }
}

/// Returns raw PCM for [start, end], with no file creation or side effects.
/// The recorder contract is 16 kHz / mono / signed 16-bit little-endian.
Uint8List pcm16SliceForRange(Uint8List pcm, Duration start, Duration end) {
  if (start < Duration.zero || end <= start) return Uint8List(0);
  const bytesPerMillisecond = 32; // 16000 samples/s × 2 bytes/sample.
  final startOffset =
      (start.inMilliseconds * bytesPerMillisecond).clamp(0, pcm.length).toInt();
  final endOffset =
      (end.inMilliseconds * bytesPerMillisecond).clamp(0, pcm.length).toInt();
  if (endOffset <= startOffset) return Uint8List(0);
  return Uint8List.sublistView(pcm, startOffset, endOffset);
}

final class FullTakeScoreReport {
  FullTakeScoreReport(List<FullTakeSentenceScore> sentences)
      : sentences = List.unmodifiable(sentences);

  final List<FullTakeSentenceScore> sentences;
  int get scoredCount => sentences.where((item) => item.score != null).length;
  int get totalCount => sentences.length;

  Map<String, Object?> toJson() => {
        'schema_version': 1,
        'scored_count': scoredCount,
        'total_count': totalCount,
        'sentences': [for (final item in sentences) item.toJson()],
      };
}

final class FullTakeSentenceScore {
  const FullTakeSentenceScore._({
    required this.sentenceId,
    this.score,
    this.failure,
  });

  factory FullTakeSentenceScore.scored(String sentenceId, ScoreResult score) =>
      FullTakeSentenceScore._(sentenceId: sentenceId, score: score);
  factory FullTakeSentenceScore.failed({
    required String sentenceId,
    required String message,
  }) =>
      FullTakeSentenceScore._(sentenceId: sentenceId, failure: message);

  final String sentenceId;
  final ScoreResult? score;
  final String? failure;

  Map<String, Object?> toJson() => {
        'sentence_id': sentenceId,
        if (score != null) ...{
          'child_score': score!.childScore,
          'provider': score!.provider,
          'words': [
            for (final word in score!.words)
              {'word': word.word, 'accuracy': word.accuracy},
          ],
        } else
          'failure': failure,
      };
}
