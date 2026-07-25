import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'original_audio_models.dart';
import 'original_audio_player.dart';
import 'original_audio_repository.dart';
import 'point_reading_models.dart';
import 'reader_models.dart';
import 'reader_repository.dart';
import 'subtitle_timing.dart';

/// 原音欣赏与绘本阅读分开：没有页面缩略条或 bbox，孩子只需听故事、看歌词。
class OriginalAudioPage extends ConsumerWidget {
  const OriginalAudioPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readerBook = ref.watch(readerBookProvider(libraryId));
    final originalBook = ref.watch(originalAudioBookProvider(libraryId));
    if (readerBook.hasError) {
      return _OriginalAudioErrorPage(libraryId: libraryId, bookMissing: true);
    }
    if (originalBook.hasError) {
      return _OriginalAudioErrorPage(libraryId: libraryId);
    }
    if (!readerBook.hasValue || !originalBook.hasValue) {
      return Scaffold(
        appBar: _OriginalAudioAppBar(libraryId: libraryId),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _OriginalAudioPlaybackView(
      book: readerBook.requireValue,
      original: originalBook.requireValue,
    );
  }
}

class _OriginalAudioErrorPage extends StatelessWidget {
  const _OriginalAudioErrorPage({
    required this.libraryId,
    this.bookMissing = false,
  });

  final String libraryId;
  final bool bookMissing;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: _OriginalAudioAppBar(libraryId: libraryId),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.pageMargin),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lyrics_outlined,
                  size: 64,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(height: AppSpacing.cardPadding),
                Text(
                  bookMissing ? '这本绘本暂时打不开' : '原音字幕需要重新制作',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppSizes.originalAudioErrorTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.unit),
                Text(
                  bookMissing ? '请返回书架后重新导入绘本' : '请让家长在制作端完成原音对齐后重新导入',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppSizes.originalAudioErrorBody,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _OriginalAudioAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _OriginalAudioAppBar({this.title, this.libraryId});

  final String? title;
  final String? libraryId;

  @override
  Size get preferredSize => const Size.fromHeight(AppSizes.topBarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
        leading: IconButton(
          onPressed: () => _returnToReader(context, libraryId),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回阅读',
        ),
        title: title == null
            ? null
            : Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (libraryId != null)
            TextButton.icon(
              onPressed: () => context.go('/reader/$libraryId/dub'),
              icon: const Icon(Icons.mic_none_rounded),
              label: const Text('去配音'),
            ),
          const Padding(
            padding: EdgeInsets.only(right: AppSpacing.cardPadding),
            child: Center(
              child: Text(
                '原音欣赏',
                style: TextStyle(
                  color: AppColors.primaryDark,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      );
}

void _returnToReader(BuildContext context, String? libraryId) {
  if (context.canPop()) {
    context.pop();
    return;
  }
  context.go(libraryId == null ? '/shelf' : '/reader/$libraryId');
}

class _OriginalAudioPlaybackView extends ConsumerStatefulWidget {
  const _OriginalAudioPlaybackView(
      {required this.book, required this.original});

  final ReaderBook book;
  final OriginalAudioBook original;

  @override
  ConsumerState<_OriginalAudioPlaybackView> createState() =>
      _OriginalAudioPlaybackViewState();
}

class _OriginalAudioPlaybackViewState
    extends ConsumerState<_OriginalAudioPlaybackView>
    with WidgetsBindingObserver {
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  var _position = Duration.zero;
  var _isPlaying = false;
  var _isPrepared = false;
  var _isSeeking = false;
  var _resumeAfterSeek = false;
  String? _playbackError;

  late final OriginalAudioPlayer _player;
  late final ProviderSubscription<OriginalAudioPlayer> _playerLease;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reading an auto-dispose provider in initState alone can release its
    // native player before the first platform decoder call completes. Keep a
    // manual lease for this route, then release it explicitly in dispose.
    _playerLease = ref.listenManual(
      originalAudioPlayerProvider,
      (_, __) {},
    );
    _player = ref.read(originalAudioPlayerProvider);
    _positionSubscription = _player.positionStream.listen(_onPosition);
    _playingSubscription = _player.playingStream.listen(_onPlayingChanged);
    unawaited(_prepare());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_positionSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    // Providers dispose the native player once this page leaves the tree.
    // Stop eagerly as well so an in-flight route transition cannot keep audio.
    unawaited(_player.stop());
    _playerLease.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_releaseForBackground());
    }
  }

  Future<void> _prepare() async {
    try {
      await _player.load(widget.original.audioPath);
      if (!mounted) return;
      setState(() => _isPrepared = true);
    } on Object {
      if (!mounted) return;
      setState(() => _playbackError = '原音暂时无法播放，请让家长重新导出资源包后再导入');
    }
  }

  Future<void> _releaseForBackground() async {
    try {
      await _player.stop();
      if (mounted) setState(() => _isPlaying = false);
    } on Object {
      // Native audio focus failures should not turn a valid timeline into an
      // unavailable page. The next explicit play remains the recovery path.
    }
  }

  void _onPosition(Duration position) {
    if (!mounted || _isSeeking) return;
    final clamped = _clamp(position);
    if (clamped == _position) return;
    setState(() => _position = clamped);
  }

  void _onPlayingChanged(bool playing) {
    if (!mounted || _isPlaying == playing) return;
    setState(() => _isPlaying = playing);
  }

  Duration _clamp(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (value > widget.original.duration) return widget.original.duration;
    return value;
  }

  Future<void> _togglePlayback() async {
    if (!_isPrepared) return;
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        if (_position >= widget.original.duration) {
          await _player.seek(Duration.zero);
          if (mounted) setState(() => _position = Duration.zero);
        }
        await _player.play();
      }
    } on Object {
      if (mounted) {
        setState(() => _playbackError = '原音暂时无法播放，请让家长重新导出资源包后再导入');
      }
    }
  }

