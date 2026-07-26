import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../reader/timeline_lyrics.dart';
import 'dubbing_repository.dart';
import 'full_dubbing_controller.dart';

class FullDubbingPage extends ConsumerStatefulWidget {
  const FullDubbingPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  ConsumerState<FullDubbingPage> createState() => _FullDubbingPageState();
}

class _FullDubbingPageState extends ConsumerState<FullDubbingPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(ref
          .read(fullDubbingControllerProvider(widget.libraryId).notifier)
          .handleAppBackgrounded());
    }
  }

  Future<void> _leave() async {
    await ref
        .read(fullDubbingControllerProvider(widget.libraryId).notifier)
        .prepareToLeave();
    if (mounted) context.go('/reader/${widget.libraryId}/dub');
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fullDubbingControllerProvider(widget.libraryId));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => unawaited(_leave()),
            tooltip: '返回逐句配音',
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('跟着歌词讲完整故事'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.cardPadding),
              child: state.maybeWhen(
                data: (value) => Center(
                  child: Text(
                    value.isComplete ? '已完成' : '草稿',
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                orElse: () => const SizedBox.shrink(),
              ),
            ),
          ],
        ),
        body: state.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.pageMargin),
              child: Text(
                '这本绘本的完整配音歌词还没有准备好，请让家长重新导出并导入。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
          data: (value) =>
              _FullDubbingView(libraryId: widget.libraryId, state: value),
        ),
      ),
    );
  }
}

class _FullDubbingView extends ConsumerWidget {
  const _FullDubbingView({required this.libraryId, required this.state});

  final String libraryId;
  final FullDubbingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller =
        ref.read(fullDubbingControllerProvider(libraryId).notifier);
    final selected = state.takes.where((take) => take.isSelected).firstOrNull;
    final recordingSurface = state.phase == FullDubbingPhase.preparing ||
        state.phase == FullDubbingPhase.countdown ||
        state.isRecording;

    return SafeArea(
      top: false,
      child: recordingSurface
          ? _KaraokeRecordingSurface(
              state: state,
              onCancel: () => unawaited(controller.cancelCountdown()),
              onStop: () => unawaited(controller.stopRecording()),
            )
          : _FullDubbingHome(
              state: state,
              selected: selected,
              onListenFirst: () =>
                  unawaited(controller.toggleOriginalPreview()),
              onStart: () => unawaited(controller.startCountdown()),
              onPlayTake: (take) => unawaited(controller.playTake(take)),
              onScoreTake: (take) => unawaited(controller.scoreTake(take)),
              onSelectTake: (take) => unawaited(controller.selectTake(take.id)),
              onDeleteTake: (take) => unawaited(controller.deleteTake(take.id)),
              onSaveDraft: () => unawaited(controller.saveDraft()),
              onComplete: () => unawaited(controller.complete()),
              onCreateMix: () => unawaited(controller.createMix()),
              onPlayMix: (mix) => unawaited(controller.playMix(mix)),
              onDeleteMix: (mix) => unawaited(controller.deleteMix(mix.id)),
            ),
    );
  }
}

class _KaraokeRecordingSurface extends StatelessWidget {
  const _KaraokeRecordingSurface({
    required this.state,
    required this.onCancel,
    required this.onStop,
  });

  final FullDubbingState state;
  final VoidCallback onCancel;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final sentences = state.original.sentences;
    final position = state.elapsed > state.original.duration
        ? state.original.duration
        : state.elapsed;
    final sentenceIndex = timelineSentenceIndexAt(sentences, position);
    final timedActiveWord = state.isRecording
        ? timelineActiveWordIndex(sentences[sentenceIndex], position)
        : null;
    final activeWord = state.isRecording &&
            sentenceIndex == 0 &&
            sentences.first.words.isNotEmpty &&
            state.elapsed < const Duration(milliseconds: 1200)
        ? timedActiveWord ?? 0
        : timedActiveWord;
    final totalMs = state.original.duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final preparing = state.phase == FullDubbingPhase.preparing;
    final countdown = state.phase == FullDubbingPhase.countdown;

