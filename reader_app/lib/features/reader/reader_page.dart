import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'reader_models.dart';
import 'reader_repository.dart';

class ReaderPage extends ConsumerWidget {
  const ReaderPage({super.key, required this.libraryId});

  final String libraryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(readerBookProvider(libraryId));
    return book.when(
      loading: () => const Scaffold(
        appBar: _ReaderBackAppBar(),
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const Scaffold(
        appBar: _ReaderBackAppBar(),
        body: _ReaderLoadError(),
      ),
      data: (value) => _ReaderView(
        key: ValueKey('${value.libraryId}-${value.pages.length}'),
        book: value,
      ),
    );
  }
}

class _ReaderBackAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ReaderBackAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
        leading: IconButton(
          onPressed: () => _returnToShelf(context),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回书架',
        ),
      );
}

class _ReaderLoadError extends StatelessWidget {
  const _ReaderLoadError();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.pageMargin),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 64,
                color: AppColors.textSecondary,
              ),
              SizedBox(height: AppSpacing.cardPadding),
              Text(
                '这本绘本暂时打不开',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: AppSpacing.unit),
              Text(
                '资源可能已损坏，请返回书架后重新导入',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
}

class _ReaderView extends StatefulWidget {
  const _ReaderView({super.key, required this.book});

  final ReaderBook book;

