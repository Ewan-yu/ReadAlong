# VoxCPM 排雷验证（PoC）

> ✅ **PoC-A 已通过**（2026-07-05 实测于 RTX 4070）
> 这是**验证脚本**，不是正式项目代码。目的：确认 VoxCPM2 能否作为 ReadAlong 的 TTS 主力方案。

## 一、实测结果

| 验证项 | 结果 | 数据 |
|---|---|---|
| 环境 | ✅ | RTX 4070 / 12GB / CUDA 可用 |
| 基础 TTS | ✅ | 英文音质**人工评分 9+ 分** |
| 显存 | ✅ | 峰值 **5.33 GB**（4070 余量充足） |
| 速度 RTF | ✅ | 2.55（预生成场景完全可接受） |
| 声音克隆 | ✅ | API 通，相似度可接受 |
| 词级时间戳 | ✅ | stable-ts 词级对齐成功 |
| 模型加载 | ✅ | 首次 205s，缓存后 42s |

**结论：VoxCPM 可作为本项目 TTS 主力。** 最大不确定性排除，方案文档 §10 该项由 🔬待验证 → ✅已通过。

---

## 二、环境配置（实测步骤）

### ⚠️ 关键前提：Python 必须 <3.13（VoxCPM 要求 ≥3.10 且 <3.13）

### 1. 用 conda 建 Python 3.11 环境（不影响系统 Python）
```bash
conda create -n readalong python=3.11 -y
```

### 2. 装 PyTorch（CUDA 12.4 版，实测装到 2.6.0+cu124）
```bash
conda run -n readalong pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu124
```

### 3. 装 VoxCPM + stable-ts + soundfile
```bash
conda run -n readalong pip install -i https://pypi.tuna.tsinghua.edu.cn/simple voxcpm soundfile stable-ts
```
> ⚠️ **坑**：`voxcpm[timestamps]` 在 2.0.3 里**没带** stable-ts，必须单独 `pip install stable-ts`。

### 4. 装 ffmpeg（stable-ts 解码音频要用）
```bash
conda install -n readalong -c conda-forge ffmpeg -y
```
> ⚠️ **坑**：stable-ts 通过 PATH 找 ffmpeg；脚本已在内部把 `envs/readalong/Library/bin` 加入 PATH，无需手动设。

### 5. 下载模型（用 ModelScope，国内快，约 5GB，实测 5 分 20 秒）
```bash
conda run -n readalong pip install modelscope
conda run -n readalong python -c "from modelscope import snapshot_download; snapshot_download('OpenBMB/VoxCPM2', local_dir='F:/Source/ReadAlong/pretrained_models/VoxCPM2')"
```

---

## 三、运行验证脚本

```bash
# ⚠️ 用 conda 环境的 python 直接跑（避开 conda run 的中文编码坑）
HF_ENDPOINT=https://hf-mirror.com PYTHONUTF8=1 PYTHONIOENCODING=utf-8 \
  "D:/Program Files/Anaconda3/envs/readalong/python.exe" \
  F:/Source/ReadAlong/poc/voxcpm_poc.py \
  --model-path F:/Source/ReadAlong/pretrained_models/VoxCPM2
```
> ⚠️ **坑**：中文 Windows 下 `conda run` 捕获子进程输出会按 GBK 解码而崩（UnicodeEncodeError），**直接用环境 `python.exe` 绝对路径**绕开。
> `HF_ENDPOINT` 用于加速 whisper-tiny 下载（词级时间戳那步）。

---

## 四、产出（`poc/out/`，已被 .gitignore 忽略）

| 文件 | 用途 |
|---|---|
| `01_basic.wav` | 基础英文合成 → 听音质 |
| `00_ref.wav` | Voice Design 生成的伪参考音 |
| `02_clone.wav` | 克隆音色合成 → 对比参考音听相似度 |
| `04_timestamps.json` | 词级时间戳（stable-ts） |

---

## 五、踩坑速查（⭐ 正式开发务必参考）