    return LayoutBuilder(
      builder: (context, constraints) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.pageMargin,
              AppSpacing.cardPadding,
              AppSpacing.pageMargin,
              AppSpacing.unit,
            ),
            child: Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    color: AppColors.primary,
                    backgroundColor: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                ),
                const SizedBox(width: AppSpacing.cardPadding),
                Text(
                  '${_clock(position)} / ${_clock(state.original.duration)}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: preparing || countdown
                  ? Center(
                      key: ValueKey(state.phase),
                      child: Semantics(
                        liveRegion: true,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              preparing
                                  ? Icons.mic_none_rounded
                                  : Icons.music_note_rounded,
                              size: 52,
                              color: AppColors.accent,
                            ),
                            const SizedBox(height: AppSpacing.cardPadding),
                            Text(
                              preparing ? '麦克风准备中' : '${state.countdown}',
                              style: TextStyle(
                                fontSize: countdown ? 78 : 30,
                                height: 1,
                                fontWeight: FontWeight.w800,
                                color: countdown
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.cardPadding),
                            Text(
                              preparing
                                  ? '先稳定麦克风，保护故事的第一个字'
                                  : '看到“开始”后，跟着歌词讲故事',
                              style: const TextStyle(
                                  color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Stack(
                      key: const ValueKey('full-dubbing-karaoke-lyrics'),
                      alignment: Alignment.topCenter,
                      children: [
                        TimelineLyrics(
                          sentences: sentences,
                          currentIndex: sentenceIndex,
                          activeWordIndex: activeWord,
                          currentFontSize: constraints.maxWidth < 600 ? 34 : 46,
                          neighbourFontSize:
                              constraints.maxWidth < 600 ? 20 : 27,
                          semanticLabel: '完整配音歌词',
                        ),
                        if (state.isRecording &&
                            state.elapsed < const Duration(milliseconds: 1200))
                          Semantics(
                            liveRegion: true,
                            label: '开始读',
                            child: Container(
                              margin:
                                  const EdgeInsets.only(top: AppSpacing.unit),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.cardPadding,
                                vertical: AppSpacing.unit,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.button),
                              ),
                              child: const Text(
                                '开始读',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          if (state.failure != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.pageMargin),
              child: Text(
                state.failure!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.pageMargin),
            child: Column(
              children: [
                if (state.isRecording) ...[
                  LinearProgressIndicator(
                    value: state.level.clamp(.03, 1),
                    minHeight: 10,
                    color: AppColors.accent,
                    backgroundColor: AppColors.accentContainer,
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  const SizedBox(height: AppSpacing.cardPadding),
                  FilledButton.icon(
                    key: const ValueKey('full-dubbing-record'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 18,
                      ),
                    ),
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('结束并保存录音'),
                  ),
                ] else
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('取消这次'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FullDubbingHome extends StatelessWidget {
  const _FullDubbingHome({
    required this.state,
    required this.selected,
    required this.onListenFirst,
    required this.onStart,
    required this.onPlayTake,
    required this.onScoreTake,
    required this.onSelectTake,
    required this.onDeleteTake,
    required this.onSaveDraft,
    required this.onComplete,
    required this.onCreateMix,
    required this.onPlayMix,
    required this.onDeleteMix,
  });

  final FullDubbingState state;
  final DubbingTake? selected;
  final VoidCallback onListenFirst;
  final VoidCallback onStart;
  final ValueChanged<DubbingTake> onPlayTake;
  final ValueChanged<DubbingTake> onScoreTake;
  final ValueChanged<DubbingTake> onSelectTake;
  final ValueChanged<DubbingTake> onDeleteTake;
  final VoidCallback onSaveDraft;
  final VoidCallback onComplete;
  final VoidCallback onCreateMix;
  final ValueChanged<DubbingMix> onPlayMix;
  final ValueChanged<DubbingMix> onDeleteMix;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        children: [
          Text(
            state.takes.isEmpty ? '准备好，就来讲完整故事' : '再讲一遍，或者完成作品',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 28,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.unit),
          Text(
            state.original.backgroundPath == null
                ? '录制时不会播放原旁白，歌词会按时间自动前进。'
                : '建议戴耳机；不用耳机时会自动降低伴奏音量，仍可能有少量回录。',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.pageMargin),
          Wrap(
            spacing: AppSpacing.cardPadding,
            runSpacing: AppSpacing.unit,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: state.isBusy ? null : onListenFirst,
                icon: Icon(
                  state.isPreviewingOriginal && state.audioPlaying
                      ? Icons.pause_rounded
                      : Icons.headphones_rounded,
                ),
                label: Text(
                  state.isPreviewingOriginal && state.audioPlaying
                      ? '暂停原音'
                      : state.isPreviewingOriginal &&
                              state.playbackPosition > Duration.zero
                          ? '继续听'
                          : '先听一遍',
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('full-dubbing-record'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
                ),
                onPressed: state.canStart ? onStart : null,
                icon: const Icon(Icons.mic_none_rounded),
                label: const Text('开始完整配音'),
              ),
            ],
          ),
          if (state.isPreviewingOriginal) ...[
            const SizedBox(height: AppSpacing.cardPadding),
            _OriginalPreviewPanel(state: state),
          ],
          if (state.failure != null) ...[
            const SizedBox(height: AppSpacing.cardPadding),
            Container(
              padding: const EdgeInsets.all(AppSpacing.cardPadding),
              decoration: BoxDecoration(
                color: AppColors.accentContainer,
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Text(
                state.failure!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.pageMargin),
          ExpansionTile(
            initiallyExpanded: state.takes.isNotEmpty,
            tilePadding: EdgeInsets.zero,
            leading: const Icon(Icons.library_music_outlined),
            title: Text('我的完整录音（${state.takes.length}）'),
            subtitle: const Text('回放和管理录音版本'),
            children: [
              if (state.takes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.cardPadding),
                  child: Text(
                    '第一遍故事录好后，会安全保存在这里。',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
              for (final take in state.takes)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    take.isSelected
                        ? Icons.check_circle
                        : Icons.mic_none_rounded,
                    color: take.isSelected
                        ? AppColors.success
                        : AppColors.textSecondary,
                  ),
                  title: Text(take.isSelected
                      ? '正在使用这一版'
                      : '完整录音 ${_clock(take.duration)}'),
                  subtitle: Text(
                    take.scoreStatus == DubbingTakeScoreStatus.scored
                        ? '已经完成逐句评分'
                        : take.scoreStatus == DubbingTakeScoreStatus.failed
                            ? '评分暂时没完成，录音仍然保留'
                            : '已保存，可以逐句评分',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => onPlayTake(take),
                        tooltip: state.playbackKind ==
                                    FullDubbingPlaybackKind.take &&
                                state.playbackId == take.id &&
                                state.audioPlaying
                            ? '暂停这条录音'
                            : '听这条录音',
                        icon: Icon(
                          state.playbackKind == FullDubbingPlaybackKind.take &&
                                  state.playbackId == take.id &&
                                  state.audioPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '管理这条录音',
                        enabled: !state.isBusy,
                        onSelected: (value) {
                          if (value == 'score') onScoreTake(take);
                          if (value == 'select') onSelectTake(take);
                          if (value == 'delete') onDeleteTake(take);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'score',
                            child: Text('逐句评分'),
                          ),
                          if (!take.isSelected)
                            const PopupMenuItem(
                              value: 'select',
                              child: Text('使用这一版'),
                            ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除这条录音'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (selected != null) ...[
            const SizedBox(height: AppSpacing.cardPadding),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: state.isBusy ? null : onSaveDraft,
                    child: const Text('保存为草稿'),
                  ),
                ),
                const SizedBox(width: AppSpacing.cardPadding),
                Expanded(
                  child: FilledButton(
                    onPressed: state.isBusy ? null : onComplete,
                    child: const Text('确认完成故事'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.unit),
            FilledButton.icon(
              key: const ValueKey('full-dubbing-create-work'),
              onPressed: state.isBusy ? null : onCreateMix,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(
                state.phase == FullDubbingPhase.mixing
                    ? '正在生成作品…'
                    : state.original.backgroundPath == null
                        ? '生成纯人声作品'
                        : '生成背景音乐作品',
              ),
            ),
          ],
          if (state.mixes.isNotEmpty)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                state.mixes.first.variant == DubbingMixVariant.background
                    ? Icons.music_note_rounded
                    : Icons.record_voice_over_rounded,
                color: AppColors.primary,
              ),
              title: Text(
                state.mixes.first.variant == DubbingMixVariant.background
                    ? '最新背景音乐作品'
                    : '最新纯人声作品',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip:
                        state.playbackKind == FullDubbingPlaybackKind.mix &&
                                state.playbackId == state.mixes.first.id &&
                                state.audioPlaying
                            ? '暂停作品'
                            : '播放作品',
                    onPressed: () => onPlayMix(state.mixes.first),
                    icon: Icon(
                      state.playbackKind == FullDubbingPlaybackKind.mix &&
                              state.playbackId == state.mixes.first.id &&
                              state.audioPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  IconButton(
                    tooltip: '删除作品',
                    onPressed: state.isBusy
                        ? null
                        : () => onDeleteMix(state.mixes.first),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ],
              ),
            ),
        ],
      );
}

class _OriginalPreviewPanel extends StatelessWidget {
  const _OriginalPreviewPanel({required this.state});

  final FullDubbingState state;

  @override
  Widget build(BuildContext context) {
    final position = state.playbackPosition > state.original.duration
        ? state.original.duration
        : state.playbackPosition;
    final sentenceIndex =
        timelineSentenceIndexAt(state.original.sentences, position);
    final activeWord = timelineActiveWordIndex(
      state.original.sentences[sentenceIndex],
      position,
    );
    final totalMs = state.original.duration.inMilliseconds;
    final progress = totalMs <= 0
        ? 0.0
        : (position.inMilliseconds / totalMs).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.cardPadding,
        AppSpacing.cardPadding,
        AppSpacing.cardPadding,
        AppSpacing.unit,
      ),
      decoration: BoxDecoration(
        color: AppColors.primaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 150,
            child: TimelineLyrics(
              sentences: state.original.sentences,
              currentIndex: sentenceIndex,
              activeWordIndex: activeWord,
              currentFontSize: 28,
              neighbourFontSize: 17,
              semanticLabel: '完整配音原音试听歌词',
            ),
          ),
          LinearProgressIndicator(
            value: progress,
            minHeight: 6,
            color: AppColors.primary,
            backgroundColor: Colors.white.withOpacity(.65),
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          const SizedBox(height: AppSpacing.unit),
          Text(
            '${_clock(position)} / ${_clock(state.original.duration)} · 留在这里就能直接开始配音',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

String _clock(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
