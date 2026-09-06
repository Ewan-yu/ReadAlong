import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/tokens.dart';
import '../../data/appdb/app_database_providers.dart';
import '../follow/follow_reading_controller.dart';
import '../../services/audio/encouragement_audio.dart';
import '../../services/scoring/score_models.dart';
import 'point_reading_controller.dart';
import 'point_reading_models.dart';
import 'reader_geometry.dart';
import 'reader_models.dart';
import 'reader_repository.dart';
import 'original_audio_repository.dart';
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

class _ReaderViewState extends ConsumerState<_ReaderView>
    with WidgetsBindingObserver {
  late final PageController _pageController;
  late final ScrollController _thumbnailController;
  late final List<TransformationController> _transforms;
  late final List<bool> _zoomedPages;
  final Map<int, Size> _decodedPageSizes = {};
  final Set<int> _pendingPageSizes = {};
  var _currentIndex = 0;
  var _isStripVisible = true;
  var _horizontalSwipeDistance = 0.0;
  var _alignmentFailureShown = false;
  var _playbackFeedbackScheduled = false;
  int? _scoreDialogRecordId;
  var _tapSequence = 0;
  var _sentenceNavigationSequence = 0;
  int? _pendingSentenceNavigationPage;
  PointReadingBook? _orderedSentencesBook;
  List<ReaderSentence> _orderedSentencesCache = const [];
  var _defaultSentenceSelectionQueued = false;
  Timer? _progressSaveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController();
    _thumbnailController = ScrollController();
    _zoomedPages = List.filled(widget.book.pages.length, false);
    _transforms = List.generate(widget.book.pages.length, (index) {
      final controller = TransformationController();
      controller.addListener(() => _handleTransform(index));
      return controller;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _precacheAround(_currentIndex);
      unawaited(_restoreReadingProgress());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _thumbnailController.dispose();
    _progressSaveTimer?.cancel();
    for (final controller in _transforms) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _pendingSentenceNavigationPage = null;
      _sentenceNavigationSequence++;
      final sequence = ++_tapSequence;
      unawaited(_stopReaderAudioForBackground(sequence));
    }
  }

  Future<void> _stopReaderAudioForBackground(int sequence) async {
    final pointProvider = pointReadingControllerProvider(widget.book.libraryId);
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    await ref.read(pointProvider.notifier).stopForPageChange();
    if (!mounted || sequence != _tapSequence) return;
    await ref.read(followProvider.notifier).handleAppBackgrounded();
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
    final controlledNavigation = _pendingSentenceNavigationPage == index;
    if (controlledNavigation) {
      _pendingSentenceNavigationPage = null;
    }
    final sequence = ++_tapSequence;
    if (!controlledNavigation) {
      unawaited(_stopReaderForPageChangeAndSelectFirst(
        sequence: sequence,
        pageIndex: index,
      ));
    }
    final previous = _currentIndex;
    _zoomedPages[previous] = false;
    _transforms[previous].value = Matrix4.identity();
    setState(() => _currentIndex = index);
    _precacheAround(index);
    _revealThumbnail(index);
    _scheduleProgressSave();
  }

  Future<void> _stopReaderForPageChangeAndSelectFirst({
    required int sequence,
    required int pageIndex,
  }) async {
    await _stopReaderForPageChange(sequence);
    if (!mounted || sequence != _tapSequence || pageIndex != _currentIndex) {
      return;
    }
    await _selectFirstSentenceWhenReady(pageIndex);
  }

  Future<void> _stopReaderForPageChange(int sequence) async {
    final pointProvider = pointReadingControllerProvider(widget.book.libraryId);
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    await ref.read(pointProvider.notifier).stopForPageChange();
    if (!mounted || sequence != _tapSequence) return;
    await ref.read(followProvider.notifier).stopForPageChange();
  }

  Future<void> _restoreReadingProgress() async {
    try {
      final index = await ref.read(shelfIndexProvider.future);
      final stored = await index.loadProgress(widget.book.libraryId);
      final page = stored?.currentPage;
      if (!mounted || page == null) return;
      final target = widget.book.pages.indexWhere(
        (candidate) => candidate.pageNumber == page,
      );
      if (target <= 0 || target >= widget.book.pages.length) return;
      _pageController.jumpToPage(target);
      setState(() => _currentIndex = target);
      _precacheAround(target);
      _revealThumbnail(target);
      unawaited(_selectFirstSentenceWhenReady(target, replaceExisting: true));
    } on Object {
      // Progress is optional runtime data; a corrupt row must not block reading.
    }
  }

  void _scheduleDefaultSentenceSelection() {
    if (!mounted || _defaultSentenceSelectionQueued) {
      return;
    }
    final pointReading = ref
        .read(pointReadingControllerProvider(widget.book.libraryId))
        .valueOrNull;
    if (pointReading == null) return;
    final currentFollowSentence = ref
        .read(followReadingControllerProvider(widget.book.libraryId))
        .valueOrNull
        ?.sentence;
    if (currentFollowSentence != null) return;

    _defaultSentenceSelectionQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _defaultSentenceSelectionQueued = false;
      if (!mounted) return;
      unawaited(_selectFirstSentenceWhenReady(_currentIndex));
    });
  }

  Future<void> _selectFirstSentenceWhenReady(
    int pageIndex, {
    bool replaceExisting = false,
  }) async {
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    if (!mounted || pageIndex != _currentIndex) return;
    final current = ref.read(followProvider).valueOrNull?.sentence;
    if (current != null && !replaceExisting) return;
    _selectFirstSentenceForPage(pageIndex);
  }

  void _selectFirstSentenceForPage(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= widget.book.pages.length) return;
    final pointReading = ref
        .read(pointReadingControllerProvider(widget.book.libraryId))
        .valueOrNull;
    if (pointReading == null) return;
    final sentences = pointReading.book
        .sentencesForPage(widget.book.pages[pageIndex].pageNumber);
    if (sentences.isEmpty) return;
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    final current = ref.read(followProvider).valueOrNull?.sentence;
    if (current?.id == sentences.first.id) return;
    // Selecting the sentence must not start audio. The child can immediately
    // use the stable toolbar, while tapping the artwork remains the explicit
    // gesture that starts playback.
    ref.read(followProvider.notifier).selectSentence(sentences.first);
  }

  void _scheduleProgressSave() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer(const Duration(milliseconds: 450), () async {
      try {
        final index = await ref.read(shelfIndexProvider.future);
        await index.saveProgress(
          libraryId: widget.book.libraryId,
          currentPage: widget.book.pages[_currentIndex].pageNumber,
        );
      } on Object {
        // A progress write is best-effort and should never interrupt reading.
      }
    });
  }

  void _selectPage(int index) {
    if (!_pageController.hasClients || index == _currentIndex) return;
    _pendingSentenceNavigationPage = null;
    _sentenceNavigationSequence++;
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
    // The visible page loads itself. Prefetch only the likely next page so a
    // three-page full-resolution cache cannot overwhelm emulator GPU bridges.
    for (final candidate in [index + 1]) {
      if (candidate < 0 || candidate >= widget.book.pages.length) continue;
      precacheImage(
        _readerPageImage(widget.book.pages[candidate]),
        context,
        onError: (_, __) {},
      );
    }
  }

  void _capturePageImageSize(ReaderPageData page) {
    if (_decodedPageSizes.containsKey(page.pageNumber) ||
        !_pendingPageSizes.add(page.pageNumber)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final stream = _readerPageImage(page).resolve(
        createLocalImageConfiguration(context),
      );
      late final ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          stream.removeListener(listener);
          _pendingPageSizes.remove(page.pageNumber);
          if (!mounted) return;
          final size = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          if (size.isEmpty || _decodedPageSizes[page.pageNumber] == size) {
            return;
          }
          setState(() => _decodedPageSizes[page.pageNumber] = size);
        },
        onError: (_, __) {
          stream.removeListener(listener);
          _pendingPageSizes.remove(page.pageNumber);
        },
      );
      stream.addListener(listener);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pointReadingProvider =
        pointReadingControllerProvider(widget.book.libraryId);
    ref.listen<AsyncValue<PointReadingState>>(
      pointReadingProvider,
      (previous, next) {
        _handlePointReadingFeedback(previous, next);
        if (next.hasValue) _scheduleDefaultSentenceSelection();
      },
    );
    final pointReading = ref.watch(pointReadingProvider);
    final originalAudioReady = ref.watch(
      originalAudioReadyProvider(widget.book.libraryId),
    );
    final followReadingProvider =
        followReadingControllerProvider(widget.book.libraryId);
    ref.listen<AsyncValue<FollowReadingState>>(
      followReadingProvider,
      (previous, next) {
        _handleFollowReadingFeedback(previous, next);
        if (next.hasValue) _scheduleDefaultSentenceSelection();
      },
    );
    final followSentence = ref.watch(
      followReadingProvider.select((value) => value.valueOrNull?.sentence),
    );
    final followPhase = ref.watch(
      followReadingProvider.select((value) => value.valueOrNull?.phase),
    );
    final pointState = pointReading.valueOrNull;
    if (pointState != null) _scheduleDefaultSentenceSelection();
    final orderedSentences = pointState == null
        ? const <ReaderSentence>[]
        : _orderedSentences(pointState.book);
    final selectedSentenceIndex = followSentence == null
        ? -1
        : orderedSentences
            .indexWhere((sentence) => sentence.id == followSentence.id);
    final canPreviousSentence = selectedSentenceIndex > 0;
    final canNextSentence = selectedSentenceIndex >= 0 &&
        selectedSentenceIndex + 1 < orderedSentences.length;
    final activeSentence = pointReading.valueOrNull?.activeSentence ??
        (followPhase != null && followPhase != FollowReadingPhase.idle
            ? followSentence
            : null);
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
            _capturePageImageSize(page);
            final imageSize = _decodedPageSizes[page.pageNumber] ??
                Size(
                  page.widthPx.toDouble(),
                  page.heightPx.toDouble(),
                );
            final imageRect = containedImageRect(
              canvasSize: canvasSize,
              imageSize: imageSize,
            );
            return GestureDetector(
              key: ValueKey('reader-tap-surface-${page.pageNumber}'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handlePageTap(
                pageNumber: page.pageNumber,
                viewportPoint: details.localPosition,
                imageRect: imageRect,
                transformation: _transforms[index],
                pointReading: pointReading.valueOrNull,
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
                      Positioned.fromRect(
                        rect: imageRect,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.bgAlt,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.scrim,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Image(
                        key: ValueKey('reader-page-image-${page.pageNumber}'),
                        image: _readerPageImage(page),
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
          if (originalAudioReady.valueOrNull == true)
            IconButton(
              onPressed: () => context.push(
                '/reader/${widget.book.libraryId}/original',
              ),
              icon: const Icon(Icons.headphones_outlined),
              tooltip: '听原音',
            ),
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
          final compact = constraints.maxWidth < AppSizes.readerWideLayout;
          final controlPanelHeight =
              (constraints.maxHeight * (compact ? 0.28 : 0.22))
                  .clamp(
                    AppSizes.readerControlPanelMinHeight,
                    AppSizes.readerControlPanelMaxHeight,
                  )
                  .toDouble();
          return Column(
            children: [
              Expanded(child: readerArea),
              SizedBox(
                key: const ValueKey('follow-stable-panel'),
                height: controlPanelHeight,
                child: RepaintBoundary(
                  child: Consumer(
                    builder: (context, panelRef, _) {
                      final followReading =
                          panelRef.watch(followReadingProvider);
                      return _FollowReadingPanel(
                        state: followReading,
                        compact: compact,
                        pointReadingError: pointReading.hasError,
                        pointPlaybackSentenceId: pointState?.activeSentence?.id,
                        pointPlaybackWordIndex: pointState?.activeWordIndex,
                        onRetryPointReading: () {
                          _alignmentFailureShown = false;
                          panelRef.invalidate(pointReadingProvider);
                        },
                        onRecord: () => unawaited(
                          _startSelectedRecording(),
                        ),
                        onStop: () => unawaited(panelRef
                            .read(followReadingProvider.notifier)
                            .stopRecording()),
                        onCancelPreparation: () => unawaited(panelRef
                            .read(followReadingProvider.notifier)
                            .cancelPreparation()),
                        onRetry: () => unawaited(panelRef
                            .read(followReadingProvider.notifier)
                            .retryScoring()),
                        onMyRecording: () => unawaited(panelRef
                            .read(followReadingProvider.notifier)
                            .playMyRecording()),
                        onPrevious: () => unawaited(_navigateSentence(
                          delta: -1,
                          pointReading: pointState,
                          current: followReading.valueOrNull?.sentence,
                        )),
                        onNext: () => unawaited(_navigateSentence(
                          delta: 1,
                          pointReading: pointState,
                          current: followReading.valueOrNull?.sentence,
                        )),
                        canPrevious: canPreviousSentence,
                        canNext: canNextSentence,
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _handlePageTap({
    required int pageNumber,
    required Offset viewportPoint,
    required Rect imageRect,
    required TransformationController transformation,
    required PointReadingState? pointReading,
  }) async {
    final normalized = viewportPointToNormalized(
      viewportPoint: viewportPoint,
      transformation: transformation,
      imageRect: imageRect,
    );
    if (normalized == null) return;
    _pendingSentenceNavigationPage = null;
    _sentenceNavigationSequence++;
    final book = pointReading?.book;
    if (book == null) return;
    final matches = hitTestSentences(
      sentences: book.sentencesForPage(pageNumber),
      normalizedPoint: normalized,
    );
    final selected = matches.isEmpty ? null : matches.first;
    if (selected == null) {
      _showMessageAfterFrame('点一下绘本中的一句话，就可以开始跟读');
      return;
    }
    final sequence = ++_tapSequence;
    final pointController = ref.read(
      pointReadingControllerProvider(widget.book.libraryId).notifier,
    );
    final followController = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );
    followController.selectSentence(selected);
    await pointController.stopForPageChange();
    if (!mounted || sequence != _tapSequence) return;
    unawaited(pointController.playAt(pageNumber, normalized));
  }

  Future<void> _playSelectedDemonstration() async {
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    final sentence = ref.read(followProvider).valueOrNull?.sentence;
    if (sentence == null) return;
    final pointController = ref.read(
      pointReadingControllerProvider(widget.book.libraryId).notifier,
    );
    final followController = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );
    await pointController.stopForPageChange();
    if (!mounted) return;
    await followController.playDemonstration();
  }

  Future<void> _startSelectedRecording() async {
    final followProvider =
        followReadingControllerProvider(widget.book.libraryId);
    if (ref.read(followProvider).valueOrNull?.sentence == null) return;
    final pointController = ref.read(
      pointReadingControllerProvider(widget.book.libraryId).notifier,
    );
    final followController = ref.read(followProvider.notifier);
    await pointController.stopForPageChange();
    if (!mounted) return;
    await followController.startRecording();
  }

  List<ReaderSentence> _orderedSentences(PointReadingBook book) {
    if (identical(_orderedSentencesBook, book)) {
      return _orderedSentencesCache;
    }
    final sorted = book.sentencesByPage.values
        .expand((sentences) => sentences)
        .toList()
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
    _orderedSentencesBook = book;
    _orderedSentencesCache = List.unmodifiable(sorted);
    return _orderedSentencesCache;
  }

  Future<void> _navigateSentence({
    required int delta,
    required PointReadingState? pointReading,
    required ReaderSentence? current,
  }) async {
    if (pointReading == null || current == null) return;
    final all = _orderedSentences(pointReading.book);
    final index = all.indexWhere((sentence) => sentence.id == current.id);
    final targetIndex = index + delta;
    if (index < 0 || targetIndex < 0 || targetIndex >= all.length) {
      _showMessageAfterFrame(delta < 0 ? '已经是第一句啦' : '已经是最后一句啦');
      return;
    }

    final navigationSequence = ++_sentenceNavigationSequence;
    final target = all[targetIndex];
    final targetPageIndex = widget.book.pages.indexWhere(
      (page) => page.pageNumber == target.pageNumber,
    );
    final pointController = ref.read(
      pointReadingControllerProvider(widget.book.libraryId).notifier,
    );
    final followController = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );

    if (targetPageIndex >= 0 && targetPageIndex != _currentIndex) {
      // Stop both readers before starting the page animation. The page
      // callback skips its normal stop for this controlled transition, so it
      // cannot race the target sentence's playback after the animation.
      _pendingSentenceNavigationPage = targetPageIndex;
      final stopSequence = ++_tapSequence;
      await _stopReaderForPageChange(stopSequence);
      if (!_isSentenceNavigationCurrent(navigationSequence)) return;
      if (!_pageController.hasClients) return;
      await _pageController.animateToPage(
        targetPageIndex,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      if (!_isSentenceNavigationCurrent(navigationSequence)) return;
    }

    if (!_isSentenceNavigationCurrent(navigationSequence)) return;
    followController.selectSentence(target);
    await pointController.playSentence(target);
  }

  bool _isSentenceNavigationCurrent(int sequence) =>
      mounted && sequence == _sentenceNavigationSequence;

  void _handlePointReadingFeedback(
    AsyncValue<PointReadingState>? previous,
    AsyncValue<PointReadingState> next,
  ) {
    if (next.hasError && !_alignmentFailureShown) {
      _alignmentFailureShown = true;
      final error = next.error;
      debugPrint('readalong.point_reading load failed: $error');
      if (error is PointReadingLoadException && error.cause != null) {
        debugPrint('readalong.point_reading cause: ${error.cause}');
      }
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

  void _handleFollowReadingFeedback(
    AsyncValue<FollowReadingState>? previous,
    AsyncValue<FollowReadingState> next,
  ) {
    final current = next.valueOrNull;
    final recordId = current?.record?.id;
    if (current?.phase != FollowReadingPhase.scored ||
        current?.result == null ||
        recordId == null ||
        _scoreDialogRecordId == recordId) {
      return;
    }
    _scoreDialogRecordId = recordId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showScoreDialog(current!));
    });
  }

  Future<void> _showScoreDialog(FollowReadingState state) async {
    final score = state.result;
    final sentence = state.sentence;
    if (score == null || sentence == null || !mounted) return;
    unawaited(
      ref.read(encouragementAudioPlayerProvider).playForStars(score.stars),
    );
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: FollowScoreDialog(
          sentence: sentence,
          score: score,
          onClose: () {
            Navigator.of(dialogContext).pop();
            unawaited(_finishScoreAndClose());
          },
          onDemo: () {
            Navigator.of(dialogContext).pop();
            unawaited(_finishScoreAndPlayDemonstration());
          },
          onRepeat: () {
            Navigator.of(dialogContext).pop();
            unawaited(_finishScoreAndRecordAgain());
          },
          onMyRecording: () {
            unawaited(_playMyRecordingInScoreDialog());
          },
          onNext: () {
            Navigator.of(dialogContext).pop();
            unawaited(_finishScoreAndGoNext(sentence));
          },
        ),
      ),
    );
  }

  Future<void> _finishScoreAndPlayDemonstration() async {
    final controller = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );
    await controller.acknowledgeResult();
    await _playSelectedDemonstration();
  }

  Future<void> _finishScoreAndClose() => ref
      .read(
        followReadingControllerProvider(widget.book.libraryId).notifier,
      )
      .acknowledgeResult();

  Future<void> _finishScoreAndRecordAgain() async {
    final controller = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );
    await controller.acknowledgeResult();
    await controller.startRecording();
  }

  Future<void> _playMyRecordingInScoreDialog() async {
    final played = await ref
        .read(
          followReadingControllerProvider(widget.book.libraryId).notifier,
        )
        .playMyRecording();
    if (!mounted || played) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('我的录音暂时无法播放，请再录一次')),
    );
  }

  Future<void> _finishScoreAndGoNext(ReaderSentence sentence) async {
    final controller = ref.read(
      followReadingControllerProvider(widget.book.libraryId).notifier,
    );
    await controller.acknowledgeResult();
    if (!mounted) return;
    await _navigateSentence(
      delta: 1,
      pointReading: ref
          .read(pointReadingControllerProvider(widget.book.libraryId))
          .valueOrNull,
      current: sentence,
    );
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

ImageProvider<Object> _readerPageImage(ReaderPageData page) => ResizeImage(
      FileImage(File(page.imagePath)),
      width: page.widthPx.clamp(1, 2048),
    );

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

class _ReaderControlPanelFrame extends StatelessWidget {
  const _ReaderControlPanelFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.bgAlt,
          border: Border(top: BorderSide(color: AppColors.border)),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.subtitleBar),
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.scrim,
              blurRadius: 16,
              offset: Offset(0, -3),
            ),
          ],
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            primary: false,
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(child: child),
            ),
          ),
        ),
      );
}

