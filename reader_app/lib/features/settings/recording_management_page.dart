import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../data/appdb/shelf_index.dart';
import '../dubbing/dubbing_repository.dart';
import 'recording_management_controller.dart';

class RecordingManagementPage extends ConsumerWidget {
  const RecordingManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final management = ref.watch(recordingManagementControllerProvider);
    final value = management.valueOrNull;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回设置',
        ),
        title: const Text('录音与作品'),
      ),
      body: management.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _ManagementLoadError(
          onRetry: () => ref.invalidate(recordingManagementControllerProvider),
        ),
        data: (state) => state.projects.isEmpty
            ? const _EmptyManagementState()
            : _ManagementList(state: state),
      ),
      bottomNavigationBar: value == null || value.selectedKeys.isEmpty
          ? null
          : _DeleteSelectionBar(
              count: value.selectedKeys.length,
              deleting: value.deleting,
              onDelete: () => _confirmDelete(context, ref, value),
            ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    RecordingManagementState state,
  ) async {
    if (state.deleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除选中的 ${state.selectedKeys.length} 项？'),
        content: const Text(
          '录音和作品会从本机永久删除，无法恢复。绘本资源不会受到影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('recording-management-confirm-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(recordingManagementControllerProvider.notifier)
          .deleteSelected();
    }
  }
}

class _ManagementList extends ConsumerWidget {
  const _ManagementList({required this.state});

  final RecordingManagementState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(recordingManagementControllerProvider.notifier);
    final rows = <Object>[];
    String? previousLibraryId;
    for (final project in state.projects) {
      if (project.book.libraryId != previousLibraryId) {
        rows.add(project.book);
        previousLibraryId = project.book.libraryId;
      }
      rows.add(project);
    }
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(recordingManagementControllerProvider);
        await ref.read(recordingManagementControllerProvider.future);
      },
      child: ListView.builder(
        key: const ValueKey('recording-management-list'),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pageMargin,
          AppSpacing.cardPadding,
          AppSpacing.pageMargin,
          AppSpacing.pageMargin + 88,
        ),
        itemCount: rows.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _ManagementSummary(
              state: state,
              onToggleAll: controller.toggleAll,
              onDismissMessage: controller.clearMessage,
            );
          }
          final row = rows[index - 1];
          if (row is ShelfBook) {
            return Padding(
              padding: const EdgeInsets.only(
                top: AppSpacing.pageMargin,
                bottom: AppSpacing.unit,
              ),
              child: Text(
                row.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.unit),
            child: _ProjectSurface(
              project: row as ManagedRecordingProject,
              selectedKeys: state.selectedKeys,
              enabled: !state.deleting,
              onToggleProject: controller.toggleProject,
              onToggleItem: controller.toggle,
            ),
          );
        },
      ),
    );
  }
}

class _ManagementSummary extends StatelessWidget {
  const _ManagementSummary({
    required this.state,
    required this.onToggleAll,
    required this.onDismissMessage,
  });

