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

  /// alignment.db 必须存在的表（与 alignment.sql 一致）
  static const alignmentTables = {'book', 'page', 'sentence', 'word_timing'};

  /// 资源包内必需的顶层条目
  static const requiredEntries = {
    'manifest.json',
    'align/alignment.db',
  };

  /// book_id 规则（与 manifest.schema.json pattern 一致）
  static final bookIdPattern = RegExp(r'^[a-z0-9][a-z0-9-]{2,63}$');
}
