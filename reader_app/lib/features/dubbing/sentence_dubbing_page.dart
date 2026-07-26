import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../reader/timeline_lyrics.dart';
import 'dubbing_repository.dart';
import 'sentence_dubbing_controller.dart';

class SentenceDubbingPage extends ConsumerStatefulWidget {
  const SentenceDubbingPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  ConsumerState<SentenceDubbingPage> createState() =>
      _SentenceDubbingPageState();
}

class _SentenceDubbingPageState extends ConsumerState<SentenceDubbingPage>
    with WidgetsBindingObserver {
  Timer? _slowLoadingTimer;
  var _slowLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _armSlowLoadingNotice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slowLoadingTimer?.cancel();
    super.dispose();
  }

  void _armSlowLoadingNotice() {
    _slowLoadingTimer?.cancel();
    _slowLoadingTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _slowLoading = true);
    });
  }

  void _retryLoading() {
    ref.invalidate(sentenceDubbingControllerProvider(widget.libraryId));
    setState(() => _slowLoading = false);
    _armSlowLoadingNotice();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(ref
          .read(sentenceDubbingControllerProvider(widget.libraryId).notifier)
          .handleAppBackgrounded());
    }
  }

  @override
  Widget build(BuildContext context) {
    final libraryId = widget.libraryId;
    final state = ref.watch(sentenceDubbingControllerProvider(libraryId));
    if (!state.isLoading) {
      _slowLoadingTimer?.cancel();
      _slowLoadingTimer = null;
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.go('/reader/$libraryId/original'),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回原音欣赏',
        ),
        title: const Text('一句一句配故事'),
        actions: [
          TextButton.icon(
            onPressed: () => context.go('/reader/$libraryId/dub/full'),
            icon: const Icon(Icons.library_music_outlined),
            label: const Text('完整配音'),
          ),
          const SizedBox(width: AppSpacing.unit),
        ],
      ),
      body: state.when(
        loading: () => _DubbingLoading(
          slow: _slowLoading,
          onRetry: _retryLoading,
        ),
        error: (_, __) => const _DubbingUnavailable(),
        data: (value) => _DubbingView(libraryId: libraryId, state: value),
      ),
    );
  }
}

class _DubbingLoading extends StatelessWidget {
  const _DubbingLoading({required this.slow, required this.onRetry});

  final bool slow;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.cardPadding),
              Text(
                slow ? '打开得有点久，录音和进度都不会丢失' : '正在打开配音…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              if (slow) ...[
                const SizedBox(height: AppSpacing.cardPadding),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重新加载'),
                ),
              ],
            ],
          ),
        ),
      );
}

class _DubbingUnavailable extends StatelessWidget {
  const _DubbingUnavailable();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.pageMargin),
          child: Text(
            '这本绘本的配音歌词还没有准备好，请让家长重新导出并导入。',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

class _DubbingView extends ConsumerWidget {
  const _DubbingView({required this.libraryId, required this.state});

  final String libraryId;
  final SentenceDubbingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller =
        ref.read(sentenceDubbingControllerProvider(libraryId).notifier);
    return SafeArea(
      top: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final lyrics = _LyricsArea(
            state: state,
            onSentenceTap: state.isBusy
                ? null
                : (index) {
                    if (index < state.sentenceIndex) {
                      unawaited(controller.previousSentence());
                    } else if (index > state.sentenceIndex) {
                      unawaited(controller.nextSentence());
                    }
                  },
          );
          final controls = _GuidedControls(
            state: state,
            stickyNavigation: !compact,
            onStart: () => unawaited(controller.startRecording()),
            onCancelPreparation: () =>
                unawaited(controller.cancelPreparation()),
            onStop: () => unawaited(controller.stopRecording()),
            onContinue: () =>
                unawaited(controller.continueAndStartNextSentence()),
            onPrevious: () => unawaited(controller.previousSentence()),
            onNext: () => unawaited(controller.nextSentence()),
            onSelect: (take) => unawaited(controller.selectTake(take.id)),
            onPlay: (take) => unawaited(controller.playTake(take)),
            onRetryScore: (take) => unawaited(controller.retryScore(take)),
            onCreateMix: () => unawaited(controller.createMix()),
            onPlayMix: (mix) => unawaited(controller.playMix(mix)),
          );
          if (compact) {
            final lyricHeight =
                (constraints.maxHeight * .42).clamp(230.0, 340.0);
            return Column(
              children: [
                SizedBox(height: lyricHeight, child: lyrics),
                Expanded(child: controls),
              ],
            );
          }
          return Row(
            children: [
              Expanded(flex: 5, child: lyrics),
              const VerticalDivider(width: 1, color: AppColors.border),
              Expanded(flex: 6, child: controls),
            ],
          );
        },
      ),
    );
  }
}