  @override
  State<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<_ReaderView> {
  late final PageController _pageController;
  late final ScrollController _thumbnailController;
  late final List<TransformationController> _transforms;
  late final List<bool> _zoomedPages;
  var _currentIndex = 0;
  var _isStripVisible = true;
  var _horizontalSwipeDistance = 0.0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _thumbnailController = ScrollController();
    _zoomedPages = List.filled(widget.book.pages.length, false);
    _transforms = List.generate(widget.book.pages.length, (index) {
      final controller = TransformationController();
      controller.addListener(() => _handleTransform(index));
      return controller;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _precacheAround(_currentIndex);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _thumbnailController.dispose();
    for (final controller in _transforms) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleTransform(int index) {
    final zoomed = _transforms[index].value.getMaxScaleOnAxis() > 1.001;
    if (_zoomedPages[index] == zoomed || !mounted) return;
    setState(() {
      _zoomedPages[index] = zoomed;
      if (zoomed) _horizontalSwipeDistance = 0;
    });
  }

  void _onPageChanged(int index) {
    final previous = _currentIndex;
    _zoomedPages[previous] = false;
    _transforms[previous].value = Matrix4.identity();
    setState(() => _currentIndex = index);
    _precacheAround(index);
    _revealThumbnail(index);
  }

  void _selectPage(int index) {
    if (!_pageController.hasClients || index == _currentIndex) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _startPageInteraction(int index) {
    if (index == _currentIndex && !_zoomedPages[index]) {
      _horizontalSwipeDistance = 0;
    }
  }

  void _updatePageInteraction(int index, ScaleUpdateDetails details) {
    if (index == _currentIndex && !_zoomedPages[index]) {
      _horizontalSwipeDistance += details.focalPointDelta.dx;
    }
  }

  void _endPageInteraction(int index, ScaleEndDetails details) {
    if (index != _currentIndex || _zoomedPages[index]) return;
    final distance = _horizontalSwipeDistance;
    _horizontalSwipeDistance = 0;
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (distance.abs() < 48 && velocity.abs() < 300) return;
    final target = distance < 0 || velocity < -300 ? index + 1 : index - 1;
    if (target >= 0 && target < widget.book.pages.length) {
      _selectPage(target);
    }
  }

  void _revealThumbnail(int index) {
    if (!_thumbnailController.hasClients) return;
    const extent = AppSizes.readerThumbnailHeight;
    final position = _thumbnailController.position;
    final target = (index * extent).clamp(0.0, position.maxScrollExtent);
    _thumbnailController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _precacheAround(int index) {
    for (final candidate in [index - 1, index, index + 1]) {
      if (candidate < 0 || candidate >= widget.book.pages.length) continue;
      precacheImage(
        FileImage(File(widget.book.pages[candidate].imagePath)),
        context,
        onError: (_, __) {},
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageView = PageView.builder(
      key: const ValueKey('reader-page-view'),
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemCount: widget.book.pages.length,
      itemBuilder: (context, index) {
        final page = widget.book.pages[index];
        final imageFile = File(page.imagePath);
        return InteractiveViewer(
          key: ValueKey('reader-canvas-${page.pageNumber}'),
          transformationController: _transforms[index],
          minScale: 1,
          maxScale: 4,
          panEnabled: _zoomedPages[index],
          onInteractionStart: (_) => _startPageInteraction(index),
          onInteractionUpdate: (details) =>
              _updatePageInteraction(index, details),
          onInteractionEnd: (details) => _endPageInteraction(index, details),
          child: SizedBox.expand(
            child: imageFile.existsSync()
                ? Image.file(
                    imageFile,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _MissingReaderPage(
                      pageNumber: page.pageNumber,
                    ),
                  )
                : _MissingReaderPage(pageNumber: page.pageNumber),
          ),
        );
      },
    );

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => _returnToShelf(context),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回书架',
        ),
        title: Text(
          widget.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          SizedBox(
            width: 80,
            child: Center(
              child: Text(
                '${_currentIndex + 1} / ${widget.book.pages.length}',
                key: const ValueKey('reader-page-indicator'),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.unit),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= AppSizes.readerWideLayout) {
            return Row(
              children: [
                Expanded(child: pageView),
                _VerticalThumbnailRail(
                  book: widget.book,
                  currentIndex: _currentIndex,
                  visible: _isStripVisible,
                  controller: _thumbnailController,
                  onSelected: _selectPage,
                  onToggle: () => setState(
                    () => _isStripVisible = !_isStripVisible,
                  ),
                ),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: pageView),
              _HorizontalThumbnailStrip(
                book: widget.book,
                currentIndex: _currentIndex,
                controller: _thumbnailController,
                onSelected: _selectPage,
              ),
            ],
          );
        },
      ),
    );
  }
}

void _returnToShelf(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/shelf');
  }
}

class _MissingReaderPage extends StatelessWidget {
  const _MissingReaderPage({required this.pageNumber});

  final int pageNumber;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppColors.primaryContainer,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                size: 56,
                color: AppColors.textSecondary,
              ),
              const SizedBox(height: AppSpacing.unit),
              const Text(
                '这一页的图片缺失',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: AppSpacing.unit / 2),
              Text(
                '第 $pageNumber 页',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      );
}

class _VerticalThumbnailRail extends StatelessWidget {
  const _VerticalThumbnailRail({
    required this.book,
    required this.currentIndex,
    required this.visible,
    required this.controller,
    required this.onSelected,
    required this.onToggle,
  });

  final ReaderBook book;
  final int currentIndex;
  final bool visible;
  final ScrollController controller;
  final ValueChanged<int> onSelected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return SizedBox(
        width: AppSizes.readerCollapsedStripWidth,
        child: Align(
          alignment: Alignment.topCenter,
          child: IconButton(
            key: const ValueKey('reader-thumbnail-toggle'),
            onPressed: onToggle,
            icon: const Icon(Icons.chevron_left),
            tooltip: '展开页面缩略图',
          ),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('reader-thumbnail-strip-vertical'),
      width: AppSizes.thumbnailStripWidth,
      child: Column(
        children: [
          IconButton(
            key: const ValueKey('reader-thumbnail-toggle'),
            onPressed: onToggle,
            icon: const Icon(Icons.chevron_right),
            tooltip: '收起页面缩略图',
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: book.pages.length,
              itemBuilder: (context, index) => _ReaderThumbnail(
                page: book.pages[index],
                selected: currentIndex == index,
                axis: Axis.vertical,
                onTap: () => onSelected(index),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HorizontalThumbnailStrip extends StatelessWidget {
  const _HorizontalThumbnailStrip({
    required this.book,
    required this.currentIndex,
    required this.controller,
    required this.onSelected,
  });

  final ReaderBook book;
  final int currentIndex;
  final ScrollController controller;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: const ValueKey('reader-thumbnail-strip-horizontal'),
        height: AppSizes.readerThumbnailHeight,
        child: ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          itemCount: book.pages.length,
          itemBuilder: (context, index) => _ReaderThumbnail(
            page: book.pages[index],
            selected: currentIndex == index,
            axis: Axis.horizontal,
            onTap: () => onSelected(index),
          ),
        ),
      );
}

class _ReaderThumbnail extends StatelessWidget {
  const _ReaderThumbnail({
    required this.page,
    required this.selected,
    required this.axis,
    required this.onTap,
  });

  final ReaderPageData page;
  final bool selected;
  final Axis axis;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final thumbnailFile = File(page.thumbnailPath);
    return Semantics(
      key: ValueKey('reader-thumbnail-${page.pageNumber}'),
      button: true,
      selected: selected,
      label: '第 ${page.pageNumber} 页',
      child: SizedBox(
        width: axis == Axis.vertical ? AppSizes.thumbnailStripWidth : 72,
        height: AppSizes.readerThumbnailHeight,
        child: Material(
          color: AppColors.bg,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.unit / 2),
              child: Column(
                children: [
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color:
                                selected ? AppColors.primary : AppColors.border,
                            width: selected ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(
                            AppRadius.thumbnail,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppRadius.thumbnail - 1,
                          ),
                          child: thumbnailFile.existsSync()
                              ? Image.file(
                                  thumbnailFile,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const _MissingThumbnail(),
                                )
                              : const _MissingThumbnail(),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    '${page.pageNumber}',
                    style: TextStyle(
                      color: selected
                          ? AppColors.primaryDark
                          : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MissingThumbnail extends StatelessWidget {
  const _MissingThumbnail();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.primaryContainer,
        child: Icon(
          Icons.image_not_supported_outlined,
          color: AppColors.textSecondary,
        ),
      );
}
