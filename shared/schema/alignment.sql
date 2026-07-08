-- ReadAlong alignment.db 建表 SQL
-- schema_version = 1
-- 家长端（步骤⑤打包）负责创建与写入；阅读端只读。
-- 变更规则：任何修改必须同步 bump manifest 的 schema_version 并记录 CHANGELOG.md。

CREATE TABLE book (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  language TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE page (
  id INTEGER PRIMARY KEY,
  book_id TEXT NOT NULL,
  page_no INTEGER NOT NULL,
  image_path TEXT NOT NULL,
  thumbnail_path TEXT NOT NULL,
  width_px INTEGER NOT NULL,
  height_px INTEGER NOT NULL,
  source_pdf_page INTEGER,
  source_region TEXT NOT NULL,
  FOREIGN KEY (book_id) REFERENCES book(id)
);

CREATE TABLE sentence (
  id TEXT PRIMARY KEY,          -- 's' + 4位序号，书内唯一
  book_id TEXT NOT NULL,
  page_no INTEGER NOT NULL,
  seq INTEGER NOT NULL,         -- 全书阅读顺序
  text TEXT NOT NULL,
  bbox_json TEXT NOT NULL,      -- 归一化 {"x","y","w","h"}，0~1，x+w<=1，y+h<=1
  shared_bbox INTEGER NOT NULL DEFAULT 0,  -- 1=与同块其他句共享 bbox（命中连播）
  audio_path TEXT NOT NULL,     -- 包内相对路径 tts/s0001.ogg
  t_start REAL NOT NULL DEFAULT 0,
  t_end REAL NOT NULL,          -- 转码后真实时长
  audio_source TEXT NOT NULL,   -- 'tts' | 'azure-tts' | 'original'(二期)
  FOREIGN KEY (book_id) REFERENCES book(id)
);

CREATE TABLE word_timing (
  id TEXT PRIMARY KEY,
  sentence_id TEXT NOT NULL,
  seq INTEGER NOT NULL,         -- 词在句内顺序
  word TEXT NOT NULL,
  t_start REAL NOT NULL,
  t_end REAL NOT NULL,
  FOREIGN KEY (sentence_id) REFERENCES sentence(id)
);

-- 查询索引（阅读端热路径：按页取句、按句取词）
CREATE INDEX idx_page_book_no ON page(book_id, page_no);
CREATE INDEX idx_sentence_page ON sentence(book_id, page_no, seq);
CREATE INDEX idx_word_sentence ON word_timing(sentence_id, seq);