  final RecordingManagementState state;
  final VoidCallback onToggleAll;
  final VoidCallback onDismissMessage;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${state.takeCount} 条录音 · ${state.mixCount} 个作品',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 4),
          const Text(
            '这里只管理孩子保存的声音，删除不会影响已导入的绘本。',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          if (state.message != null) ...[
            const SizedBox(height: AppSpacing.cardPadding),
            Material(
              color: state.messageIsError
                  ? AppColors.danger.withOpacity(.08)
                  : AppColors.primaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: ListTile(
                leading: Icon(
                  state.messageIsError
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  color: state.messageIsError
                      ? AppColors.danger
                      : AppColors.primary,
                ),
                title: Text(state.message!),
                trailing: IconButton(
                  onPressed: onDismissMessage,
                  tooltip: '关闭提示',
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
          ],
          CheckboxListTile(
            key: const ValueKey('recording-management-select-all'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: state.selectedKeys.length == state.itemCount,
            onChanged: state.deleting ? null : (_) => onToggleAll(),
            title: const Text('全选'),
          ),
        ],
      );
}

class _ProjectSurface extends StatelessWidget {
  const _ProjectSurface({
    required this.project,
    required this.selectedKeys,
    required this.enabled,
    required this.onToggleProject,
    required this.onToggleItem,
  });

  final ManagedRecordingProject project;
  final Set<String> selectedKeys;
  final bool enabled;
  final ValueChanged<ManagedRecordingProject> onToggleProject;
  final ValueChanged<String> onToggleItem;

  @override
  Widget build(BuildContext context) {
    final projectKeys = project.items.map((item) => item.selectionKey).toSet();
    final selectedCount = projectKeys.intersection(selectedKeys).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bgAlt,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: ExpansionTile(
        key: PageStorageKey('recording-project-${project.project.id}'),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Checkbox(
          key: ValueKey('recording-project-select-${project.project.id}'),
          tristate: true,
          value: selectedCount == 0
              ? false
              : selectedCount == projectKeys.length
                  ? true
                  : null,
          onChanged: enabled ? (_) => onToggleProject(project) : null,
        ),
        title: Text(
          project.project.mode == DubbingMode.sentence ? '逐句配音' : '完整配音',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${project.takeCount} 条录音 · ${project.mixCount} 个作品',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        children: [
          const Divider(height: 1),
          for (final item in project.items)
            CheckboxListTile(
              key: ValueKey('recording-item-${item.selectionKey}'),
              value: selectedKeys.contains(item.selectionKey),
              onChanged:
                  enabled ? (_) => onToggleItem(item.selectionKey) : null,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(_itemTitle(item)),
              subtitle: Text(_itemSubtitle(item)),
              secondary: Icon(
                item.kind == ManagedRecordingKind.mix
                    ? Icons.library_music_outlined
                    : Icons.mic_none_rounded,
                color: item.kind == ManagedRecordingKind.mix
                    ? AppColors.primary
                    : AppColors.accent,
              ),
            ),
        ],
      ),
    );
  }
}

class _DeleteSelectionBar extends StatelessWidget {
  const _DeleteSelectionBar({
    required this.count,
    required this.deleting,
    required this.onDelete,
  });

  final int count;
  final bool deleting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.bgAlt,
        elevation: 8,
        child: SafeArea(
          minimum: const EdgeInsets.all(AppSpacing.cardPadding),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选择 $count 项',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('recording-management-delete'),
                onPressed: deleting ? null : onDelete,
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.danger),
                icon: deleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.bgAlt,
                        ),
                      )
                    : const Icon(Icons.delete_outline),
                label: Text(deleting ? '正在删除' : '删除'),
              ),
            ],
          ),
        ),
      );
}

class _EmptyManagementState extends StatelessWidget {
  const _EmptyManagementState();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.mic_none_rounded,
                size: 64,
                color: AppColors.textSecondary,
              ),
              SizedBox(height: AppSpacing.cardPadding),
              Text(
                '还没有保存的录音',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: AppSpacing.unit),
              Text(
                '孩子完成逐句或完整配音后，会在这里统一管理。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
}

class _ManagementLoadError extends StatelessWidget {
  const _ManagementLoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '暂时无法读取录音',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.unit),
              const Text('录音没有被删除，可以稍后重试。'),
              const SizedBox(height: AppSpacing.cardPadding),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
}

String _itemTitle(ManagedRecordingItem item) {
  if (item.kind == ManagedRecordingKind.take) {
    return item.take!.takeKind == DubbingTakeKind.sentence ? '逐句录音' : '完整录音';
  }
  return item.mix!.variant == DubbingMixVariant.background ? '背景音乐作品' : '纯人声作品';
}

String _itemSubtitle(ManagedRecordingItem item) {
  final local = item.createdAt.toLocal();
  final date = '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
  final seconds = item.duration.inMilliseconds / 1000;
  final selected = item.take?.isSelected == true ? ' · 当前选用' : '';
  return '$date · ${seconds.toStringAsFixed(1)} 秒$selected';
}

String _two(int value) => value.toString().padLeft(2, '0');
