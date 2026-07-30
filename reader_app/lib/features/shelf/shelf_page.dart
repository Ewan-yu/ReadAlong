import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/tokens.dart';
import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/book_pack_importer.dart';
import 'shelf_controller.dart';

class ShelfPage extends ConsumerWidget {
  const ShelfPage({super.key, this.onOpenBook});

  final ValueChanged<ShelfBook>? onOpenBook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(shelfControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const _ShelfBrand(),
        actions: [
          IconButton(
            key: const ValueKey('shelf-settings'),
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
          ),
          const SizedBox(width: AppSpacing.unit),
        ],
      ),
      body: shelf.when(
        data: (state) => Stack(
          children: [
            _ShelfContents(
              state: state,
              onOpen: (book) => _openBook(context, book),
              onDelete: (book) => _confirmDelete(context, ref, book),
              onImport: () => _importBook(context, ref),
            ),
            if (state.isMutating) const _ShelfMutationProgress(),
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _ShelfLoadError(),
      ),
    );
  }

  void _openBook(BuildContext context, ShelfBook book) {
    final callback = onOpenBook;
    if (callback != null) {
      callback(book);
      return;
    }
    context.push('/reader/${Uri.encodeComponent(book.libraryId)}');
  }

  Future<void> _importBook(BuildContext context, WidgetRef ref) async {
    final controller = ref.read(shelfControllerProvider.notifier);
    final result = await controller.pickAndImport();
    if (!context.mounted) return;
    await _handleResult(context, controller, result);
  }

