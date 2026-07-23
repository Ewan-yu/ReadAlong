import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../reader/original_audio_models.dart';
import 'dubbing_repository.dart';
import 'sentence_dubbing_controller.dart';

/// First durable dubbing mode: one sentence at a time, without mixing.
/// It deliberately keeps the original-audio page's editorial lyric focus.
class SentenceDubbingPage extends ConsumerWidget {
  const SentenceDubbingPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sentenceDubbingControllerProvider(libraryId));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.go('/reader/$libraryId/original'),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回原音欣赏',
        ),
        title: const Text('故事配音'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: AppSpacing.cardPadding),
            child: Center(
                child: Text('逐句作品',
                    style: TextStyle(
                        color: AppColors.primaryDark,
                        fontWeight: FontWeight.w700))),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _DubbingUnavailable(),
        data: (value) => _DubbingView(libraryId: libraryId, state: value),
      ),
    );
  }
}

class _DubbingUnavailable extends StatelessWidget {
  const _DubbingUnavailable();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.pageMargin),
          child:
              Text('配音需要已校验的原音时间线。请让家长重新导出并导入绘本。', textAlign: TextAlign.center),
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
    final sentence = state.sentence;
    return SafeArea(
      top: false,
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        final lyric = _LyricPanel(
            sentence: sentence,
            sequence: state.sentenceIndex + 1,
            total: state.original.sentences.length);
        final studio = _StudioPanel(
            state: state,
            onRecord: () => state.isRecording
                ? unawaited(controller.stopRecording())
                : unawaited(controller.startRecording()),
            onPrevious: () => unawaited(controller.previousSentence()),
            onNext: () => unawaited(controller.nextSentence()),
            onSelect: (take) => unawaited(controller.selectTake(take.id)),
            onDelete: (take) => unawaited(controller.deleteTake(take.id)),
            onPlay: (take) => unawaited(controller.playTake(take)),
            onRetryScore: (take) => unawaited(controller.retryScore(take)));
        return compact
            ? Column(children: [lyric, Expanded(child: studio)])
            : Row(children: [
                SizedBox(width: 360, child: lyric),
                Expanded(child: studio)
              ]);
      }),
    );
  }
}

class _LyricPanel extends StatelessWidget {
  const _LyricPanel(
      {required this.sentence, required this.sequence, required this.total});
  final OriginalAudioSentence sentence;
  final int sequence;
  final int total;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        color: AppColors.primaryContainer,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('第 $sequence / $total 句',
              style: const TextStyle(
                  color: AppColors.primaryDark, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(sentence.text,
              style: const TextStyle(
                  fontSize: 30,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.cardPadding),
          Text('${_clock(sentence.start)} — ${_clock(sentence.end)}',
              style: const TextStyle(color: AppColors.textSecondary)),
          const Spacer(),
          const Text('录好后会永久保存在“我的故事”里。',
              style: TextStyle(color: AppColors.textSecondary)),
        ]),
      );
}

class _StudioPanel extends StatelessWidget {
  const _StudioPanel(
      {required this.state,
      required this.onRecord,
      required this.onPrevious,
      required this.onNext,
      required this.onSelect,
      required this.onDelete,
      required this.onPlay,
      required this.onRetryScore});
  final SentenceDubbingState state;
  final VoidCallback onRecord;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DubbingTake> onSelect;
  final ValueChanged<DubbingTake> onDelete;
  final ValueChanged<DubbingTake> onPlay;
  final ValueChanged<DubbingTake> onRetryScore;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              state.isRecording
                  ? '正在录音 ${_clock(state.elapsed)}'
                  : state.phase == SentenceDubbingPhase.scoring
                      ? '正在评分…'
                      : '录下你的故事声音',
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.cardPadding),
          LinearProgressIndicator(
              value: state.isRecording ? state.level.clamp(0.03, 1) : 0,
              minHeight: 10,
              color: AppColors.accent,
              backgroundColor: AppColors.accentContainer),
          const SizedBox(height: AppSpacing.cardPadding),
          Center(
              child: FilledButton.icon(
                  key: const ValueKey('dubbing-record'),
                  style: FilledButton.styleFrom(
                      backgroundColor: state.isRecording
                          ? AppColors.danger
                          : AppColors.accent,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 16)),
                  onPressed:
                      state.isBusy && !state.isRecording ? null : onRecord,
                  icon: Icon(state.isRecording
                      ? Icons.stop_rounded
                      : Icons.mic_none_rounded),
                  label: Text(state.isRecording
                      ? '完成这一句'
                      : state.canRecord
                          ? '开始录音'
                          : '本句已有 3 条录音'))),
          if (state.failure != null)
            Padding(
                padding: const EdgeInsets.only(top: AppSpacing.cardPadding),
                child: Text(state.failure!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.danger))),
          if (state.result != null)
            Padding(
                padding: const EdgeInsets.only(top: AppSpacing.cardPadding),
                child: Text('这一次 ${state.result!.stars.toStringAsFixed(1)} 星',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppColors.primaryDark,
                        fontSize: 20,
                        fontWeight: FontWeight.w700))),
          const SizedBox(height: AppSpacing.cardPadding),
          Expanded(
              child: ListView(children: [
            for (final take in state.takes)
              _TakeRow(
                  take: take,
                  onSelect: () => onSelect(take),
                  onDelete: () => onDelete(take),
                  onPlay: () => onPlay(take),
                  onRetry: () => onRetryScore(take))
          ])),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            OutlinedButton.icon(
                onPressed: state.canGoPrevious ? onPrevious : null,
                icon: const Icon(Icons.arrow_back),
                label: const Text('上一句')),
            FilledButton.icon(
                onPressed: state.canGoNext ? onNext : null,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('下一句'))
          ]),
        ]),
      );
}

class _TakeRow extends StatelessWidget {
  const _TakeRow(
      {required this.take,
      required this.onSelect,
      required this.onDelete,
      required this.onPlay,
      required this.onRetry});
  final DubbingTake take;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback onPlay;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final score = take.scoreJson == null ? null : _score(take.scoreJson!);
    return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
            take.isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            color:
                take.isSelected ? AppColors.primary : AppColors.textSecondary),
        title: Text(take.isSelected ? '选用的录音' : '录音 ${_clock(take.duration)}'),
        subtitle: Text(score == null
            ? (take.scoreStatus == DubbingTakeScoreStatus.failed
                ? '暂未评分，可稍后重试'
                : '正在等待评分')
            : '${score.toStringAsFixed(1)} 星'),
        trailing: Wrap(spacing: 2, children: [
          IconButton(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow),
              tooltip: '回放'),
          if (take.scoreStatus == DubbingTakeScoreStatus.failed)
            IconButton(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                tooltip: '重试评分'),
          IconButton(
              onPressed: onSelect,
              icon: const Icon(Icons.check),
              tooltip: '选用'),
          IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除')
        ]));
  }
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
