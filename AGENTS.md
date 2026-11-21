# ReadAlong 跟读宝 — Agent 工作说明

扫描版英文绘本 PDF → 可点读/跟读/录音/配音的儿童英语学习资源。双端架构:家长端(Windows+GPU 加工)→ `.readalongbook` 资源包 → 阅读端(Android 平板消费)。

## 目录与事实源

- `parent_tool/app/` — FastAPI 流水线(api/pipeline/jobs/providers/services);`parent_tool/web/` — React 19 + TS + Vite 前端(pnpm)
- `reader_app/` — Flutter 阅读端(Riverpod),仅部署 Android,但仓储/纯函数保持 Windows 兼容边界
- `shared/schema/` — 跨端契约**单一事实源**(manifest schema、alignment.sql、original_timeline schema)
- `poc/` — 已完成技术验证脚本,**只读参考,禁止复用为正式代码**
- `docs/PROGRESS.md` — 进度与验证证据的事实源;改代码前先读 `docs/architecture.md`
- `output/` — 本地 QA 截图/dump,不入库

## 常用命令

家长端后端(conda 环境 `readalong`,Windows GBK 终端必须 `python -X utf8`):

```bash
conda run -n readalong python -X utf8 -m pytest parent_tool/tests
conda run -n readalong python -X utf8 -m ruff check parent_tool
# 启动服务(端口 8760):在 parent_tool/ 下 python -m app.main;详见 docs/家长端服务启动指南.md
```

家长端前端(`parent_tool/web/`):`pnpm lint`(即 tsc)、`pnpm test`(vitest)、`pnpm build`;`pnpm generate:api` 需先启动后端。pnpm 不可用时走 corepack。

阅读端(`reader_app/`,Flutter 3.24.5 在 `C:\tools\flutter`):

```bash
flutter analyze
flutter test --no-pub --concurrency=1   # 必须串行,并发会不稳定
dart format --set-exit-if-changed lib test
flutter build apk --debug --no-pub
```

夹具再生:`conda run -n readalong python -X utf8 shared/fixtures/make_fixture_book.py`(需 `PYTHONIOENCODING=utf-8`,否则 emoji 输出在 GBK 终端崩溃)。

提交前基线:家长端 pytest 全绿(~132)+ ruff;阅读端 analyze 0 问题 + 串行全量测试(~250)全绿。

## 关键架构红线

- **契约变更**:`shared/schema/` 任何改动必须同步 `shared/schema/CHANGELOG.md` 和阅读端 Dart 镜像常量;资源包两端各自校验。
- **家长端流水线**:产物走不可变 revision(暂存目录 → 哈希校验 → 原子发布),禁止原地改写成功产物;Windows 上不覆盖非空正式目录。GPU Provider(VoxCPM/stable-ts/PaddleOCR/Demucs)延迟加载且不在基础依赖中;Demucs 权重缺失时禁止自动海外下载。
- **音频安全边界**:完整原音 `original/source.mp3` 只用于欣赏,**禁止**参与儿童配音混音;混音背景必须是家长已确认的 `original/background.ogg`,否则产出并标注"纯人声作品";原音播放走兼容轨 `original/playback.ogg`。
- **阅读端数据**:`app.db` 版本化迁移(当前 v6),迁移必须向后兼容;`alignment.db` 只读;Android sqflite 按路径复用单实例句柄——需要独占的读取请用非单例连接,避免共享句柄被提前关闭(历史竞态来源)。
- `record_android` 经 `dependency_overrides` 锁定 1.2.6(receiver 幂等注销),非必要不升级。

## 环境陷阱

- 国内镜像:`PUB_HOSTED_URL=https://pub.flutter-io.cn`、`FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`;依赖已缓存时用 `flutter pub get --offline`,**不要删除全局缓存**(Flutter 3.24/Pub 3.5 解析镜像 advisories 空字段会异常)。
- `adb` 不在 PATH:`C:\Users\kense\AppData\Local\Android\Sdk\platform-tools\adb.exe`。
- 密钥安全:讯飞/Azure/Paddle key 只走环境变量,**禁止写入任何文件**(gitignore 已覆盖 `ise_config.json`、`.env`)。
- 真机数据根在 `F:\ReadAlongData`(不在仓库内)。

## 改动前必读

- 任何进度/结论冲突:以 `docs/PROGRESS.md` 当前结论为准
- 家长端流水线/导出:`docs/m2.5-export-design.md`、`docs/m5-original-audio-dubbing-design.md`
- 阅读端录音/配音:`docs/m5-reader-recording-ux-followup.md`
- schema 契约:`shared/schema/CHANGELOG.md`