class _FollowReadingPanel extends StatelessWidget {
  const _FollowReadingPanel({
    required this.state,
    required this.compact,
    required this.pointReadingError,
    required this.pointPlaybackSentenceId,
    required this.pointPlaybackWordIndex,
    required this.onRetryPointReading,
    required this.onRecord,
    required this.onStop,
    required this.onCancelPreparation,
    required this.onRetry,
    required this.onMyRecording,
    required this.onPrevious,
    required this.onNext,
    required this.canPrevious,
    required this.canNext,
  });

  final AsyncValue<FollowReadingState> state;
  final bool compact;
  final bool pointReadingError;
  final String? pointPlaybackSentenceId;
  final int? pointPlaybackWordIndex;
  final VoidCallback onRetryPointReading;
  final VoidCallback onRecord;
  final VoidCallback onStop;
  final VoidCallback onCancelPreparation;
  final VoidCallback onRetry;
  final VoidCallback onMyRecording;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool canPrevious;
  final bool canNext;

  @override
  Widget build(BuildContext context) {
    if (pointReadingError) {
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? AppSpacing.unit : AppSpacing.cardPadding,
            vertical: compact ? AppSpacing.unit : AppSpacing.cardPadding,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('点读资源暂时不可用'),
              const SizedBox(height: AppSpacing.unit),
              OutlinedButton.icon(
                onPressed: onRetryPointReading,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    return state.when(
      loading: () => const _ReaderControlPanelFrame(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.cardPadding),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (_, __) => const _ReaderControlPanelFrame(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.cardPadding),
          child: Text('跟读功能暂时无法准备好，请稍后再试'),
        ),
      ),
      data: (value) => _buildContent(context, value),
    );
  }

