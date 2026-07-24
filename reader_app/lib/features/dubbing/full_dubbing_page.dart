import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'dubbing_repository.dart';
import 'full_dubbing_controller.dart';

/// One uninterrupted performance, kept separately from sentence practice.
class FullDubbingPage extends ConsumerWidget {
  const FullDubbingPage({super.key, required this.libraryId});
  final String libraryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(fullDubbingControllerProvider(libraryId));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.go('/reader/$libraryId/dub'),
          tooltip: '返回逐句配音',
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('完整配音'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.cardPadding),
            child: state.maybeWhen(
              data: (value) => Center(
                child: Text(value.isComplete ? '已完成' : '草稿',
                    style: const TextStyle(
                        color: AppColors.primaryDark,
                        fontWeight: FontWeight.w700)),
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
          child: Text('完整配音需要已校验的原音时间线。请让家长重新导出并导入绘本。',
              textAlign: TextAlign.center),
        )),
        data: (value) => _FullDubbingView(libraryId: libraryId, state: value),
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
              state.phase == FullDubbingPhase.countdown
                  ? '${state.countdown}'
                  : state.isRecording
                      ? '正在讲故事  ${_clock(state.elapsed)}'
                      : '一口气讲完这个故事',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: state.phase == FullDubbingPhase.countdown ? 72 : 28,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  color: state.phase == FullDubbingPhase.countdown
                      ? AppColors.accent
                      : AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.cardPadding),
          Text(
              state.phase == FullDubbingPhase.countdown
                  ? '准备好了吗？'
                  : '录音会连续保存成一条作品，可按原音时间轴逐句评分。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: AppSpacing.pageMargin),
          LinearProgressIndicator(
              value: state.isRecording ? state.level.clamp(0.03, 1) : 0,
              minHeight: 12,
              color: AppColors.accent,
              backgroundColor: AppColors.accentContainer),
          const SizedBox(height: AppSpacing.pageMargin),
          Center(
            child: FilledButton.icon(
              key: const ValueKey('full-dubbing-record'),
              style: FilledButton.styleFrom(
                  backgroundColor:
                      state.isRecording ? AppColors.danger : AppColors.accent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 30, vertical: 18)),
              onPressed: state.phase == FullDubbingPhase.countdown
                  ? () => unawaited(controller.cancelCountdown())
                  : state.isRecording
                      ? () => unawaited(controller.stopRecording())
                      : state.canStart
                          ? () => unawaited(controller.startCountdown())
                          : null,
              icon: Icon(state.phase == FullDubbingPhase.countdown
                  ? Icons.close
                  : state.isRecording
                      ? Icons.stop_rounded
                      : Icons.mic_none_rounded),
              label: Text(state.phase == FullDubbingPhase.countdown
                  ? '取消'
                  : state.isRecording
                      ? '结束录音'
                      : '3 秒后开始'),
            ),
          ),
          if (state.failure != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.cardPadding),
              child: Text(state.failure!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.danger)),
            ),
          const SizedBox(height: AppSpacing.pageMargin),
          const Text('我的完整作品',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.unit),
          Expanded(
            child: state.takes.isEmpty
                ? const Center(
                    child: Text('录下第一遍故事后，会保存在这里。',
                        style: TextStyle(color: AppColors.textSecondary)))
                : ListView(children: [
                    for (final take in state.takes)
                      ListTile(
                        leading: Icon(
                            take.isSelected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: take.isSelected
                                ? AppColors.primary
                                : AppColors.textSecondary),
                        title: Text(take.isSelected
                            ? '当前选用版本'
                            : '完整录音 ${_clock(take.duration)}'),
                        subtitle: Text(
                          take.scoreStatus == DubbingTakeScoreStatus.scored
                              ? '已评分，查看本次逐句表现'
                              : take.scoreStatus ==
                                      DubbingTakeScoreStatus.failed
                                  ? '评分未完成，可重新评分'
                                  : '已保存，尚未评分',
                        ),
                        trailing: Wrap(spacing: 0, children: [
                          IconButton(
                              onPressed: () =>
                                  unawaited(controller.playTake(take)),
                              tooltip: '回放',
                              icon: const Icon(Icons.play_arrow)),
                          IconButton(
                              onPressed: state.isBusy
                                  ? null
                                  : () => unawaited(controller.scoreTake(take)),
                              tooltip: '逐句评分',
                              icon: const Icon(Icons.auto_graph_rounded)),
                          IconButton(
                              onPressed: () =>
                                  unawaited(controller.selectTake(take.id)),
                              tooltip: '选用',
                              icon: const Icon(Icons.check)),
                          IconButton(
                              onPressed: () =>
                                  unawaited(controller.deleteTake(take.id)),
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline)),
                        ]),
                      )
                  ]),
          ),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: state.isBusy
                      ? null
                      : () => unawaited(controller.saveDraft()),
                  child: const Text('保存草稿')),
            ),
            const SizedBox(width: AppSpacing.cardPadding),
            Expanded(
              child: FilledButton(
                  onPressed: state.isBusy || selected == null
                      ? null
                      : () => unawaited(controller.complete()),
                  child: const Text('完成作品')),
            ),
          ]),
          const SizedBox(height: AppSpacing.unit),
          FilledButton.icon(
            key: const ValueKey('full-dubbing-create-work'),
            onPressed: state.isBusy || selected == null
                ? null
                : () => unawaited(controller.createMix()),
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(state.phase == FullDubbingPhase.mixing
                ? '正在生成作品…'
                : state.original.backgroundPath == null
                    ? '生成纯人声作品'
                    : '生成背景版作品'),
          ),
          if (state.mixes.isNotEmpty)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                state.mixes.first.variant == DubbingMixVariant.background
                    ? Icons.music_note_rounded
                    : Icons.record_voice_over_rounded,
                color: AppColors.primary,
              ),
              title: Text(
                  state.mixes.first.variant == DubbingMixVariant.background
                      ? '最新背景版作品'
                      : '最新纯人声作品'),
              trailing: Wrap(children: [
                IconButton(
                  tooltip: '回放作品',
                  onPressed: () =>
                      unawaited(controller.playMix(state.mixes.first)),
                  icon: const Icon(Icons.play_arrow),
                ),
                IconButton(
                  tooltip: '删除作品',
                  onPressed: state.isBusy
                      ? null
                      : () =>
                          unawaited(controller.deleteMix(state.mixes.first.id)),
                  icon: const Icon(Icons.delete_outline),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

String _clock(Duration duration) =>
    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
