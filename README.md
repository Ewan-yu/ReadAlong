# ReadAlong 跟读宝

把扫描版英文绘本 PDF 转成可点读、跟读、录音、配音的儿童英语学习资源。

**双端架构**：家长端（Windows + GPU，加工）→ 资源包（`.readalongbook`）→ 阅读端（Android 平板，消费）。

## 目录

| 目录 | 说明 |
|---|---|
| `docs/` | 方案与设计文档（先读 `docs/ReadAlong-产品与技术方案.md`） |
| `parent_tool/` | 家长端：Python + FastAPI，PDF→OCR→校对→TTS→打包流水线 |
| `reader_app/` | 阅读端：Flutter，书架/点读/跟读评分 |
| `shared/schema/` | 跨端契约单一事实来源（manifest schema + alignment.sql） |
| `poc/` | 已完成的技术验证脚本（只读参考，不复用为正式代码） |

## 工程文档

- `docs/architecture.md` — 框架设计（读代码前必读）
- `docs/functional-design.md` — 功能详细设计
- `docs/development-plan.md` — 里程碑计划（M0–M5）
- `docs/design.md` — UI 设计规范（色板/组件/布局）

## 开发环境

- 家长端：conda `readalong` 环境（Python 3.11 + CUDA，配置见 `poc/README.md`）
- 阅读端：Flutter stable ≥3.22

## 密钥安全

- 讯飞等 API key **禁止入库**：家长端走环境变量/本地配置，阅读端走 `flutter_secure_storage`
- `.gitignore` 已覆盖 `ise_config.json`、`.env` 等