  Widget _buildContent(BuildContext context, FollowReadingState value) {
    final sentence = value.sentence;
    final pointPlaybackActive = pointPlaybackSentenceId == sentence?.id &&
        pointPlaybackWordIndex != null;
    final activeWordIndex = value.phase == FollowReadingPhase.demonstrating
        ? value.activeWordIndex
        : pointPlaybackActive
            ? pointPlaybackWordIndex
            : null;
    final panelPadding = EdgeInsets.symmetric(
      horizontal: compact ? AppSpacing.unit : AppSpacing.cardPadding,
      vertical: compact ? AppSpacing.unit : AppSpacing.cardPadding,
    );
    if (sentence == null) {
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.touch_app_outlined, color: AppColors.primary),
              SizedBox(width: AppSpacing.unit),
              Text('点一下绘本中的一句话，开始跟读'),
            ],
          ),
        ),
      );
    }
    if (value.phase == FollowReadingPhase.scoring) {
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.hearing_rounded,
                size: 36,
                color: AppColors.primary,
              ),
              const SizedBox(height: AppSpacing.unit),
              const Text('录音已收到，正在评分…'),
            ],
          ),
        ),
      );
    }
    if (value.isPreparing) {
      final countdown = value.phase == FollowReadingPhase.countdown;
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FollowSentenceText(sentence: sentence, compact: compact),
              const SizedBox(height: AppSpacing.unit),
              Text(
                countdown ? '${value.countdown}' : '麦克风准备中',
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: countdown ? (compact ? 34 : 42) : 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: AppSpacing.unit),
              const Text(
                '看到“开始读吧”再开口，第一个字会更完整',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              IconButton(
                key: const ValueKey('follow-cancel-preparation'),
                onPressed: onCancelPreparation,
                icon: const Icon(Icons.close_rounded),
                tooltip: '取消录音准备',
              ),
            ],
          ),
        ),
      );
    }
    if (value.phase == FollowReadingPhase.recording) {
      final recordingPrompt = !value.heardSpeech
          ? '开始读吧，我在认真听'
          : value.level < followSpeechLevelThreshold
              ? '读完后停一下，会自动结束'
              : '听得很清楚，继续读吧';
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FollowSentenceText(sentence: sentence, compact: compact),
              const SizedBox(height: AppSpacing.unit),
              Text(
                '${_formatPlaybackTime(value.elapsed)} / '
                '${_formatPlaybackTime(value.recordingLimit)}',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.unit),
              _RecordingMeter(level: value.level),
              const SizedBox(height: AppSpacing.unit),
              Text(
                recordingPrompt,
                style: TextStyle(
                    color: !value.heardSpeech
                        ? AppColors.accent
                        : AppColors.primaryDark),
              ),
              SizedBox(
                  height: compact ? AppSpacing.unit : AppSpacing.cardPadding),
              IconButton.filled(
                key: const ValueKey('follow-stop-recording'),
                constraints: const BoxConstraints.tightFor(
                  width: 64,
                  height: 64,
                ),
                style: IconButton.styleFrom(backgroundColor: AppColors.danger),
                onPressed: onStop,
                icon: const Icon(Icons.stop_rounded),
                tooltip: '停止录音',
              ),
            ],
          ),
        ),
      );
    }
    if (value.phase == FollowReadingPhase.scored && value.result != null) {
      // The result itself is presented in a focused confirmation dialog.
      // Keep this panel quiet and stable behind it so the reading canvas does
      // not jump while the child is receiving feedback.
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FollowSentenceText(sentence: sentence, compact: compact),
              SizedBox(
                  height: compact ? AppSpacing.unit : AppSpacing.cardPadding),
              const Text('评价完成啦'),
            ],
          ),
        ),
      );
    }
    if (value.phase == FollowReadingPhase.failed) {
      return _ReaderControlPanelFrame(
        child: Padding(
          padding: panelPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FollowSentenceText(sentence: sentence, compact: compact),
              const SizedBox(height: AppSpacing.unit),
              Text(value.failure ?? '分数马上来～',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary)),
              SizedBox(
                  height: compact ? AppSpacing.unit : AppSpacing.cardPadding),
              Wrap(
                spacing: AppSpacing.unit,
                runSpacing: AppSpacing.unit,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                      onPressed: onMyRecording,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('听我的录音')),
                  FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试评分')),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return _ReaderControlPanelFrame(
      child: Padding(
        padding: panelPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FollowSentenceText(
              sentence: sentence,
              activeWordIndex: activeWordIndex,
              compact: compact,
            ),
            SizedBox(
                height: compact ? AppSpacing.unit : AppSpacing.cardPadding),
            _FollowDemoProgress(
              value: value.phase == FollowReadingPhase.demonstrating
                  ? playbackProgress(
                      value.playbackPosition,
                      value.playbackDuration,
                    )
                  : 0,
              visible: value.phase == FollowReadingPhase.demonstrating,
            ),
            const SizedBox(height: AppSpacing.unit),
            _ReaderSentenceNavigationBar(
              canPrevious: canPrevious,
              canNext: canNext,
              recordingEnabled: value.phase != FollowReadingPhase.demonstrating,
              onPrevious: onPrevious,
              onRecord: onRecord,
              onNext: onNext,
            ),
          ],
        ),
      ),
    );
  }
}