  void _startSeeking() {
    _resumeAfterSeek = _isPlaying;
    _isSeeking = true;
    if (_isPlaying) unawaited(_player.pause());
  }

  void _changeSeeking(double value) {
    setState(() => _position = Duration(milliseconds: value.round()));
  }

  Future<void> _finishSeeking(double value) async {
    final position = Duration(milliseconds: value.round());
    try {
      await _player.seek(position);
      if (_resumeAfterSeek) await _player.play();
    } on Object {
      if (mounted) {
        setState(() => _playbackError = '原音暂时无法播放，请让家长重新导出资源包后再导入');
      }
    } finally {
      if (mounted) setState(() => _isSeeking = false);
    }
  }

  Future<void> _seekToSentence(int index) async {
    if (index < 0 || index >= widget.original.sentences.length) return;
    final target = widget.original.sentences[index].start;
    try {
      await _player.seek(target);
      if (mounted) setState(() => _position = target);
    } on Object {
      if (mounted) {
        setState(() => _playbackError = '原音暂时无法播放，请让家长重新导出资源包后再导入');
      }
    }
  }

  int get _currentSentenceIndex => _sentenceIndexAt(
        widget.original.sentences,
        _position,
      );

  @override
  Widget build(BuildContext context) {
    final sentenceIndex = _currentSentenceIndex;
    final activeWord = _activeWordIndex(
      widget.original.sentences[sentenceIndex],
      _position,
    );
    final coverPath = widget.book.pages.first.imagePath;
    return Scaffold(
      appBar: _OriginalAudioAppBar(
        title: widget.book.title,
        libraryId: widget.book.libraryId,
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < AppSizes.originalAudioWideLayout;
            final cover = _OriginalAudioCover(
              imagePath: coverPath,
              title: widget.book.title,
              duration: widget.original.duration,
              compact: compact,
            );
            final lyrics = _OriginalLyrics(
              sentences: widget.original.sentences,
              currentIndex: sentenceIndex,
              activeWordIndex: activeWord,
              onSentenceTap: (index) => unawaited(_seekToSentence(index)),
            );
            return Column(
              children: [
                Expanded(
                  child: compact
                      ? Column(children: [cover, Expanded(child: lyrics)])
                      : Row(children: [cover, Expanded(child: lyrics)]),
                ),
                if (_playbackError != null)
                  _OriginalAudioNotice(message: _playbackError!),
                _OriginalAudioControls(
                  position: _position,
                  duration: widget.original.duration,
                  playing: _isPlaying,
                  enabled: _isPrepared,
                  hasPrevious: sentenceIndex > 0 ||
                      _position > widget.original.sentences.first.start,
                  hasNext: sentenceIndex < widget.original.sentences.length - 1,
                  onPlayPause: () => unawaited(_togglePlayback()),
                  onSeekStart: _startSeeking,
                  onSeekChanged: _changeSeeking,
                  onSeekEnd: (value) => unawaited(_finishSeeking(value)),
                  onPrevious: () => unawaited(_seekToSentence(
                    _previousSentenceIndex(sentenceIndex),
                  )),
                  onNext: () => unawaited(_seekToSentence(sentenceIndex + 1)),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  int _previousSentenceIndex(int currentIndex) {
    final current = widget.original.sentences[currentIndex];
    if (_position - current.start > const Duration(milliseconds: 900)) {
      return currentIndex;
    }
    return currentIndex > 0 ? currentIndex - 1 : 0;
  }
}

class _OriginalAudioCover extends StatelessWidget {
  const _OriginalAudioCover({
    required this.imagePath,
    required this.title,
    required this.duration,
    required this.compact,
  });

  final String imagePath;
  final String title;
  final Duration duration;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final artwork = AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: File(imagePath).existsSync()
            ? Image.file(File(imagePath), fit: BoxFit.contain)
            : const ColoredBox(
                color: AppColors.primaryContainer,
                child: Icon(
                  Icons.menu_book_outlined,
                  color: AppColors.primaryDark,
                  size: AppSizes.originalAudioCoverFallbackIcon,
                ),
              ),
      ),
    );
    return Container(
      key: const ValueKey('original-audio-cover'),
      width: compact ? double.infinity : AppSizes.originalAudioCoverColumn,
      padding: EdgeInsets.fromLTRB(
        compact ? AppSpacing.pageMargin : AppSpacing.cardPadding,
        compact ? AppSpacing.cardPadding : AppSpacing.pageMargin,
        compact ? AppSpacing.pageMargin : AppSpacing.cardPadding,
        AppSpacing.cardPadding,
      ),
      decoration: const BoxDecoration(
        color: AppColors.primaryContainer,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: compact
          ? Row(
              children: [
                SizedBox(
                    width: AppSizes.originalAudioCompactCoverWidth,
                    child: artwork),
                const SizedBox(width: AppSpacing.cardPadding),
                Expanded(child: _CoverMeta(title: title, duration: duration)),
              ],
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(child: Center(child: artwork)),
                const SizedBox(height: AppSpacing.cardPadding),
                _CoverMeta(title: title, duration: duration),
              ],
            ),
    );
  }
}

class _CoverMeta extends StatelessWidget {
  const _CoverMeta({required this.title, required this.duration});

  final String title;
  final Duration duration;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: AppSizes.originalAudioCoverTitle,
            ),
          ),
          const SizedBox(height: AppSpacing.unit),
          Text(
            '原音 · ${_formatTime(duration)}',
            style: const TextStyle(
              color: AppColors.primaryDark,
              fontSize: AppSizes.originalAudioCoverMeta,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

class _OriginalLyrics extends StatelessWidget {
  const _OriginalLyrics({
    required this.sentences,
    required this.currentIndex,
    required this.activeWordIndex,
    required this.onSentenceTap,
  });

  final List<OriginalAudioSentence> sentences;
  final int currentIndex;
  final int? activeWordIndex;
  final ValueChanged<int> onSentenceTap;

  @override
  Widget build(BuildContext context) {
    final previous = currentIndex > 0 ? sentences[currentIndex - 1] : null;
    final current = sentences[currentIndex];
    final next = currentIndex + 1 < sentences.length
        ? sentences[currentIndex + 1]
        : null;
    return Semantics(
      label: '原音歌词，第 ${currentIndex + 1} 句，共 ${sentences.length} 句',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.pageMargin),
        child: Column(
          key: const ValueKey('original-audio-lyrics'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (previous != null)
              _NeighbourLyric(
                sentence: previous,
                onTap: () => onSentenceTap(currentIndex - 1),
              ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              child: _CurrentLyric(
                key: ValueKey(current.id),
                sentence: current,
                activeWordIndex: activeWordIndex,
                onTap: () => onSentenceTap(currentIndex),
              ),
            ),
            if (next != null)
              _NeighbourLyric(
                sentence: next,
                onTap: () => onSentenceTap(currentIndex + 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _NeighbourLyric extends StatelessWidget {
  const _NeighbourLyric({required this.sentence, required this.onTap});

  final OriginalAudioSentence sentence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.cardPadding),
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.zero,
            minimumSize:
                const Size(AppSizes.minTouchTarget, AppSizes.minTouchTarget),
          ),
          child: Text(
            sentence.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: AppSizes.originalAudioNeighbourLyric,
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
    required this.onTap,
  });

  final OriginalAudioSentence sentence;
  final int? activeWordIndex;
  final VoidCallback onTap;

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
      button: true,
      label: sentence.text,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.subtitleBar),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.cardPadding),
          child: Text.rich(
            TextSpan(
              children: [
                for (final segment in segments)
                  TextSpan(
                    text: segment.text,
                    style: segment.wordIndex == activeWordIndex
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
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: AppSizes.originalAudioCurrentLyric,
              height: 1.32,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _OriginalAudioNotice extends StatelessWidget {
  const _OriginalAudioNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('original-audio-error'),
        width: double.infinity,
        color: AppColors.accentContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pageMargin,
          vertical: AppSpacing.unit,
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _OriginalAudioControls extends StatelessWidget {
  const _OriginalAudioControls({
    required this.position,
    required this.duration,
    required this.playing,
    required this.enabled,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPlayPause,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onPrevious,
    required this.onNext,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final bool enabled;
  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('original-audio-controls'),
        decoration: const BoxDecoration(
          color: AppColors.bgAlt,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.unit,
          AppSpacing.pageMargin,
          AppSpacing.cardPadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(_formatTime(position),
                    style: const TextStyle(color: AppColors.textSecondary)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: AppColors.primary,
                      inactiveTrackColor: AppColors.primaryContainer,
                      trackHeight: AppSpacing.unit / 2,
                      thumbColor: AppColors.primary,
                      overlayColor: AppColors.primaryContainer,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: AppSpacing.unit,
                      ),
                    ),
                    child: Slider(
                      key: const ValueKey('original-audio-seek'),
                      value: position.inMilliseconds.toDouble().clamp(
                            0,
                            duration.inMilliseconds.toDouble(),
                          ),
                      max: duration.inMilliseconds.toDouble(),
                      onChangeStart: enabled ? (_) => onSeekStart() : null,
                      onChanged: enabled ? onSeekChanged : null,
                      onChangeEnd: enabled ? onSeekEnd : null,
                    ),
                  ),
                ),
                Text(_formatTime(duration),
                    style: const TextStyle(color: AppColors.textSecondary)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _SentenceSkipButton(
                  onPressed: enabled && hasPrevious ? onPrevious : null,
                  icon: Icons.skip_previous_rounded,
                  tooltip: '上一句',
                ),
                const SizedBox(width: AppSpacing.cardPadding),
                SizedBox(
                  width: AppSizes.primaryButton,
                  height: AppSizes.primaryButton,
                  child: FilledButton(
                    key: const ValueKey('original-audio-play-toggle'),
                    onPressed: enabled ? onPlayPause : null,
                    style: FilledButton.styleFrom(shape: const CircleBorder()),
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: AppSizes.originalAudioPlayIcon,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.cardPadding),
                _SentenceSkipButton(
                  onPressed: enabled && hasNext ? onNext : null,
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一句',
                ),
              ],
            ),
          ],
        ),
      );
}

class _SentenceSkipButton extends StatelessWidget {
  const _SentenceSkipButton({
    required this.onPressed,
    required this.icon,
    required this.tooltip,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, size: AppSizes.originalAudioSkipIcon),
        style: IconButton.styleFrom(
          foregroundColor: AppColors.primaryDark,
          backgroundColor: AppColors.primaryContainer,
          disabledBackgroundColor: AppColors.border,
          minimumSize: const Size(
            AppSizes.originalAudioSkipButton,
            AppSizes.originalAudioSkipButton,
          ),
        ),
      );
}

int _sentenceIndexAt(List<OriginalAudioSentence> sentences, Duration position) {
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

int? _activeWordIndex(OriginalAudioSentence sentence, Duration position) {
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
  if (candidate < 0 || position >= sentence.words[candidate].end) return null;
  return candidate;
}

String _formatTime(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
}
