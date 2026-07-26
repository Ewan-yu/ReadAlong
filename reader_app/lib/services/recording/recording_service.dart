import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';

import '../../data/appdb/app_database_providers.dart';

final class RecordingLevel {
  const RecordingLevel(this.value);

  /// Normalized microphone level in the inclusive 0–1 range.
  final double value;
}

final class RecordingSession {
  const RecordingSession({required this.path, required this.levels});

  final String path;
  final Stream<RecordingLevel> levels;
}

final class RecordingException implements Exception {
  const RecordingException(this.message);

  final String message;

  @override
  String toString() => 'RecordingException: $message';
}

/// Isolates microphone permission, WAV settings and private file storage from
/// follow-reading state/UI. Tests replace this interface with a fake recorder.
abstract interface class AudioRecordingService {
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  });

  Future<String> stop();
  Future<void> cancel();
  Future<void> dispose();
}

final recordingServiceProvider =
    FutureProvider.autoDispose<AudioRecordingService>((ref) async {
  final temporary = await ref.watch(appTemporaryDirectoryProvider.future);
  final documents = await ref.watch(appDocumentsDirectoryProvider.future);
  final service = RecordAudioRecordingService(temporaryDirectory: temporary);
  await service.purgeStaleRecordings();
  await purgeLegacyFollowRecordings(documents);
  try {
    final index = await ref.watch(shelfIndexProvider.future);
    await index.deleteAllReadingRecords();
  } on Object {
    // Legacy metadata cleanup must not make the microphone unavailable.
  }
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final class RecordAudioRecordingService implements AudioRecordingService {
  RecordAudioRecordingService({
    required Directory temporaryDirectory,
    AudioRecorder? recorder,
  })  : _temporaryDirectory = temporaryDirectory,
        _recorder = recorder ?? AudioRecorder();

  final Directory _temporaryDirectory;
  final AudioRecorder _recorder;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamController<RecordingLevel>? _levelController;
  String? _activePath;
  Future<String>? _stopOperation;
  var _disposed = false;

  @override
  Future<RecordingSession> start({
    required String libraryId,
    required String sentenceId,
  }) async {
    if (_disposed) throw const RecordingException('录音服务已关闭');
    if (libraryId.isEmpty || sentenceId.isEmpty) {
      throw const RecordingException('当前句子无法录音');
    }
    if (await _recorder.isRecording()) {
      throw const RecordingException('录音正在进行中');
    }
    if (!await _recorder.hasPermission()) {
      throw const RecordingException('请允许麦克风权限后再开始录音');
    }

    final folder = Directory(p.join(
      _temporaryDirectory.path,
      'readalong-follow-recordings',
      _safeSegment(libraryId),
    ));
    await folder.create(recursive: true);
    final filename = '${_safeSegment(sentenceId)}_'
        '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.wav';
    final path = p.join(folder.path, filename);
    final levels = StreamController<RecordingLevel>.broadcast();
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: path,
      );
      _activePath = path;
      _levelController = levels;
      _amplitudeSubscription = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 200))
          .listen((amplitude) {
        if (!levels.isClosed) {
          // -60dBFS is close to silence for a child-facing meter.
          final value = ((amplitude.current + 60) / 60).clamp(0.0, 1.0);
          levels.add(RecordingLevel(value));
        }
      });
      return RecordingSession(path: path, levels: levels.stream);
    } on RecordingException {
      await _cleanupActiveRecording(deleteFile: true);
      rethrow;
    } on Object {
      await _cleanupActiveRecording(deleteFile: true);
      throw const RecordingException('录音没有开始，请稍后重试');
    }
  }

  @override
  Future<String> stop() {
    final activeOperation = _stopOperation;
    if (activeOperation != null) return activeOperation;
    late final Future<String> operation;
    operation = _stopInternal().whenComplete(() {
      if (identical(_stopOperation, operation)) _stopOperation = null;
    });
    _stopOperation = operation;
    return operation;
  }

  Future<String> _stopInternal() async {
    if (_disposed) throw const RecordingException('录音服务已关闭');
    try {
      final path = await _recorder.stop();
      final result = path ?? _activePath;
      await _closeLevelStream();
      _activePath = null;
      if (result == null || !await File(result).exists()) {
        throw const RecordingException('录音没有保存成功，请再试一次');
      }
      return result;
    } on RecordingException {
      rethrow;
    } on Object {
      await _closeLevelStream();
      _activePath = null;
      throw const RecordingException('录音没有保存成功，请再试一次');
    }
  }

  @override
  Future<void> cancel() => _cleanupActiveRecording(deleteFile: true);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _cleanupActiveRecording(deleteFile: true);
    await _recorder.dispose();
  }

  /// Removes takes left behind when Android terminated the previous process.
  /// This directory is reserved for disposable follow-reading practice only.
  Future<void> purgeStaleRecordings() =>
      purgeStaleFollowRecordings(_temporaryDirectory);

  Future<void> _cleanupActiveRecording({required bool deleteFile}) async {
    final activePath = _activePath;
    _activePath = null;
    try {
      await _recorder.cancel();
    } on Object {
      // The session may already have stopped; local cleanup is still useful.
    }
    await _closeLevelStream();
    if (deleteFile && activePath != null) {
      try {
        await File(activePath).delete();
      } on Object {
        // A partially-created file is harmless and will be overwritten only by
        // a nonce filename; never turn a cancelled recording into a UI error.
      }
    }
  }

  Future<void> _closeLevelStream() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _levelController?.close();
    _levelController = null;
  }
}