class _FollowSentenceText extends StatelessWidget {
  const _FollowSentenceText({
    required this.sentence,
    this.activeWordIndex,
    this.compact = false,
  });
  final ReaderSentence sentence;
  final int? activeWordIndex;
  final bool compact;
  @override
  Widget build(BuildContext context) => Semantics(
        label: sentence.text,
        container: true,
        child: ExcludeSemantics(
          child: _SubtitleText(
            sentence: sentence,
            segments:
                buildSubtitleSegments(sentence.text, sentence.wordTimings),
            activeWordIndex: activeWordIndex,
            fontSize: compact ? 18 : 24,
          ),
        ),
      );
}

class _ReaderSentenceNavigationBar extends StatelessWidget {
  const _ReaderSentenceNavigationBar({
    required this.canPrevious,
    required this.canNext,
    required this.recordingEnabled,
    required this.onPrevious,
    required this.onRecord,
    required this.onNext,
  });

  final bool canPrevious;
  final bool canNext;
  final bool recordingEnabled;
  final VoidCallback onPrevious;
  final VoidCallback onRecord;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            key: const ValueKey('reader-previous-sentence'),
            onPressed: canPrevious ? onPrevious : null,
            tooltip: '上一句',
            constraints: const BoxConstraints.tightFor(
              width: AppSizes.minTouchTarget,
              height: AppSizes.minTouchTarget,
            ),
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          IconButton.filled(
            key: const ValueKey('follow-start-recording'),
            onPressed: recordingEnabled ? onRecord : null,
            tooltip: '开始录音',
            constraints: const BoxConstraints.tightFor(
              width: 64,
              height: 64,
            ),
            style: IconButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: AppColors.bgAlt,
            ),
            icon: const Icon(Icons.mic_none_rounded),
          ),
          IconButton(
            key: const ValueKey('reader-next-sentence'),
            onPressed: canNext ? onNext : null,
            tooltip: '下一句',
            constraints: const BoxConstraints.tightFor(
              width: AppSizes.minTouchTarget,
              height: AppSizes.minTouchTarget,
            ),
            icon: const Icon(Icons.arrow_forward_rounded),
          ),
        ],
      );
}

