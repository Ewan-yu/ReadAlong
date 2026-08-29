import 'dart:typed_data';

/// Resource limits applied before archive contents are inflated or installed.
///
/// The parent tool currently accepts up to 500 MiB source audio, so the
/// compressed package limit stays aligned with that product boundary. The
/// uncompressed and entry limits additionally protect devices from ZIP bombs
/// and metadata-only archives with excessive file counts.
final class BookPackLimits {
  static const defaultMaxPackageBytes = 500 * 1024 * 1024;

  const BookPackLimits({
    this.maxPackageBytes = defaultMaxPackageBytes,
    this.maxArchiveEntries = 4096,
    this.maxSingleEntryBytes = 512 * 1024 * 1024,
    this.maxUncompressedBytes = 1024 * 1024 * 1024,
  });

  final int maxPackageBytes;
  final int maxArchiveEntries;
  final int maxSingleEntryBytes;
  final int maxUncompressedBytes;

  /// Checks ZIP metadata without asking the decoder to inflate entries.
  static List<String> validateZipBytes(
    Uint8List bytes, {
    BookPackLimits limits = const BookPackLimits(),
  }) {
    if (bytes.length > limits.maxPackageBytes) {
      return [
        '资源包过大: ${bytes.length} 字节（上限 ${limits.maxPackageBytes}）',
      ];
    }

    final endOfCentralDirectory = _findEndOfCentralDirectory(bytes);
    if (endOfCentralDirectory < 0) return const ['ZIP 缺少中央目录'];

    final entryCount = _u16(bytes, endOfCentralDirectory + 10);
    final diskNumber = _u16(bytes, endOfCentralDirectory + 4);
    final centralDirectoryDisk = _u16(bytes, endOfCentralDirectory + 6);
    final entriesOnDisk = _u16(bytes, endOfCentralDirectory + 8);
    final centralDirectorySize = _u32(bytes, endOfCentralDirectory + 12);
    final centralDirectoryOffset = _u32(bytes, endOfCentralDirectory + 16);
    if (diskNumber != 0 ||
        centralDirectoryDisk != 0 ||
        entriesOnDisk != entryCount) {
      return const ['不支持多磁盘 ZIP 资源包'];
    }
    if (entryCount == 0xffff ||
        centralDirectorySize == 0xffffffff ||
        centralDirectoryOffset == 0xffffffff) {
      return const ['暂不支持 ZIP64 资源包'];
    }
    if (entryCount > limits.maxArchiveEntries) {
      return ['资源包条目过多: $entryCount（上限 ${limits.maxArchiveEntries}）'];
    }
    if (centralDirectoryOffset > bytes.length ||
        centralDirectorySize > bytes.length - centralDirectoryOffset) {
      return const ['ZIP 中央目录越界'];
    }

    final errors = <String>[];
    var cursor = centralDirectoryOffset;
    var totalUncompressed = 0;
    for (var index = 0; index < entryCount; index++) {
      if (cursor > bytes.length - 46 ||
          _u32(bytes, cursor) != 0x02014b50) {
        return ['ZIP 中央目录条目 $index 损坏'];
      }
      final flags = _u16(bytes, cursor + 8);
      final compressed = _u32(bytes, cursor + 20);
      final uncompressed = _u32(bytes, cursor + 24);
      final nameLength = _u16(bytes, cursor + 28);
      final extraLength = _u16(bytes, cursor + 30);
      final commentLength = _u16(bytes, cursor + 32);
      final entryLength = 46 + nameLength + extraLength + commentLength;
      if (entryLength > bytes.length - cursor) {
        return ['ZIP 中央目录条目 $index 越界'];
      }
      if ((flags & 0x0001) != 0) errors.add('资源包不支持加密 ZIP 条目');
      if (compressed == 0xffffffff || uncompressed == 0xffffffff) {
        errors.add('资源包包含未限制大小的 ZIP64 条目');
      } else {
        if (uncompressed > limits.maxSingleEntryBytes) {
          errors.add(
            '资源包单文件过大: $uncompressed 字节（上限 ${limits.maxSingleEntryBytes}）',
          );
        }
        if (totalUncompressed >
            limits.maxUncompressedBytes - uncompressed) {
          errors.add(
            '资源包解压后过大（上限 ${limits.maxUncompressedBytes} 字节）',
          );
        } else {
          totalUncompressed += uncompressed;
        }
      }
      cursor += entryLength;
    }
    return List.unmodifiable(errors);
  }

  static int _findEndOfCentralDirectory(Uint8List bytes) {
    if (bytes.length < 22) return -1;
    final start =
        bytes.length > 22 + 0xffff ? bytes.length - 22 - 0xffff : 0;
    for (var offset = bytes.length - 22; offset >= start; offset--) {
      if (_u32(bytes, offset) == 0x06054b50) {
        final commentLength = _u16(bytes, offset + 20);
        if (offset + 22 + commentLength <= bytes.length) return offset;
      }
    }
    return -1;
  }

  static int _u16(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32(Uint8List bytes, int offset) =>
      _u16(bytes, offset) | (_u16(bytes, offset + 2) << 16);
}