| # | 坑 | 现象 | 解决 |
|---|---|---|---|
| 1 | Python 3.13 太新 | VoxCPM 装不上 / 报版本不符 | conda 建 **3.11** 环境 |
| 2 | `generate()` 无 `seed` | `unexpected keyword argument 'seed'` | 去掉 seed（**2.0.3 API 与 GitHub README 有出入**） |
| 3 | `voxcpm[timestamps]` 没带 stable-ts | `No module named 'stable_whisper'` | 单独 `pip install stable-ts` |
| 4 | stable-ts 找不到 ffmpeg | `FileNotFoundError: [WinError 2]` | `conda install ffmpeg` + 脚本内设 PATH |
| 5 | `conda run` 中文编码崩 | `UnicodeEncodeError: 'gbk'` | 用环境 `python.exe` 绝对路径 |
| 6 | whisper 模型下载慢 | 卡在 HF 下载 | 设 `HF_ENDPOINT=https://hf-mirror.com` |
| 7 | 模型权重走 HF 慢 | VoxCPM2 下载慢/失败 | 用 **ModelScope** `snapshot_download` |

> 这些坑**都已在本 PoC 中解决**，正式开发按上面配置即可一次跑通。

## 六、关于 RTF=2.55（"慢于实时"）的说明

标准 PyTorch 推理 RTF 约 2.55（生成 4 秒音频耗时 10 秒）。**本项目的 TTS 是预生成**（家长导入时一次性生成，孩子端播本地文件），所以慢一点完全可接受：一本绘本几十句，十几分钟生成完，孩子用零延迟。若将来要实时/更快，README（上游）提到 Nano-vLLM 可把 RTF 压到 0.13（非必需）。

---

## 七、OCR 验证（PoC-C：PaddleOCR-VL-1.6）

> ✅ **PoC-C 已完成**（2026-07-05）
> 目的：验证 `PaddleOCR-VL-1.6` 当前是否可调用，以及它返回的结构是否适合 ReadAlong 的点读场景。

### 实测结论

| 验证项 | 结果 | 说明 |
|---|---|---|
| API 可用性 | ✅ | 真实 PDF 已成功提交、轮询、取回 JSONL |
| 返回结构 | ✅ | 以 `layoutParsingResults` 为主，支持 Markdown + 图像块 + 布局块坐标 |
| 坐标能力 | ✅ | 坐标存在于 `prunedResult.parsing_res_list[*].block_bbox` / `block_polygon_points` |
| 粒度 | ⚠️ 偏粗 | 更像**版面块/段落块**，不是 `PP-OCRv6` 的细粒度 `dt_polys` 行坐标 |
| 点读适配 | ⚠️ 有条件可用 | 句级/段级页面可用，词级/karaoke/精细点击仍不够稳 |

### 关键发现

1. `PaddleOCR-VL-1.6` 现在**确实能调通**；早先观察到的 401 在本轮未复现，但原因尚未归因，不能直接判定为限流。
2. 返回不是 `PP-OCRv6` 风格的 `rec_texts + dt_polys`，而是：
   - `layoutParsingResults[*].prunedResult.parsing_res_list[*].block_content`
   - `layoutParsingResults[*].prunedResult.parsing_res_list[*].block_bbox`
   - `layoutParsingResults[*].prunedResult.parsing_res_list[*].block_polygon_points`
   - `markdown.text`
3. JSONL 不是“一行一页”，而是**一行一个 batch**。本次样本：
   - JSONL 记录数：5
   - 展开后的 PDF 页数：20
   - 即平均每条记录包含 4 个 `layoutParsingResults`
4. 对故事正文页，`VL-1.6` 能给出类似：
   - `My Granny talks a lot.`
   - `My Granny cleans a lot.`
   - `My Granny shops a lot.`
   这些句子的 **block bbox**
5. 但它的识别目标是“版面理解”，所以会混入：
   - 页码
   - 页脚/版权信息
   - 图片词典说明
   - Markdown 中的 `<img>` 片段

### API 稳定性待复测

