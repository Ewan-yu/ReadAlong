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

### 2026-07-22：可选原音资源（向后兼容 minor）

- `manifest.json` 新增可选 `original_audio` 对象；既有必填键和 `schema_version=1` 不变。
- M5.1 声明 `original/source.mp3` 的 MIME、字节数、SHA-256、时长和 `alignment_status=raw`。
- 旧阅读端可忽略该字段与额外资源；支持原音的阅读端在字段存在时必须验证声明文件、大小和哈希。
- 原音仍为只读包资源；运行时录音和未来配音 Take 不写入资源包。

### 2026-07-23：可选原音逐词时间线（向后兼容 minor）

- 已确认分离且全书对齐通过时，`original_audio.alignment_status` 可为 `ready`，并声明 `timeline/original_timeline.json`、时间线哈希、句数和人声轨哈希；未就绪仍为 `raw`。
- 时间线以毫秒整数存储完整原音的绝对句/词时间，必须与原音哈希、`alignment.db` 中的句子 ID、页码、顺序和校对文本一致。
- 阅读端在导入和读取时校验资源哈希、时间范围和身份关系；任何缺失或不匹配均不开放原音欣赏入口。
