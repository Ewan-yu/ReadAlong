import 'dart:collection';

/// 已通过资源包时间轴校验的完整原音。
///
/// 所有时间都是从完整原音文件零点开始的绝对时间；播放器不再把它们
/// 转换为句子裁剪时间，避免 seek 后歌词逐渐漂移。
final class OriginalAudioBook {
  OriginalAudioBook({
    required this.libraryId,
    required this.audioPath,
    required this.duration,
    required List<OriginalAudioSentence> sentences,
    this.sourceBookId = '',
    this.resourceSha256 = '',
    this.timelineSha256 = '',
  }) : sentences = UnmodifiableListView(sentences);

  final String libraryId;
  final String audioPath;
  final Duration duration;
  final UnmodifiableListView<OriginalAudioSentence> sentences;

  /// Immutable identities copied from the validated pack manifest. They keep
  /// a child's durable dubbing project tied to exactly this imported timeline.
  final String sourceBookId;
  final String resourceSha256;
  final String timelineSha256;
}

final class OriginalAudioSentence {
  OriginalAudioSentence({
    required this.id,
    required this.sequence,
    required this.text,
    required this.start,
    required this.end,
    required List<OriginalAudioWord> words,
  }) : words = UnmodifiableListView(words);

  final String id;
  final int sequence;
  final String text;
  final Duration start;
  final Duration end;
  final UnmodifiableListView<OriginalAudioWord> words;
}

final class OriginalAudioWord {
  const OriginalAudioWord({
    required this.sequence,
    required this.text,
    required this.start,
    required this.end,
  });

  final int sequence;
  final String text;
  final Duration start;
  final Duration end;
}

abstract class OriginalAudioLoadException implements Exception {
  const OriginalAudioLoadException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// 有原音并不表示可播放歌词；raw / failed 对齐在这里明确拒绝。
final class OriginalAudioUnavailableException
    extends OriginalAudioLoadException {
  const OriginalAudioUnavailableException(
      [super.message = 'Original audio is not ready']);
}

final class OriginalAudioDataException extends OriginalAudioLoadException {
  const OriginalAudioDataException(
      [super.message = 'Original audio timeline is invalid']);
}