  Future<void> _handleResult(
    BuildContext context,
    ShelfController controller,
    ShelfActionResult result,
  ) async {
    switch (result.kind) {
      case ShelfActionKind.cancelled:
      case ShelfActionKind.busy:
        return;
      case ShelfActionKind.imported:
        _showMessage(
          context,
          result.book == null ? '绘本已导入' : '已导入《${result.book!.title}》',
        );
        return;
      case ShelfActionKind.deleted:
        _showMessage(
          context,
          result.book == null ? '绘本已删除' : '已删除《${result.book!.title}》',
        );
        return;
      case ShelfActionKind.alreadyImported:
        _showMessage(
          context,
          result.book == null ? '这本绘本已经导入了' : '《${result.book!.title}》已经在书架里',
        );
        return;
      case ShelfActionKind.validationFailed:
        await _showValidationErrors(context, result.errors);
        return;
      case ShelfActionKind.conflict:
        final pending = result.pendingImport;
        if (pending == null) {
          await _showFailure(context);
          return;
        }
        final resolution = await _showConflictDialog(context);
        if (!context.mounted || resolution == null) return;
        final resolved = await controller.resolveConflict(pending, resolution);
        if (!context.mounted) return;
        await _handleResult(context, controller, resolved);
        return;
      case ShelfActionKind.failed:
        await _showFailure(context);
        return;
      case ShelfActionKind.partialDelete:
        _showMessage(context, '绘本已删除，但部分本地文件未能清理');
        return;
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ShelfBook book,
  ) async {
    var deleteRecordings = false;
    final selection = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, dialogRef, _) {
          final isBusy = dialogRef
                  .watch(shelfControllerProvider)
                  .valueOrNull
                  ?.isMutating ??
              true;
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('删除这本绘本？'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '《${book.title}》会从书架中移除。',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  CheckboxListTile(
                    value: deleteRecordings,
                    onChanged: isBusy
                        ? null
                        : (value) => setDialogState(
                              () => deleteRecordings = value ?? false,
                            ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('同时删除我的录音'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isBusy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('保留绘本'),
                ),
                TextButton(
                  onPressed: isBusy
                      ? null
                      : () => Navigator.pop(dialogContext, deleteRecordings),
                  style:
                      TextButton.styleFrom(foregroundColor: AppColors.danger),
                  child: const Text('删除绘本'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (!context.mounted || selection == null) return;

    final controller = ref.read(shelfControllerProvider.notifier);
    final result = await controller.deleteBook(
      book,
      deleteRecordings: selection,
    );
    if (!context.mounted) return;
    await _handleResult(context, controller, result);
  }

  Future<void> _showValidationErrors(
    BuildContext context,
    List<String> errors,
  ) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('绘本无法导入'),
          content: SizedBox(
            width: 480,
            height: 240,
            child: Scrollbar(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: errors.isEmpty ? 1 : errors.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) => Text(
                  errors.isEmpty ? '资源包没有通过检查，请重新导出后再试。' : errors[index],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Future<ImportConflictResolution?> _showConflictDialog(
    BuildContext context,
  ) =>
      showDialog<ImportConflictResolution>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('书架里已有这本绘本'),
          content: const Text('新绘本的内容不同。你可以替换原绘本，或把它存成一份副本。'),
          actionsPadding: const EdgeInsets.fromLTRB(
            AppSpacing.cardPadding,
            0,
            AppSpacing.cardPadding,
            AppSpacing.cardPadding,
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  ImportConflictResolution.overwrite,
                ),
                child: const Text('覆盖绘本'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(
                  context,
                  ImportConflictResolution.saveCopy,
                ),
                child: const Text('存为副本'),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('保留绘本'),
              ),
            ),
          ],
        ),
      );

  Future<void> _showFailure(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('操作没有完成'),
          content: const Text('请稍后再试。若问题持续，请重启应用后重试。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ShelfContents extends StatelessWidget {
  const _ShelfContents({
    required this.state,
    required this.onOpen,
    required this.onDelete,
    required this.onImport,
  });

  final ShelfState state;
  final ValueChanged<ShelfBook> onOpen;
  final ValueChanged<ShelfBook> onDelete;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    if (state.books.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _ShelfEmptyState(
              enabled: !state.isMutating,
              onImport: onImport,
            ),
          )
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.cardPadding,
            AppSpacing.pageMargin,
            0,
          ),
          sliver: SliverToBoxAdapter(
            child: _ShelfImportCard(
              enabled: !state.isMutating,
              onImport: onImport,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            AppSpacing.pageMargin,
            AppSpacing.pageMargin,
            AppSpacing.cardPadding,
          ),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                const Icon(Icons.auto_stories_outlined),
                const SizedBox(width: AppSpacing.unit),
                Text(
                  '我的绘本',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(width: AppSpacing.unit),
                Text(
                  '(${state.books.length})',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pageMargin,
            0,
            AppSpacing.pageMargin,
            AppSpacing.pageMargin,
          ),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.crossAxisExtent;
              final columns = width < 568
                  ? 2
                  : width < 976
                      ? 3
                      : width < 1280
                          ? 4
                          : 5;
              final childAspectRatio = width < 568 ? 0.56 : 0.62;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpacing.pageMargin,
                  crossAxisSpacing: AppSpacing.cardPadding,
                  childAspectRatio: childAspectRatio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final book = state.books[index];
                    return _BookTile(
                      book: book,
                      onTap: state.isMutating ? null : () => onOpen(book),
                      onLongPress:
                          state.isMutating ? null : () => onDelete(book),
                    );
                  },
                  childCount: state.books.length,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ShelfMutationProgress extends StatelessWidget {
  const _ShelfMutationProgress();

  @override
  Widget build(BuildContext context) => const Positioned.fill(
        child: ColoredBox(
          color: AppColors.scrim,
          child: Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.pageMargin),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    SizedBox(width: AppSpacing.cardPadding),
                    Text('正在处理本地资源，请稍候…'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _ShelfEmptyState extends StatelessWidget {
  const _ShelfEmptyState({required this.enabled, required this.onImport});

  final bool enabled;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpacing.pageMargin),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.auto_stories,
              size: 88,
              color: AppColors.primary,
              semanticLabel: '空书架',
            ),
            const SizedBox(height: AppSpacing.pageMargin),
            Text(
              '书架还是空的',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: AppSpacing.unit),
            const Text(
              '让爸爸妈妈用电脑制作绘本资源包，然后导入这里吧',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.pageMargin),
            FilledButton.icon(
              key: const ValueKey('shelf-empty-import-button'),
              onPressed: enabled ? onImport : null,
              icon: const Icon(Icons.add),
              label: const Text('导入绘本'),
            ),
          ],
        ),
      );
}

class _BookTile extends StatelessWidget {
  const _BookTile({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });

  final ShelfBook book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${book.title}，${book.pageCount} 页',
        hint: onTap == null
            ? null
            : onLongPress == null
                ? '点击打开绘本'
                : '点击打开绘本，长按可删除绘本',
        button: true,
        enabled: onTap != null,
        child: Material(
          color: AppColors.bgAlt,
          elevation: 2,
          shadowColor: AppColors.scrim,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            key: ValueKey('book-tile-gesture-${book.libraryId}'),
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.bgAlt,
                            border: Border.all(color: AppColors.border),
                            borderRadius: BorderRadius.circular(AppRadius.card),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                            child: _BookCover(book: book),
                          ),
                        ),
                        Positioned(
                          right: AppSpacing.unit,
                          bottom: AppSpacing.unit,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.primaryContainer,
                              borderRadius: BorderRadius.circular(
                                AppRadius.thumbnail,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.unit,
                                vertical: AppSpacing.unit / 2,
                              ),
                              child: Text(
                                '${book.pageCount} 页',
                                style: const TextStyle(
                                  color: AppColors.primaryDark,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 64,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.cardPadding,
                        vertical: AppSpacing.unit,
                      ),
                      child: Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          height: 1.16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _ShelfBrand extends StatelessWidget {
  const _ShelfBrand();

  @override
  Widget build(BuildContext context) => const Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.menu_book_rounded, color: AppColors.bgAlt),
            ),
          ),
          SizedBox(width: AppSpacing.unit),
          Expanded(
            child: Text(
              'ReadAlong 跟读宝',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

class _ShelfImportCard extends StatelessWidget {
  const _ShelfImportCard({required this.enabled, required this.onImport});

  final bool enabled;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          const icon = DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.primaryContainer,
              borderRadius: BorderRadius.all(
                Radius.circular(AppRadius.card),
              ),
            ),
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(
                Icons.drive_folder_upload_outlined,
                size: 28,
                color: AppColors.primary,
              ),
            ),
          );
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '导入 .readalongbook 资源包',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: AppSpacing.unit / 2),
              const Text(
                '从本地文件选择资源包，添加新的绘本到书架',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          );
          final button = FilledButton.icon(
            key: const ValueKey('shelf-import-card-button'),
            onPressed: enabled ? onImport : null,
            icon: const Icon(Icons.add),
            label: const Text('导入绘本'),
          );
          final compact = constraints.maxWidth < 520;
          return Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.cardPadding,
                vertical: AppSpacing.unit + 2,
              ),
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            icon,
                            const SizedBox(width: AppSpacing.cardPadding),
                            Expanded(child: description),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.cardPadding),
                        button,
                      ],
                    )
                  : Row(
                      children: [
                        icon,
                        const SizedBox(width: AppSpacing.cardPadding),
                        Expanded(child: description),
                        const SizedBox(width: AppSpacing.cardPadding),
                        button,
                      ],
                    ),
            ),
          );
        },
      );
}

class _BookCover extends StatelessWidget {
  const _BookCover({required this.book});

  final ShelfBook book;

  @override
  Widget build(BuildContext context) {
    final thumbnailPath = p.isAbsolute(book.thumbnailPath)
        ? book.thumbnailPath
        : p.join(book.bookDir, book.thumbnailPath);
    final file = File(thumbnailPath);
    if (!file.existsSync()) return const _MissingBookCover();

    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _MissingBookCover(),
    );
  }
}

class _MissingBookCover extends StatelessWidget {
  const _MissingBookCover();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.primaryContainer,
        child: Center(
          child: Icon(
            Icons.auto_stories,
            size: 48,
            color: AppColors.primary,
            semanticLabel: '绘本封面占位',
          ),
        ),
      );
}

class _ShelfLoadError extends StatelessWidget {
  const _ShelfLoadError();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.pageMargin),
          child: Text(
            '书架暂时打不开，请稍后再试',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: AppColors.textSecondary),
          ),
        ),
      );
}