class _FollowDemoProgress extends StatelessWidget {
  const _FollowDemoProgress({required this.value, required this.visible});

  final double value;
  final bool visible;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 5,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 5,
            color: AppColors.primary,
            backgroundColor: AppColors.border,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
}

class _RecordingMeter extends StatelessWidget {
  const _RecordingMeter({required this.level});
  final double level;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LinearProgressIndicator(
          value: level.clamp(0.04, 1.0),
          minHeight: 10,
          color: AppColors.accent,
          backgroundColor: AppColors.accentContainer,
        ),
      );
}

class FollowScoreDialog extends StatelessWidget {
  const FollowScoreDialog({
    required this.sentence,
    required this.score,
    required this.onClose,
    required this.onDemo,
    required this.onMyRecording,
    required this.onRepeat,
    required this.onNext,
  });
  final ReaderSentence sentence;
  final ScoreResult score;
  final VoidCallback onClose;
  final VoidCallback onDemo;
  final VoidCallback onMyRecording;
  final VoidCallback onRepeat;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final message = switch (score.stars) {
      < 2.5 => '加油！再试一次😊',
      < 4.0 => '不错，继续加油！👍',
      _ => '太棒了！🌟',
    };
    return Dialog(
      key: const ValueKey('follow-score-dialog'),
      insetPadding: const EdgeInsets.all(AppSpacing.pageMargin),
      backgroundColor: AppColors.bgAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pageMargin,
                AppSpacing.pageMargin + 12,
                AppSpacing.pageMargin,
                AppSpacing.cardPadding,
              ),
              child: Semantics(
                liveRegion: true,
                label: '跟读评价：$message',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.celebration_rounded,
                        color: AppColors.accent, size: 34),
                    const SizedBox(height: AppSpacing.unit),
                    _Stars(stars: score.stars),
                    const SizedBox(height: AppSpacing.unit),
                    Text(
                      message,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primaryDark,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.cardPadding),
                    _ScoredSentence(sentence: sentence, scores: score.words),
                    const SizedBox(height: AppSpacing.cardPadding),
                    Wrap(
                      spacing: AppSpacing.unit,
                      runSpacing: AppSpacing.unit,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: onDemo,
                          icon: const Icon(Icons.volume_up_outlined),
                          label: const Text('听示范'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('follow-play-my-recording'),
                          onPressed: onMyRecording,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('听我的录音'),
                        ),
                        OutlinedButton.icon(
                          onPressed: onRepeat,
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('再读一次'),
                        ),
                        FilledButton.icon(
                          onPressed: onNext,
                          icon: const Icon(Icons.arrow_forward_rounded),
                          label: const Text('下一句'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    _ScoreDetails(score: score),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                key: const ValueKey('follow-score-close'),
                onPressed: onClose,
                tooltip: '关闭评价',
                icon: const Icon(Icons.close_rounded),
                iconSize: 28,
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars({required this.stars});
  final double stars;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
            5,
            (index) => Icon(
                index + 1 <= stars
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                color: AppColors.highlightBorder,
                size: 38)),
      );
}

class _ScoredSentence extends StatelessWidget {
  const _ScoredSentence({required this.sentence, required this.scores});
  final ReaderSentence sentence;
  final List<WordScore> scores;
  @override
  Widget build(BuildContext context) {
    final failed = scores
        .where((score) => score.isError)
        .map((score) => score.word.toLowerCase())
        .toSet();
    final words = RegExp(r'\S+')
        .allMatches(sentence.text)
        .map((match) => match.group(0)!)
        .toList();
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        for (final word in words)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              word,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: failed.contains(
                        word.replaceAll(RegExp(r'[^A-Za-z]'), '').toLowerCase())
                    ? AppColors.danger
                    : AppColors.textPrimary,
                decoration: failed.contains(
                        word.replaceAll(RegExp(r'[^A-Za-z]'), '').toLowerCase())
                    ? TextDecoration.underline
                    : null,
                decorationColor: AppColors.danger,
                decorationThickness: 2,
              ),
            ),
          ),
      ],
    );
  }
}

class _ScoreDetails extends StatelessWidget {
  const _ScoreDetails({required this.score});
  final ScoreResult score;
  @override
  Widget build(BuildContext context) => ExpansionTile(
        title: const Text('家长查看详情',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.unit),
            child: Wrap(
              spacing: AppSpacing.cardPadding,
              runSpacing: AppSpacing.unit,
              alignment: WrapAlignment.center,
              children: [
                _detail('准确度', score.accuracy),
                _detail('流利度', score.fluency),
                _detail('完整度', score.integrity),
                _detail('标准度', score.standard),
              ],
            ),
          ),
        ],
      );
  Widget _detail(String label, double? value) =>
      Text('$label ${value?.round() ?? '—'}');
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
            if (segment.wordIndex != null &&
                segment.wordIndex == activeWordIndex)
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
