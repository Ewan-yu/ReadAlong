# M5 WP2 Demucs 人声/背景分离 PoC 报告

| 项目 | 结果 |
|---|---|
| 日期 | 2026-07-23（最终结论） |
| 输入 | `0-411-2-my-family-20260718-04/original_audio.mp3`（只读） |
| 输入规格 | 73.508563s / 44.1kHz / 双声道 MP3 / 1,176,182 bytes |
| 输入 SHA-256 | `ceb892b5c5c160ca18bc7e051f552b74d8a0f0361551dce4ce4dad17fa747e5e` |
| 硬件 | NVIDIA GeForce RTX 4070 12GB |
| 软件 | Python 3.11.15 / PyTorch 2.6.0+cu124 / Demucs 4.0.1 |
| 状态 | 技术、自动旁白残留筛查与三段人工试听已完成；默认采用 `htdemucs` |

## 1. 运行结果

参数统一为 CUDA、`shifts=1`、`overlap=0.25`、默认分段。输出使用 float32 WAV，避免为 PoC 试听引入额外重采样或有损编码。

| 指标 | `htdemucs` | `htdemucs_ft` |
|---|---:|---:|
| 权重数量 / 本地大小 | 1 / 80.2MB | 4 / 320.8MB |
| 模型加载 | 0.452s | 1.656s |
| 73.5s 音频推理 | 3.969s | 5.555s |
| RTF | 0.054 | 0.076 |
| CUDA 峰值 allocated | 549.0MB | 553.3MB |
| CUDA 峰值 reserved | 746MB | 790MB |
| 最大时长漂移 | 0.008ms | 0.008ms |
| 人声 RMS | -24.92dBFS | -24.94dBFS |
| 背景 RMS | -32.54dBFS | -32.69dBFS |

两种模型在 RTX 4070 上均显著快于实时，显存余量很大；工程上不需要为了本长度音频提前引入复杂分块策略。

## 2. 自动旁白残留筛查

使用本地缓存的 Whisper tiny 对原音、人声轨和背景轨转写。原音识别到 26 个 token，人声轨均保留 19 个主要绘本 token，序列相似度均为 0.844。

| 指标 | `htdemucs` 背景 | `htdemucs_ft` 背景 |
|---|---:|---:|
| Whisper token 数 | 2 | 12 |
| 与原音 token recall | 0 | 0 |
| 与原音 sequence similarity | 0 | 0 |
| 平均 log probability | -4.52 | -5.07 |
| 平均 no-speech probability | 0.460 | 0.476 |

两条背景轨都没有识别出 `family/dad/mom/grandma/grandpa` 等原旁白词。背景轨转写内容置信度极低，更像 Whisper 对音乐/伪影的幻觉。该结果可以排除“明显可识别旁白大量残留”，但不能证明人耳完全听不到旁白。

## 3. 人工试听门禁

`poc/out/demucs/<model>/previews/` 已为开头、中段、结尾各生成 12 秒：

- `original.ogg`：比较基准；
- `vocals.ogg`：确认旁白完整度、齿音和音乐泄漏；
- `background.ogg`：确认旁白残留、水声、断裂和高频损伤。

三段人工试听已完成，结论如下：

1. 未能稳定听出可理解的原旁白残留；
2. 两个模型均存在可感知的音乐/伪影差异，但没有足以支持 `htdemucs_ft` 的稳定听感收益；
3. 开头、中段、结尾的结论一致，因此正式候选默认使用体积更小、推理更快且自动筛查更干净的 `htdemucs`；
4. 分离结果仍必须由家长试听确认后才提升为不可变背景 revision，失败时继续生成纯人声版。

## 4. 工程建议

- 默认候选先使用 `htdemucs`：单权重、下载更小、推理更快，本样本的自动残留筛查也更干净。
- `htdemucs_ft` 保留为人工 A/B 备选；只有听感明显更好时才值得产品化。
- 权重只存本地缓存，不写仓库、不打进基础安装包。正式产品可按需下载，并复用当前续传、重试与 SHA-256 校验逻辑。
- Demucs 4.0.1 Python 包声明 MIT License；正式分发权重前仍需对上游模型权重的分发条款做一次独立确认。
- 分离失败时继续执行既定降级：原音欣赏不受影响，孩子作品只生成纯人声版。

## 5. 国内网络实测

- Python 包通过清华 PyPI 镜像安装成功，未替换现有 PyTorch/CUDA。
- 官方权重源 `dl.fbaipublicfiles.com` 可直连，下载速率随时间约 1–4MB/s。
- 新增下载器支持 `.part` 续传、指数重试、可替换 `DEMUCS_MODEL_BASE_URL` 和文件名 SHA-256 前缀校验。
- 五个权重共约 401MB，缓存于 `F:\Source\ReadAlong\pretrained_models\Demucs`，未进入 Git。
