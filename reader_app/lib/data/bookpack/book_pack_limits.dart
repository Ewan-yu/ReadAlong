import 'dart:typed_data';

/// Resource limits applied before [ZipDecoder] expands an imported package.
///
/// The reader still receives a byte buffer from the platform picker, but the
/// central-directory preflight prevents a malformed archive from asking the
/// ZIP decoder to allocate an unbounded number of entries or inflated bytes.
abstract final class BookPackLimits {
  static const maxCompressedBytes = 512 * 1024 * 1024;
  static const maxUncompressedBytes = 1024 * 1024 * 1024;
  static const maxEntryCount = 10 * 1000;
  static const maxEntryUncompressedBytes = 512 * 1024 * 1024;

  static List<String> validateZipBytes(Uint8List bytes) {
    if (bytes.length > maxCompressedBytes) {
      return [
        '资源包压缩后大小超过 ${maxCompressedBytes ~/ (1024 * 1024)} MB 上限',
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
    if (entryCount > maxEntryCount) {
      return ['资源包条目数超过 $maxEntryCount 上限'];
    }
    if (centralDirectoryOffset > bytes.length ||
        centralDirectorySize > bytes.length - centralDirectoryOffset) {
      return const ['ZIP 中央目录越界'];
    }

    final errors = <String>[];
    var cursor = centralDirectoryOffset;
    var totalUncompressed = 0;
    for (var index = 0; index < entryCount; index++) {
      if (cursor > bytes.length - 46 || _u32(bytes, cursor) != 0x02014b50) {
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
        if (uncompressed > maxEntryUncompressedBytes) {
          errors.add(
              '资源包单个文件解压后超过 ${maxEntryUncompressedBytes ~/ (1024 * 1024)} MB');
        }
        if (totalUncompressed > maxUncompressedBytes - uncompressed) {
          errors.add(
            '资源包解压后总大小超过 ${maxUncompressedBytes ~/ (1024 * 1024)} MB 上限',
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
    final start = (bytes.length - 22 - 0xffff).clamp(0, bytes.length);
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
