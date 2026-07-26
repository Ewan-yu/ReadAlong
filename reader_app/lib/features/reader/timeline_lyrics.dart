import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'original_audio_models.dart';
import 'point_reading_models.dart';
import 'subtitle_timing.dart';

/// Shared large-type lyrics for original listening and both dubbing modes.
/// Keeping one renderer prevents word highlighting and punctuation handling
/// from drifting between child-facing audio experiences.
class TimelineLyrics extends StatelessWidget {
  const TimelineLyrics({
    super.key,
    required this.sentences,
    required this.currentIndex,
    required this.activeWordIndex,
    this.onSentenceTap,
    this.currentFontSize = AppSizes.originalAudioCurrentLyric,
    this.neighbourFontSize = AppSizes.originalAudioNeighbourLyric,
    this.semanticLabel = '歌词',
    this.compact = false,
  });

  final List<OriginalAudioSentence> sentences;
  final int currentIndex;
  final int? activeWordIndex;
  final ValueChanged<int>? onSentenceTap;
  final double currentFontSize;
  final double neighbourFontSize;
  final String semanticLabel;

  /// Uses tighter vertical spacing for embedded previews with a bounded
  /// height. Full-screen lyrics keep the larger child-friendly touch targets.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final previous = currentIndex > 0 ? sentences[currentIndex - 1] : null;
    final current = sentences[currentIndex];
    final next = currentIndex + 1 < sentences.length
        ? sentences[currentIndex + 1]
        : null;
    return Semantics(
      label: '$semanticLabel，第 ${currentIndex + 1} 句，共 ${sentences.length} 句',
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? AppSpacing.cardPadding : AppSpacing.pageMargin,
        ),
        child: Column(
          key: const ValueKey('original-audio-lyrics'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (previous != null)
              _NeighbourLyric(
                sentence: previous,
                fontSize: neighbourFontSize,
                compact: compact,
                onTap: onSentenceTap == null
                    ? null
                    : () => onSentenceTap!(currentIndex - 1),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              child: _CurrentLyric(
                key: ValueKey(current.id),
                sentence: current,
                activeWordIndex: activeWordIndex,
                fontSize: currentFontSize,
                compact: compact,
                onTap: onSentenceTap == null
                    ? null
                    : () => onSentenceTap!(currentIndex),
              ),
            ),
            if (next != null)
              _NeighbourLyric(
                sentence: next,
                fontSize: neighbourFontSize,
                compact: compact,
                onTap: onSentenceTap == null
                    ? null
                    : () => onSentenceTap!(currentIndex + 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _NeighbourLyric extends StatelessWidget {
  const _NeighbourLyric({
    required this.sentence,
    required this.fontSize,
    required this.compact,
    this.onTap,
  });

  final OriginalAudioSentence sentence;
  final double fontSize;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(
          vertical: compact ? 2 : AppSpacing.cardPadding,
        ),
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.zero,
            minimumSize: compact && onTap == null
                ? Size.zero
                : const Size(
                    AppSizes.minTouchTarget,
                    AppSizes.minTouchTarget,
                  ),
            tapTargetSize: compact && onTap == null
                ? MaterialTapTargetSize.shrinkWrap
                : null,
          ),
          child: Text(
            sentence.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: fontSize,
              height: 1.35,
            ),
          ),
        ),
      );
}

class _CurrentLyric extends StatelessWidget {
  const _CurrentLyric({
    super.key,
    required this.sentence,
    required this.activeWordIndex,
    required this.fontSize,
    required this.compact,
    this.onTap,
  });

  final OriginalAudioSentence sentence;
  final int? activeWordIndex;
  final double fontSize;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final timings = sentence.words
        .map(
          (word) => ReaderWordTiming(
            id: '${sentence.id}-${word.sequence}',
            sequence: word.sequence,
            word: word.text,
            start: word.start,
            end: word.end,
          ),
        )
        .toList(growable: false);
    final segments = buildSubtitleSegments(sentence.text, timings);
    return Semantics(
      button: onTap != null,
      label: sentence.text,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.subtitleBar),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical: compact ? AppSpacing.unit / 2 : AppSpacing.cardPadding,
          ),
          child: Text.rich(
            TextSpan(
              children: [
                for (final segment in segments)
                  TextSpan(
                    text: segment.text,
                    style: activeWordIndex != null &&
                            segment.wordIndex == activeWordIndex
                        ? const TextStyle(
                            color: AppColors.primaryDark,
                            backgroundColor: AppColors.highlight,
                            fontWeight: FontWeight.w800,
                          )
                        : null,
                  ),
              ],
            ),
            key: const ValueKey('original-audio-current-lyric'),
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: fontSize,
              height: 1.32,
            ),
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

int timelineSentenceIndexAt(
  List<OriginalAudioSentence> sentences,
  Duration position,
) {
  var low = 0;
  var high = sentences.length - 1;
  var result = 0;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (sentences[middle].start <= position) {
      result = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return result;
}

int? timelineActiveWordIndex(
  OriginalAudioSentence sentence,
  Duration position,
) {
  if (sentence.words.isEmpty) return null;
  final first = sentence.words.first;
  final firstLeadStart = first.start - const Duration(milliseconds: 180);
  if (position < first.start &&
      position >= sentence.start &&
      position >= firstLeadStart) {
    return 0;
  }
  var low = 0;
  var high = sentence.words.length - 1;
  var candidate = -1;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (sentence.words[middle].start <= position) {
      candidate = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  if (candidate < 0) return null;
  if (position >= sentence.words[candidate].end) {
    if (candidate == 0) {
      final nextStart =
          sentence.words.length > 1 ? sentence.words[1].start : sentence.end;
      final heldEnd = sentence.words[0].end + const Duration(milliseconds: 80);
      if (position < heldEnd && position < nextStart) return 0;
    }
    return null;
  }
  return candidate;
}