- 曾观察到短时间多次调用后出现 401，但“几分钟 8 次”不应直接视为高频调用。
- 目前只能记录为“疑似限流 / 认证态异常 / 服务端临时异常”，不能写成已验证的免费 API 限流。
- 工程上仍应保留限速与指数退避：提交请求建议 ≤2/s，对 401/429/5xx 重试，并记录响应体。
- 后续需要单独做阶梯压测，确认稳定 QPS、日额度、并发限制和 401/429 的真实触发条件。

### 对 ReadAlong 的判断（单模型结论）

- 如果目标是 **MVP 句级点读 / 段级点读**：
  `VL-1.6` 已经不只是“可用潜力”，而是当前更合理的**单模型首选**。它更贴近绘本场景，正文噪声更少，还能顺带做图文分离。
- 如果目标是 **词级点读 / karaoke 高亮 / 更细的文本框**：
  仍应保留 `PP-OCRv6` 或其他细粒度 OCR 方案，因为 `VL-1.6` 的返回更偏块级，不够稳定精细。
- 当前最合理路线是：
  - `VL-1.6`：MVP 主 OCR，负责句级点击块、图文分离、版面理解
  - `PP-OCRv6`：低层兜底，负责细粒度文字框和后续精细点读补偿

### 产出文件

本次验证新增：

| 文件 | 用途 |
|---|---|
| `poc/ocr_vl_validate.py` | `VL-1.6` 提交/轮询/结构分析脚本 |
| `poc/out/ocr_vl_*_job.json` | 任务元数据 |
| `poc/out/ocr_vl_*.jsonl` | 原始 OCR 结果 |
| `poc/out/ocr_vl_*_summary.json` | 展开后的页面摘要（推荐直接看这个） |

### 运行方式

```bash
# 真实请求
python F:/Source/ReadAlong/poc/ocr_vl_validate.py --token <PADDLE_TOKEN>

# 不重复请求，直接重解析最近一次 JSONL
python F:/Source/ReadAlong/poc/ocr_vl_validate.py --jsonl latest
```

---

## 八、OCR 双模型对比（PoC-D：PP-OCRv6 vs PaddleOCR-VL-1.6）

> ✅ **PoC-D 已完成**（2026-07-05）
> 目的：在同一本绘本、同一批正文页上，直接比较两个 OCR 模型哪个更适合 ReadAlong。

### 对比方法

- 样本：同一本绘本的 6 个正文页
- 目标句：
  - `My Granny talks a lot.`
  - `My Granny cleans a lot.`
  - `My Granny knits a lot.`
  - `My Granny shops a lot.`
  - `My Granny cooks a lot.`
  - `I love my Granny a lot.`
- 评分维度：
  - 是否命中目标句
  - 目标句是否带 bbox
  - 噪声文本多少
  - 是否天然支持绘本图文分离

### 实测结果

| 模型 | 命中目标页 | 命中且带 bbox | 噪声文本 | 特点 |
|---|---:|---:|---:|---|
| `PP-OCRv6` | 6/6 | 6/6 | 5 | 细粒度文本框 |
| `PaddleOCR-VL-1.6` | 6/6 | 6/6 | 1 | 图文分离 / 版面块 |

### 结论

- 两个模型在本批正文页上都**足够识别出目标句并给出坐标**
- `VL-1.6` 的优势是：
  - 正文页噪声更少
  - 自带块类型，天然适合绘本图文混排
  - 更适合“句级点读”这种产品场景
- `PP-OCRv6` 的优势是：
  - 更像低层 OCR
  - 如果以后要做词级点击、精细框修正、低层规则控制，它更适合兜底

### 最终建议

- **MVP 单模型首选：`PaddleOCR-VL-1.6`**
- **句级点读主 OCR：`PaddleOCR-VL-1.6`**
- **低层兜底：`PP-OCRv6`**

### 产出文件

| 文件 | 用途 |
|---|---|
| `poc/ocr_compare_models.py` | 双模型对比脚本 |
| `poc/out/compare_models/ocr_model_compare_summary.json` | 对比摘要 |
| `poc/out/compare_models/ocr_model_compare_report.json` | 逐页详细结果 |
| `poc/out/compare_models/ocr_model_compare_report.md` | 可读版报告 |
