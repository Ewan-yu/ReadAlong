import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/tokens.dart';
import '../../data/appdb/shelf_index.dart';
import '../../data/bookpack/book_pack_importer.dart';
import 'shelf_controller.dart';

/// The M1.3 library surface. Opening a book is intentionally deferred to M1.4.
class ShelfPage extends ConsumerWidget {
  const ShelfPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shelf = ref.watch(shelfControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ReadAlong 跟读宝'),
        backgroundColor: AppColors.bg,
        surfaceTintColor: AppColors.bg,
      ),
      body: shelf.when(
        data: (state) => _ShelfContents(
          state: state,
          onDelete: (book) => _confirmDelete(context, ref, book),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const _ShelfLoadError(),
      ),
      floatingActionButton: shelf.maybeWhen(
        data: (state) => FloatingActionButton.extended(
          onPressed: state.isMutating ? null : () => _importBook(context, ref),
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.bgAlt,
          disabledElevation: 0,
          icon: state.isMutating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.textSecondary,
                  ),
                )
              : const Icon(Icons.add),
          label: Text(state.isMutating ? '导入中' : '导入绘本'),
          tooltip: state.isMutating ? '正在导入绘本' : '导入绘本',
        ),
        orElse: () => null,
      ),
    );
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
  const _ShelfContents({required this.state, required this.onDelete});

  final ShelfState state;
  final ValueChanged<ShelfBook> onDelete;

  @override
  Widget build(BuildContext context) {
    if (state.books.isEmpty) {
      return const CustomScrollView(
        slivers: [
          SliverFillRemaining(hasScrollBody: false, child: _ShelfEmptyState())
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
            AppSpacing.pageMargin + AppSizes.primaryButton,
          ),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              mainAxisSpacing: AppSpacing.pageMargin,
              crossAxisSpacing: AppSpacing.cardPadding,
              childAspectRatio: 0.68,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final book = state.books[index];
                return _BookTile(
                  book: book,
                  onLongPress: state.isMutating ? null : () => onDelete(book),
                );
              },
              childCount: state.books.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _ShelfEmptyState extends StatelessWidget {
  const _ShelfEmptyState();

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
          ],
        ),
      );
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.onLongPress});

  final ShelfBook book;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${book.title}，${book.pageCount} 页',
        hint: onLongPress == null ? null : '长按可删除绘本',
        child: Material(
          color: AppColors.bg,
          child: GestureDetector(
            key: ValueKey('book-tile-gesture-${book.libraryId}'),
            behavior: HitTestBehavior.opaque,
            onLongPress: onLongPress,
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
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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
