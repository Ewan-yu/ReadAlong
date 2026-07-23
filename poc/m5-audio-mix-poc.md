# M5.4 离线混音 PoC

此 PoC 验证“儿童录音 + 已确认背景轨”可在本机由 ffmpeg 完成，不下载模型、不修改正式家长端或阅读端代码。脚本、测试和输出均限定在 `poc/`；音频输出在被 Git 忽略的 `poc/out/`。

## 已固定的安全与降级契约

- 唯一允许的背景输入是家长确认后导出的 `original/background.ogg`；参数也限定为 `.ogg`。
- `original/source.mp3` **从不**进入 ffmpeg 输入。可通过 `--original-source` 传入它作路径/SHA-256 安全比对；一旦它被误选为儿童录音或伪装的背景，任务失败。
- 不存在已确认背景轨、分离失败、家长选择纯人声时，不猜测或回退至原音：输出 `mode: voice_only` 的纯儿童人声母版。
- 儿童录音保持原始文件不被覆盖。先输出 `.part`，两个 ffmpeg 阶段都成功后才原子替换目标；取消与失败会删除该临时文件。

## 音频处理

混音以儿童 WAV 为时间长度（`amix=duration=first`）。背景先衰减默认 `-18 dB`，避免抢读；两遍 `loudnorm` 让最终母版目标为 **-16 LUFS / -1 dBTP true peak**。第一遍只测量，第二遍带入测量结果渲染，因此不是简单音量缩放，也不会因相加削波。

输出可选 WAV（PoC 最稳定）、M4A/AAC 或 OGG/Opus。实际阅读端落地时应再以目标 Android 设备上的 ffmpeg 集成验证 AAC/Opus 编码可用性与包体积；这个 PoC 不主张直接引入任一 Flutter ffmpeg 插件。

## 运行

PowerShell 示例（所有输入均为本地已存在文件）：

```powershell
$python = 'D:\Program Files\Anaconda3\envs\readalong\python.exe'
& $python poc/audio_mix_poc.py `
  --child-wav poc/recordings/child.wav `
  --background-ogg F:/ReadAlongData/workspaces/demo/original/background.ogg `
  --original-source F:/ReadAlongData/workspaces/demo/original/source.mp3 `
  --output poc/out/mix/child_with_music.m4a
```

纯人声降级只是不传 `--background-ogg`：

```powershell
& $python poc/audio_mix_poc.py `
  --child-wav poc/recordings/child.wav `
  --output poc/out/mix/child_voice_only.wav
```

取消接入点为 `render_mix(..., cancel_event=threading.Event())`：UI 将事件设为已取消时，PoC 终止 ffmpeg，最多等待 3 秒后强杀，并保证没有半成品输出。CLI 当前故意不把取消做成隐藏热键，避免把平台 UI 的生命周期判断伪装成已验证功能。

## 无模型测试

```powershell
pytest -q poc/test_audio_mix_poc.py
```

测试覆盖：原音不会进入命令、同 SHA-256 的伪装背景被拒、纯人声显式降级、已运行 ffmpeg 的取消路径，以及响度结果解析失败。

## 仍需实体机验证后才能产品化

1. 选定 Android 的 ffmpeg 分发方式与许可证/包体积，不能直接复制桌面 ffmpeg 二进制；
2. 真实低端平板上的耗时、取消响应、音频焦点和储存空间不足；
3. AAC 与 Opus 输出的播放器兼容性，以及混音后的主观音乐/儿童声音量；
4. 用 loudness meter 复核生成文件确实达到 -16 LUFS、峰值不高于 -1 dBTP。