class _LyricsArea extends StatelessWidget {
  const _LyricsArea({required this.state, this.onSentenceTap});

  final SentenceDubbingState state;
  final ValueChanged<int>? onSentenceTap;

  @override
  Widget build(BuildContext context) {
    final total = state.original.sentences.length;
    final progress = total == 0 ? 0.0 : state.completedSentenceCount / total;
    return ColoredBox(
      color: AppColors.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.cardPadding,
              AppSpacing.pageMargin,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '第 ${state.sentenceIndex + 1} / $total 句',
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '已完成 ${state.completedSentenceCount} 句',
                  style: const TextStyle(color: AppColors.primaryDark),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.unit,
              AppSpacing.pageMargin,
              0,
            ),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              color: AppColors.primary,
              backgroundColor: AppColors.bgAlt,
              borderRadius: BorderRadius.circular(AppRadius.button),
            ),
          ),
          Expanded(
            child: TimelineLyrics(
              sentences: state.original.sentences,
              currentIndex: state.sentenceIndex,
              activeWordIndex: state.phase == SentenceDubbingPhase.demonstrating
                  ? state.activeWordIndex
                  : null,
              onSentenceTap: onSentenceTap,
              currentFontSize: 34,
              neighbourFontSize: 20,
              semanticLabel: '逐句配音歌词',
            ),
          ),
        ],
      ),
    );
  }
}

class _GuidedControls extends StatelessWidget {
  const _GuidedControls({
    required this.state,
    required this.stickyNavigation,
    required this.onStart,
    required this.onCancelPreparation,
    required this.onStop,
    required this.onContinue,
    required this.onPrevious,
    required this.onNext,
    required this.onSelect,
    required this.onPlay,
    required this.onRetryScore,
    required this.onCreateMix,
    required this.onPlayMix,
  });

  final SentenceDubbingState state;
  final bool stickyNavigation;
  final VoidCallback onStart;
  final VoidCallback onCancelPreparation;
  final VoidCallback onStop;
  final VoidCallback onContinue;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DubbingTake> onSelect;
  final ValueChanged<DubbingTake> onPlay;
  final ValueChanged<DubbingTake> onRetryScore;
  final VoidCallback onCreateMix;
  final ValueChanged<DubbingMix> onPlayMix;

