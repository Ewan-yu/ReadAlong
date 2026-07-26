/// Durable, app-private metadata for a child's dubbing work.
///
/// This data deliberately refers to an imported [libraryId], rather than a
/// resource-pack path.  A future overwrite can therefore decide whether the
/// source/timeline fingerprints are compatible without moving a child's audio.
enum DubbingMode { sentence, full }

enum DubbingProjectStatus { draft, complete, incompatible }

enum DubbingTakeKind { sentence, full }

enum DubbingTakeScoreStatus { pending, scored, failed }

/// A rendered work is independent from the recording Takes it was made from.
/// This lets a child keep listening to a finished work after replacing a Take.
enum DubbingMixVariant { voiceOnly, background }

final class DubbingProject {
  const DubbingProject({
    required this.id,
    required this.libraryId,
    required this.sourceBookId,
    required this.resourceSha256,
    required this.timelineSha256,
    required this.mode,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String libraryId;
  final String sourceBookId;
  final String resourceSha256;
  final String timelineSha256;
  final DubbingMode mode;
  final DubbingProjectStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory DubbingProject.fromMap(Map<String, Object?> map) => DubbingProject(
        id: map['id']! as String,
        libraryId: map['library_id']! as String,
        sourceBookId: map['source_book_id']! as String,
        resourceSha256: map['resource_sha256']! as String,
        timelineSha256: map['timeline_sha256']! as String,
        mode: DubbingMode.values.byName(map['mode']! as String),
        status: DubbingProjectStatus.values.byName(map['status']! as String),
        createdAt: DateTime.parse(map['created_at']! as String),
        updatedAt: DateTime.parse(map['updated_at']! as String),
      );
}

/// A single permanent recording. [audioRelativePath] is always relative to
/// the application documents directory; imported book-pack directories are
/// never used to store a child's voice.
final class DubbingTake {
  const DubbingTake({
    required this.id,
    required this.projectId,
    required this.takeKind,
    required this.audioRelativePath,
    required this.duration,
    required this.isSelected,
    required this.scoreStatus,
    required this.createdAt,
    this.sentenceId,
    this.contentOffset = Duration.zero,
    this.scoreJson,
    this.scoreError,
  });

  final String id;
  final String projectId;
  final String? sentenceId;
  final DubbingTakeKind takeKind;
  final String audioRelativePath;
  final Duration duration;

  /// Lead-in captured while Android stabilizes the microphone and the child
  /// sees the countdown. Existing v5 Takes default to zero and keep their
  /// original playback, scoring and mixing semantics.
  final Duration contentOffset;
  final bool isSelected;
  final DubbingTakeScoreStatus scoreStatus;
  final String? scoreJson;
  final String? scoreError;
  final DateTime createdAt;

  factory DubbingTake.fromMap(Map<String, Object?> map) => DubbingTake(
        id: map['id']! as String,
        projectId: map['project_id']! as String,
        sentenceId: map['sentence_id'] as String?,
        takeKind: DubbingTakeKind.values.byName(map['take_kind']! as String),
        audioRelativePath: map['audio_path']! as String,
        duration: Duration(milliseconds: map['duration_ms']! as int),
        contentOffset: Duration(
          milliseconds: (map['content_offset_ms'] as int?) ?? 0,
        ),
        isSelected: (map['selected']! as int) != 0,
        scoreStatus: DubbingTakeScoreStatus.values
            .byName(map['score_status']! as String),
        scoreJson: map['score_json'] as String?,
        scoreError: map['score_error'] as String?,
        createdAt: DateTime.parse(map['created_at']! as String),
      );
}

final class DubbingMix {
  const DubbingMix({
    required this.id,
    required this.projectId,
    required this.audioRelativePath,
    required this.variant,
    required this.sourceTakeFingerprint,
    required this.duration,
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final String audioRelativePath;
  final DubbingMixVariant variant;
  final String sourceTakeFingerprint;
  final Duration duration;
  final DateTime createdAt;

  factory DubbingMix.fromMap(Map<String, Object?> map) => DubbingMix(
        id: map['id']! as String,
        projectId: map['project_id']! as String,
        audioRelativePath: map['audio_path']! as String,
        variant: DubbingMixVariant.values.byName(map['variant']! as String),
        sourceTakeFingerprint: map['source_take_fingerprint']! as String,
        duration: Duration(milliseconds: map['duration_ms']! as int),
        createdAt: DateTime.parse(map['created_at']! as String),
      );
}
