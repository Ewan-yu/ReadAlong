import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../data/appdb/dubbing_models.dart';

/// Owns the private on-disk layout for durable dubbing files.
///
/// The recorder may write into a cache first. [persistTake] copies that file
/// to a private `.tmp` sibling, flushes it, then renames it before the caller
/// commits its database row. This keeps an interrupted recording out of the
/// visible Take list.
final class DubbingFileStore {
  DubbingFileStore({required Directory documentsDirectory})
      : _documentsDirectory = documentsDirectory;

  final Directory _documentsDirectory;

  static const _rootName = 'dubbing';

  String takeRelativePath({
    required String libraryId,
    required String projectId,
    required String takeId,
    required DubbingTakeKind kind,
    String? sentenceId,
  }) {
    _requireSegment(libraryId, 'libraryId');
    _requireSegment(projectId, 'projectId');
    _requireSegment(takeId, 'takeId');
    if (kind == DubbingTakeKind.sentence) {
      _requireSegment(sentenceId, 'sentenceId');
    } else if (sentenceId != null) {
      throw ArgumentError.value(sentenceId, 'sentenceId', '完整配音不能关联句子');
    }
    return kind == DubbingTakeKind.sentence
        ? p.posix.join(_rootName, libraryId, projectId, 'takes', sentenceId!,
            '$takeId.wav')
        : p.posix.join(
            _rootName, libraryId, projectId, 'takes', 'full', '$takeId.wav');
  }

  String mixRelativePath({
    required String libraryId,
    required String projectId,
    required String mixId,
    String extension = '.m4a',
  }) {
    _requireSegment(libraryId, 'libraryId');
    _requireSegment(projectId, 'projectId');
    _requireSegment(mixId, 'mixId');
    if (extension != '.m4a' && extension != '.wav' && extension != '.ogg') {
      throw ArgumentError.value(extension, 'extension', '不支持的作品格式');
    }
    return p.posix
        .join(_rootName, libraryId, projectId, 'mixes', '$mixId$extension');
  }

  /// Returns an absolute path only for a path produced by this store.
  String resolveRelativePath(String relativePath) {
    final normalized = p.posix.normalize(relativePath);
    if (relativePath.isEmpty ||
        p.posix.isAbsolute(relativePath) ||
        normalized == '.' ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        !normalized.startsWith('$_rootName/')) {
      throw ArgumentError.value(relativePath, 'relativePath', '不是配音私有文件路径');
    }
    return p.normalize(
      p.joinAll([_documentsDirectory.path, ...normalized.split('/')]),
    );
  }

  Future<String> persistTake({
    required File source,
    required String libraryId,
    required String projectId,
    required String takeId,
    required DubbingTakeKind kind,
    String? sentenceId,
  }) async {
    if (!await source.exists()) {
      throw FileSystemException('录音文件不存在', source.path);
    }
    final relativePath = takeRelativePath(
      libraryId: libraryId,
      projectId: projectId,
      takeId: takeId,
      kind: kind,
      sentenceId: sentenceId,
    );
    final destination = File(resolveRelativePath(relativePath));
    await destination.parent.create(recursive: true);
    final temporary = File(
      p.join(
        _projectDirectory(libraryId, projectId).path,
        '.tmp',
        '$takeId.${Random.secure().nextInt(1 << 32)}.part',
      ),
    );
    await temporary.parent.create(recursive: true);
    try {
      final sink = temporary.openWrite();
      try {
        await for (final chunk in source.openRead()) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await destination.exists()) {
        throw StateError('配音文件 ID 已存在');
      }
      await temporary.rename(destination.path);
      return relativePath;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<void> deleteRelativeFile(String relativePath) async {
    final file = File(resolveRelativePath(relativePath));
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteProject({
    required String libraryId,
    required String projectId,
  }) async {
    final directory = _projectDirectory(libraryId, projectId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Directory _projectDirectory(String libraryId, String projectId) {
    _requireSegment(libraryId, 'libraryId');
    _requireSegment(projectId, 'projectId');
    return Directory(
        p.join(_documentsDirectory.path, _rootName, libraryId, projectId));
  }
}

void _requireSegment(String? value, String name) {
  if (value == null ||
      value.isEmpty ||
      value.contains('/') ||
      value.contains('\\') ||
      value == '.' ||
      value == '..') {
    throw ArgumentError.value(value, name, '必须是非空路径片段');
  }
}