  @override
  Widget build(BuildContext context) {
    final primary = _PrimaryStage(
      state: state,
      onStart: onStart,
      onCancelPreparation: onCancelPreparation,
      onStop: onStop,
      onContinue: onContinue,
    );
    final failure = state.failure == null
        ? null
        : _MessageStrip(message: state.failure!, error: true);
    final secondary = <Widget>[
      ExpansionTile(
        key: ValueKey('sentence-takes-${state.sentence.id}'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        leading: const Icon(Icons.library_music_outlined),
        title: Text('我的录音（${state.takes.length}）'),
        subtitle: const Text('需要试听或改选时再打开；删除由家长统一管理'),
        children: [
          if (state.takes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.cardPadding),
              child: Text(
                '完成这一句后，录音会安全保存在这里。',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          for (final take in state.takes)
            _TakeRow(
              take: take,
              onSelect: () => onSelect(take),
              onPlay: () => onPlay(take),
              onRetry: () => onRetryScore(take),
            ),
        ],
      ),
      if (state.canCreateMix) ...[
        const SizedBox(height: AppSpacing.cardPadding),
        FilledButton.icon(
          key: const ValueKey('sentence-dubbing-create-work'),
          onPressed: state.isBusy ? null : onCreateMix,
          icon: const Icon(Icons.auto_awesome_rounded),
          label: Text(
            state.phase == SentenceDubbingPhase.mixing
                ? '正在生成故事…'
                : state.original.backgroundPath == null
                    ? '完成故事（纯人声）'
                    : '完成故事（带背景音乐）',
          ),
        ),
      ],
      if (state.mixes.isNotEmpty)
        _LatestMix(
          mix: state.mixes.first,
          onPlay: () => onPlayMix(state.mixes.first),
        ),
    ];
    final navigation = _SentenceNavigation(
      state: state,
      onPrevious: onPrevious,
      onNext: onNext,
    );

    if (!stickyNavigation) {
      final resetAtResult = state.phase == SentenceDubbingPhase.result;
      return ListView(
        key: ValueKey(
          'sentence-controls-${state.sentence.id}-$resetAtResult',
        ),
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        children: [
          primary,
          if (failure != null) ...[
            const SizedBox(height: AppSpacing.cardPadding),
            failure,
          ],
          const SizedBox(height: AppSpacing.pageMargin),
          ...secondary,
          const SizedBox(height: AppSpacing.cardPadding),
          navigation,
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.pageMargin,
            AppSpacing.pageMargin,
            AppSpacing.cardPadding,
          ),
          child: primary,
        ),
        if (failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              0,
              AppSpacing.pageMargin,
              AppSpacing.cardPadding,
            ),
            child: failure,
          ),
        Expanded(
          child: ListView(
            key: ValueKey('sentence-secondary-${state.sentence.id}'),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.pageMargin,
            ),
            children: secondary,
          ),
        ),
        DecoratedBox(
          decoration: const BoxDecoration(
            color: AppColors.bg,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.unit,
              AppSpacing.pageMargin,
              AppSpacing.unit,
            ),
            child: navigation,
          ),
        ),
      ],
    );
  }
}

class _SentenceNavigation extends StatelessWidget {
  const _SentenceNavigation({
    required this.state,
    required this.onPrevious,
    required this.onNext,
  });

  final SentenceDubbingState state;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: state.canGoPrevious ? onPrevious : null,
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('上一句'),
            ),
          ),
          const SizedBox(width: AppSpacing.cardPadding),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: state.canGoNext ? onNext : null,
              icon: const Icon(Icons.arrow_forward_rounded),
              label: const Text('下一句'),
            ),
          ),
        ],
      );
}

class _PrimaryStage extends StatelessWidget {
  const _PrimaryStage({
    required this.state,
    required this.onStart,
    required this.onCancelPreparation,
    required this.onStop,
    required this.onContinue,
  });

  final SentenceDubbingState state;
  final VoidCallback onStart;
  final VoidCallback onCancelPreparation;
  final VoidCallback onStop;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final phase = state.phase;
    final preparing = phase == SentenceDubbingPhase.preparing ||
        phase == SentenceDubbingPhase.countdown;
    final title = switch (phase) {
      SentenceDubbingPhase.demonstrating => '先听一遍',
      SentenceDubbingPhase.preparing => '麦克风已准备好',
      SentenceDubbingPhase.countdown => '马上到你',
      SentenceDubbingPhase.recording => '轮到你啦',
      SentenceDubbingPhase.scoring => '录音保存好了',
      SentenceDubbingPhase.result => '这一句完成啦',
      SentenceDubbingPhase.mixing => '正在完成故事',
      _ => state.canRecord ? '听一句，录一句' : '本句已有 3 条录音',
    };
    final hint = switch (phase) {
      SentenceDubbingPhase.demonstrating => '看着亮起的词，记住说话节奏',
      SentenceDubbingPhase.preparing => '听示范时，麦克风已经在后台稳定',
      SentenceDubbingPhase.countdown => '听完这一拍就开始',
      SentenceDubbingPhase.recording => '读完后点“完成这一句”',
      SentenceDubbingPhase.scoring => '正在听一听你的表现…',
      SentenceDubbingPhase.result => state.result == null
          ? '录音已经保留，可以再录或从下面选择一版'
          : '得到 ${state.result!.stars.toStringAsFixed(1)} 星，已自动选用这一版',
      _ => '点一次按钮，会自动听示范并接着录音',
    };
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        decoration: BoxDecoration(
          color: AppColors.bgAlt,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Text(
                title,
                key: ValueKey(title),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: phase == SentenceDubbingPhase.countdown ? 36 : 26,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  color: phase == SentenceDubbingPhase.countdown
                      ? AppColors.accent
                      : AppColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.unit),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (phase == SentenceDubbingPhase.recording) ...[
              const SizedBox(height: AppSpacing.cardPadding),
              LinearProgressIndicator(
                value: state.level.clamp(.03, 1),
                minHeight: 10,
                color: AppColors.accent,
                backgroundColor: AppColors.accentContainer,
                borderRadius: BorderRadius.circular(AppRadius.button),
              ),
              const SizedBox(height: AppSpacing.unit),
              Text(_clock(state.elapsed)),
            ],
            const SizedBox(height: AppSpacing.cardPadding),
            if (phase == SentenceDubbingPhase.recording)
              FilledButton.icon(
                key: const ValueKey('dubbing-record'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                ),
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('完成这一句'),
              )
            else if (preparing)
              TextButton.icon(
                onPressed: onCancelPreparation,
                icon: const Icon(Icons.close_rounded),
                label: const Text('取消这次'),
              )
            else if (phase == SentenceDubbingPhase.result)
              Wrap(
                spacing: AppSpacing.cardPadding,
                runSpacing: AppSpacing.unit,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: state.canRecord ? onStart : null,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('再录一次'),
                  ),
                  FilledButton.icon(
                    onPressed: state.hasSelectedTake ? onContinue : null,
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(state.canCreateMix ? '去完成故事' : '下一句，接着录'),
                  ),
                ],
              )
            else if (phase == SentenceDubbingPhase.demonstrating ||
                phase == SentenceDubbingPhase.scoring ||
                phase == SentenceDubbingPhase.mixing)
              const SizedBox(
                width: AppSizes.minTouchTarget,
                height: AppSizes.minTouchTarget,
                child: CircularProgressIndicator(),
              )
            else
              FilledButton.icon(
                key: const ValueKey('dubbing-record'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                ),
                onPressed: state.canRecord ? onStart : null,
                icon: const Icon(Icons.volume_up_rounded),
                label: Text(state.canRecord ? '开始这一句' : '请先管理已有录音'),
              ),
          ],
        ),
      ),
    );
  }
}

