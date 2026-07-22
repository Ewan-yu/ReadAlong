/// 跨端契约镜像常量 — 与 `shared/schema/` 保持同步。
/// ⚠️ 修改 shared/schema 后必须同步此文件；`test/schema_mirror_test.dart`
/// 会与 schema 文件逐项比对防漂移。
abstract final class BookPackSchema {
  /// 阅读端支持的 schema_version 集合（不支持 → 拒绝导入并提示升级 App）
  static const supportedSchemaVersions = {1};

  /// manifest.json 必填字段（与 manifest.schema.json required 一致）
  static const manifestRequiredKeys = {
    'schema_version',
    'book_id',
    'title',
    'language',
    'created_at',
    'generator',
    'page_count',
    'page_image',
    'thumbnail',
    'pages',
  };

  /// manifest.original_audio 存在时的必填字段。
  static const originalAudioRequiredKeys = {
    'path',
    'mime_type',
    'size_bytes',
    'sha256',
    'duration_ms',
    'alignment_status',
  };

  static const originalAudioPath = 'original/source.mp3';
  static const originalAudioMimeType = 'audio/mpeg';
  static const originalAudioRawStatus = 'raw';

  /// alignment.db 必须存在的表（与 alignment.sql 一致）
  static const alignmentTables = {'book', 'page', 'sentence', 'word_timing'};

  /// 资源包内必需的顶层条目
  static const requiredEntries = {
    'manifest.json',
    'align/alignment.db',
  };

  /// book_id 规则（与 manifest.schema.json pattern 一致）
  static final bookIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{2,63}$');
  static final sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
}