/// M4 originally stored follow-reading WAV files in Documents/records. Remove
/// that legacy folder after an upgrade; future durable dubbing audio must use a
/// separate directory and therefore is not affected by this migration.
Future<void> purgeLegacyFollowRecordings(Directory documentsDirectory) =>
    _deleteDirectoryIfExists(
        Directory(p.join(documentsDirectory.path, 'records')));

Future<void> purgeStaleFollowRecordings(Directory temporaryDirectory) =>
    _deleteDirectoryIfExists(
      Directory(
        p.join(temporaryDirectory.path, 'readalong-follow-recordings'),
      ),
    );

Future<void> _deleteDirectoryIfExists(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on Object {
    // Cache cleanup is best-effort and must never disable microphone access.
  }
}

String _safeSegment(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

final class WavPcmData {
  const WavPcmData({
    required this.pcm16k,
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
  });

  final Uint8List pcm16k;
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
}

/// Extracts the raw PCM section required by Xfyun ISE from a standard WAV.
/// The recorder always requests 16kHz/16bit/mono; validating it here prevents
/// a malformed platform response from being sent to the scoring service.
WavPcmData parseWavPcm16(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const RecordingException('录音格式不正确，请重新录一次');
  }
  final view = ByteData.sublistView(bytes);
  var offset = 12;
  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  Uint8List? pcm;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final length = view.getUint32(offset + 4, Endian.little);
    final dataOffset = offset + 8;
    if (dataOffset + length > bytes.length) break;
    if (id == 'fmt ' && length >= 16) {
      final format = view.getUint16(dataOffset, Endian.little);
      if (format != 1) {
        throw const RecordingException('录音不是 PCM 格式，请重新录一次');
      }
      channels = view.getUint16(dataOffset + 2, Endian.little);
      sampleRate = view.getUint32(dataOffset + 4, Endian.little);
      bitsPerSample = view.getUint16(dataOffset + 14, Endian.little);
    } else if (id == 'data') {
      pcm = Uint8List.sublistView(bytes, dataOffset, dataOffset + length);
    }
    offset = dataOffset + length + (length.isOdd ? 1 : 0);
  }
  if (sampleRate != 16000 ||
      channels != 1 ||
      bitsPerSample != 16 ||
      pcm == null) {
    throw const RecordingException('录音格式不正确，请重新录一次');
  }
  return WavPcmData(
    pcm16k: pcm,
    sampleRate: sampleRate!,
    channels: channels!,
    bitsPerSample: bitsPerSample!,
  );
}

/// Returns PCM starting at the child-visible content zero. The lead-in remains
/// in the WAV for recovery and diagnostics but never dilutes speech scoring.
Uint8List pcm16SliceFromOffset(Uint8List pcm, Duration contentOffset) {
  if (contentOffset <= Duration.zero) return pcm;
  const bytesPerMillisecond = 32; // 16 kHz × 16-bit mono.
  final offset = (contentOffset.inMilliseconds * bytesPerMillisecond)
      .clamp(0, pcm.length)
      .toInt();
  if (offset >= pcm.length) return Uint8List(0);
  return Uint8List.sublistView(pcm, offset);
}
