import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'alignment_repository.dart';
import 'point_reading_models.dart';
import 'reader_geometry.dart';
import 'sentence_audio_player.dart';
import 'subtitle_timing.dart' as subtitle_timing;

enum PointReadingFailure { playback }

final class PointReadingState {
  const PointReadingState({
    required this.book,
    this.activeSentence,
    this.subtitleSentence,
    this.isPlaying = false,
    this.playbackPosition = Duration.zero,
    this.playbackDuration = Duration.zero,
    this.activeWordIndex,
    this.failure,
  });

  final PointReadingBook book;
  final ReaderSentence? activeSentence;
  final ReaderSentence? subtitleSentence;
  final bool isPlaying;
  final Duration playbackPosition;
  final Duration playbackDuration;
  final int? activeWordIndex;
  final PointReadingFailure? failure;

  PointReadingState copyWith({
    Object? activeSentence = _notProvided,
    Object? subtitleSentence = _notProvided,
    bool? isPlaying,
    Duration? playbackPosition,
    Duration? playbackDuration,
    Object? activeWordIndex = _notProvided,
    Object? failure = _notProvided,
  }) =>
      PointReadingState(
        book: book,
        activeSentence: identical(activeSentence, _notProvided)
            ? this.activeSentence
            : activeSentence as ReaderSentence?,
        subtitleSentence: identical(subtitleSentence, _notProvided)
            ? this.subtitleSentence
            : subtitleSentence as ReaderSentence?,
        isPlaying: isPlaying ?? this.isPlaying,
        playbackPosition: playbackPosition ?? this.playbackPosition,
        playbackDuration: playbackDuration ?? this.playbackDuration,
        activeWordIndex: identical(activeWordIndex, _notProvided)
            ? this.activeWordIndex
            : activeWordIndex as int?,
        failure: identical(failure, _notProvided)
            ? this.failure
            : failure as PointReadingFailure?,
      );
}

const _notProvided = Object();

final pointReadingControllerProvider = AutoDisposeAsyncNotifierProviderFamily<
    PointReadingController,
    PointReadingState,
    String>(PointReadingController.new);

final class PointReadingController
    extends AutoDisposeFamilyAsyncNotifier<PointReadingState, String> {
  late SentenceAudioPlayer _player;
  var _generation = 0;
  var _disposed = false;

  @override
  Future<PointReadingState> build(String arg) async {
    _disposed = false;
    _player = ref.watch(sentenceAudioPlayerProvider);
    ref.onDispose(() {
      _disposed = true;
      _generation++;
    });
    final book = await ref.watch(pointReadingBookProvider(arg).future);
    return PointReadingState(book: book);
  }

  Future<void> playAt(int pageNumber, Offset normalizedPoint) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final group = hitTestSentences(
      sentences: current.book.sentencesForPage(pageNumber),
      normalizedPoint: normalizedPoint,
    );
    if (group.isEmpty) return;

    final generation = ++_generation;
    try {
      await _player.stop();
      if (!_isCurrent(generation)) return;
      _setState(
        current.copyWith(
          activeSentence: null,
          isPlaying: false,
          failure: null,
        ),
      );

      for (final sentence in group) {
        if (!_isCurrent(generation)) return;
        final latest = state.valueOrNull;
        if (latest == null) return;
        _setState(
          latest.copyWith(
            activeSentence: sentence,
            subtitleSentence: sentence,
            isPlaying: true,
            playbackPosition: Duration.zero,
            playbackDuration: sentence.audio.end - sentence.audio.start,
            activeWordIndex:
                subtitle_timing.activeWordIndex(sentence, Duration.zero),
            failure: null,
          ),
        );
        await _player.play(
          sentence.audio,
          onPosition: (elapsed) =>
              _handlePosition(generation, sentence, elapsed),
        );
        if (!_isCurrent(generation)) return;
      }

      final latest = state.valueOrNull;
      if (latest != null && _isCurrent(generation)) {
        _setState(
          latest.copyWith(
            activeSentence: null,
            isPlaying: false,
            playbackPosition: latest.playbackDuration,
            activeWordIndex: null,
          ),
        );
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(
          latest.copyWith(
            activeSentence: null,
            isPlaying: false,
            activeWordIndex: null,
            failure: PointReadingFailure.playback,
          ),
        );
      }
    }
  }

  Future<void> stopForPageChange() async {
    final generation = ++_generation;
    final current = state.valueOrNull;
    if (current != null) {
      _setState(
        current.copyWith(
          activeSentence: null,
          subtitleSentence: null,
          isPlaying: false,
          playbackPosition: Duration.zero,
          playbackDuration: Duration.zero,
          activeWordIndex: null,
        ),
      );
    }
    try {
      await _player.stop();
    } on Object {
      if (!_isCurrent(generation)) return;
      final latest = state.valueOrNull;
      if (latest != null) {
        _setState(latest.copyWith(failure: PointReadingFailure.playback));
      }
    }
  }

  void clearFailure() {
    final current = state.valueOrNull;
    if (current != null && current.failure != null) {
      _setState(current.copyWith(failure: null));
    }
  }

  void _handlePosition(
    int generation,
    ReaderSentence sentence,
    Duration elapsed,
  ) {
    if (!_isCurrent(generation)) return;
    final current = state.valueOrNull;
    if (current == null ||
        current.activeSentence?.id != sentence.id ||
        current.subtitleSentence?.id != sentence.id) {
      return;
    }
    final position = subtitle_timing.clampPlaybackPosition(
      elapsed,
      current.playbackDuration,
    );
    _setState(
      current.copyWith(
        playbackPosition: position,
        activeWordIndex: subtitle_timing.activeWordIndex(sentence, position),
      ),
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _setState(PointReadingState next) {
    if (!_disposed) state = AsyncData(next);
  }
}
