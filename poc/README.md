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
