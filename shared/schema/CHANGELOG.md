# shared/schema CHANGELOG

跨端契约（资源包格式）变更记录。规则见 `docs/architecture.md §5.2`：
- 加字段（向后兼容）= minor 记录，不 bump `schema_version`
- 改语义 / 删字段 / 改必填 = bump `schema_version`
- 阅读端声明支持的 `schema_version` 集合，不支持则拒绝导入

## schema_version = 1（2026-07-08）

初始版本。

- `manifest.schema.json`：资源包入口文件结构（book_id / pages / page_image / thumbnail / source 映射）
- `alignment.sql`：book / page / sentence / word_timing 四表
  - `sentence.bbox_json` 为归一化坐标（0~1）
  - `sentence.shared_bbox` 标记块级共享 bbox（命中连播）
  - `word_timing` 可缺失（词序一致性校验失败的句子降级整句字幕）
- 阅读端 `record` 表**不在**资源包内（App 私有库，见 functional-design B4）
