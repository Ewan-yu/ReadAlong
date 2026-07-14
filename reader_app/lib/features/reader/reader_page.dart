import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import 'point_reading_controller.dart';
import 'point_reading_models.dart';
import 'reader_geometry.dart';
import 'reader_models.dart';
import 'reader_repository.dart';
import 'subtitle_timing.dart';

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

class _ReaderView extends ConsumerStatefulWidget {
  const _ReaderView({super.key, required this.book});

  final ReaderBook book;

  @override
  ConsumerState<_ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<_ReaderView> {
  late final PageController _pageController;
  late final ScrollController _thumbnailController;
  late final List<TransformationController> _transforms;
  late final List<bool> _zoomedPages;
  var _currentIndex = 0;
  var _isStripVisible = true;
  var _horizontalSwipeDistance = 0.0;
  var _alignmentFailureShown = false;
  var _playbackFeedbackScheduled = false;

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
    unawaited(
      ref
          .read(pointReadingControllerProvider(widget.book.libraryId).notifier)
          .stopForPageChange(),
    );
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
    final pointReadingProvider =
        pointReadingControllerProvider(widget.book.libraryId);
    ref.listen<AsyncValue<PointReadingState>>(
      pointReadingProvider,
      (previous, next) => _handlePointReadingFeedback(
        previous,
        next,
      ),
    );
    final pointReading = ref.watch(pointReadingProvider);
    final activeSentence = pointReading.valueOrNull?.activeSentence;
    final pageView = PageView.builder(
      key: const ValueKey('reader-page-view'),
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemCount: widget.book.pages.length,
      itemBuilder: (context, index) {
        final page = widget.book.pages[index];
        final imageFile = File(page.imagePath);
        if (!imageFile.existsSync()) {
          return _MissingReaderPage(pageNumber: page.pageNumber);
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final canvasSize = constraints.biggest;
            final imageRect = containedImageRect(
              canvasSize: canvasSize,
              imageSize: Size(
                page.widthPx.toDouble(),
                page.heightPx.toDouble(),
              ),
            );
            return GestureDetector(
              key: ValueKey('reader-tap-surface-${page.pageNumber}'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handlePageTap(
                pageNumber: page.pageNumber,
                viewportPoint: details.localPosition,
                imageRect: imageRect,
                transformation: _transforms[index],
              ),
              child: InteractiveViewer(
                key: ValueKey('reader-canvas-${page.pageNumber}'),
                transformationController: _transforms[index],
                minScale: 1,
                maxScale: 4,
                panEnabled: _zoomedPages[index],
                onInteractionStart: (_) => _startPageInteraction(index),
                onInteractionUpdate: (details) =>
                    _updatePageInteraction(index, details),
                onInteractionEnd: (details) =>
                    _endPageInteraction(index, details),
                child: SizedBox.fromSize(
                  size: canvasSize,
                  child: Stack(
                    key: ValueKey('reader-image-stack-${page.pageNumber}'),
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        imageFile,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _MissingReaderPage(
                          pageNumber: page.pageNumber,
                        ),
                      ),
                      _ReaderHighlight(
                        sentence: activeSentence?.pageNumber == page.pageNumber
                            ? activeSentence
                            : null,
                        imageRect: imageRect,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
          late final Widget readerArea;
          if (constraints.maxWidth >= AppSizes.readerWideLayout) {
            readerArea = Row(
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
          } else {
            readerArea = Column(
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
          }
          return Column(
            children: [
              Expanded(child: readerArea),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: pointReading.valueOrNull?.subtitleSentence == null
                    ? const SizedBox.shrink()
                    : _ReaderSubtitleBand(
                        state: pointReading.requireValue,
                        compact:
                            constraints.maxWidth < AppSizes.readerWideLayout,
                        maxHeight:
                            (constraints.maxHeight * 0.35).clamp(0.0, 220.0),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _handlePageTap({
    required int pageNumber,
    required Offset viewportPoint,
    required Rect imageRect,
    required TransformationController transformation,
  }) {
    final normalized = viewportPointToNormalized(
      viewportPoint: viewportPoint,
      transformation: transformation,
      imageRect: imageRect,
    );
    if (normalized == null) return;
    unawaited(
      ref
          .read(pointReadingControllerProvider(widget.book.libraryId).notifier)
          .playAt(pageNumber, normalized),
    );
  }

  void _handlePointReadingFeedback(
    AsyncValue<PointReadingState>? previous,
    AsyncValue<PointReadingState> next,
  ) {
    if (next.hasError && !_alignmentFailureShown) {
      _alignmentFailureShown = true;
      _showMessageAfterFrame('点读资源暂时不可用，请重新导入绘本');
      return;
    }
    final failure = next.valueOrNull?.failure;
    if (failure == null ||
        previous?.valueOrNull?.failure == failure ||
        _playbackFeedbackScheduled) {
      return;
    }
    _playbackFeedbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这一句暂时无法播放，请重新导入绘本')),
      );
      ref
          .read(pointReadingControllerProvider(widget.book.libraryId).notifier)
          .clearFailure();
      _playbackFeedbackScheduled = false;
    });
  }

  void _showMessageAfterFrame(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    });
  }
}

class _ReaderHighlight extends StatelessWidget {
  const _ReaderHighlight({required this.sentence, required this.imageRect});

  final ReaderSentence? sentence;
  final Rect imageRect;

  @override
  Widget build(BuildContext context) {
    final active = sentence;
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        reverseDuration: const Duration(milliseconds: 300),
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        ),
        child: active == null
            ? const SizedBox.expand(key: ValueKey('reader-highlight-empty'))
            : SizedBox.expand(
                key: ValueKey('reader-highlight-layer-${active.id}'),
                child: Stack(
                  children: [
                    Positioned(
                      left: imageRect.left + active.bbox.x * imageRect.width,
                      top: imageRect.top + active.bbox.y * imageRect.height,
                      width: active.bbox.width * imageRect.width,
                      height: active.bbox.height * imageRect.height,
                      child: CustomPaint(
                        key: ValueKey('reader-highlight-${active.id}'),
                        painter: const _ReaderHighlightPainter(),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ReaderHighlightPainter extends CustomPainter {
  const _ReaderHighlightPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()..color = AppColors.highlight.withOpacity(0.3),
    );
    canvas.drawRect(
      rect.deflate(1),
      Paint()
        ..color = AppColors.highlightBorder
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawRect(
      rect.deflate(2.5),
      Paint()
        ..color = AppColors.bgAlt
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ReaderHighlightPainter oldDelegate) => false;
}

class _ReaderSubtitleBand extends StatelessWidget {
  const _ReaderSubtitleBand({
    required this.state,
    required this.compact,
    required this.maxHeight,
  });

  final PointReadingState state;
  final bool compact;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final sentence = state.subtitleSentence!;
    final segments = buildSubtitleSegments(
      sentence.text,
      sentence.wordTimings,
    );
    final fontSize = compact ? 20.0 : 26.0;
    final progress = playbackProgress(
      state.playbackPosition,
      state.playbackDuration,
    );
    return ConstrainedBox(
      key: const ValueKey('reader-subtitle-band'),
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.bgAlt,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal:
                compact ? AppSpacing.cardPadding : AppSpacing.pageMargin,
            vertical: compact ? AppSpacing.unit : AppSpacing.cardPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Semantics(
                    label: sentence.text,
                    container: true,
                    child: ExcludeSemantics(
                      child: _SubtitleText(
                        sentence: sentence,
                        segments: segments,
                        activeWordIndex: state.activeWordIndex,
                        fontSize: fontSize,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.unit),
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(
                      _formatPlaybackTime(state.playbackPosition),
                      key: const ValueKey('reader-subtitle-elapsed'),
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: LinearProgressIndicator(
                      key: const ValueKey('reader-subtitle-progress'),
                      value: progress,
                      minHeight: 5,
                      color: AppColors.primary,
                      backgroundColor: AppColors.border,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      _formatPlaybackTime(state.playbackDuration),
                      key: const ValueKey('reader-subtitle-duration'),
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubtitleText extends StatelessWidget {
  const _SubtitleText({
    required this.sentence,
    required this.segments,
    required this.activeWordIndex,
    required this.fontSize,
  });

  final ReaderSentence sentence;
  final List<SubtitleTextSegment> segments;
  final int? activeWordIndex;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      color: AppColors.textPrimary,
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
    );
    if (sentence.wordTimings.isEmpty ||
        !segments.any((segment) => segment.wordIndex != null)) {
      return Text(
        sentence.text,
        textAlign: TextAlign.center,
        style: baseStyle,
      );
    }
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          for (final segment in segments)
            if (segment.wordIndex == activeWordIndex)
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: DecoratedBox(
                  key: ValueKey(
                    'reader-subtitle-active-word-${segment.wordIndex}',
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.highlight,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.unit / 2,
                      vertical: 2,
                    ),
                    child: Text(
                      segment.text,
                      style: baseStyle.copyWith(color: AppColors.primaryDark),
                    ),
                  ),
                ),
              )
            else
              TextSpan(text: segment.text),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}

String _formatPlaybackTime(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 5999);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
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