class _TakeRow extends StatelessWidget {
  const _TakeRow({
    required this.take,
    required this.onSelect,
    required this.onPlay,
    required this.onRetry,
  });

  final DubbingTake take;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final score = take.scoreJson == null ? null : _score(take.scoreJson!);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        take.isSelected ? Icons.check_circle : Icons.mic_none_rounded,
        color: take.isSelected ? AppColors.success : AppColors.textSecondary,
      ),
      title: Text(take.isSelected ? '正在使用这一版' : '录音 ${_clock(take.duration)}'),
      subtitle: Text(
        score == null
            ? (take.scoreStatus == DubbingTakeScoreStatus.failed
                ? '评分暂时没完成，录音仍然保留'
                : '录音已保存')
            : '${score.toStringAsFixed(1)} 星',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded),
            tooltip: '听这条录音',
          ),
          PopupMenuButton<String>(
            tooltip: '管理这条录音',
            onSelected: (value) {
              if (value == 'select') onSelect();
              if (value == 'retry') onRetry();
            },
            itemBuilder: (_) => [
              if (!take.isSelected)
                const PopupMenuItem(value: 'select', child: Text('使用这一版')),
              if (take.scoreStatus == DubbingTakeScoreStatus.failed)
                const PopupMenuItem(value: 'retry', child: Text('重新评分')),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatestMix extends StatelessWidget {
  const _LatestMix({
    required this.mix,
    required this.onPlay,
  });

  final DubbingMix mix;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          mix.variant == DubbingMixVariant.background
              ? Icons.music_note_rounded
              : Icons.record_voice_over_rounded,
          color: AppColors.primary,
        ),
        title: Text(mix.variant == DubbingMixVariant.background
            ? '最新背景版故事'
            : '最新纯人声故事'),
        subtitle: Text(_clock(mix.duration)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: '播放故事',
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded),
            ),
          ],
        ),
      );
}

class _MessageStrip extends StatelessWidget {
  const _MessageStrip({required this.message, required this.error});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: error ? AppColors.accentContainer : AppColors.primaryContainer,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: error ? AppColors.danger : AppColors.primaryDark,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

double? _score(String json) {
  try {
    final value = jsonDecode(json) as Map<String, dynamic>;
    return (value['child_score'] as num).toDouble() / 20;
  } on Object {
    return null;
  }
}

String _clock(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
