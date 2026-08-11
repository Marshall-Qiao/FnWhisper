# FnWhisper

[English](README.md) | **简体中文**

FnWhisper 是一个仅做语音输入的 macOS 菜单栏 App：在任意输入框中按住 `Fn` 说话，松开后由本机开源 `whisper.cpp` 转成文字，并直接写回原输入框。

语音和识别文本不会上传云端。首次安装时需要联网安装 `whisper.cpp` 和下载模型，之后可以离线使用。

## 当前实现

- 长按 Fn 350 ms 开始录音，短按 Fn 不触发录音。
- App 运行时独占 Fn 的按下和松开事件，避免 macOS 原有的地球仪、表情、输入源或听写功能抢占；其他修饰键不受影响。
- 松开 Fn 后停止录音并开始本地转写。
- 不抢焦点的悬浮状态框会显示“正在听”“正在本地转成文字”和识别结果预览。
- 长按 Fn 时固定捕获当前文本输入控件，转写完成后写回同一个输入框；如果焦点在按钮等非输入控件，会立即提示先点击输入位置。
- 支持 macOS Terminal：终端的 `AXTextArea` 即使不允许直接修改 Accessibility 值，也会作为有效输入焦点并通过 Cmd+V 写入命令行。
- 默认让 Whisper 在中文与英文语音之间自动检测，输出层只接受中文、英文和中英混说；检测到其他文字脚本时不会写入。
- Whisper 的分段边界会保留为自然停顿，中文上下文中的标点会规范化，并在缺失时补全中文句末标点；纯英文结果不会被强制加句号，避免破坏终端命令和代码。
- 默认使用完整架构的量化 `large-v3-q5_0` 模型和 Apple Metal GPU 识别；它比 Turbo Q5 更准确。若 Metal 在受限运行环境中不可用，当前这一次转写会自动回退 CPU，不会丢失录音。
- 优先重新聚焦开始录音时的输入框并发送 Cmd+V，兼容网页和 Electron 编辑器；粘贴失败时回退到 Accessibility API，并恢复原剪贴板。
- 菜单栏显示就绪、录音、识别和错误状态。
- 不读取键入内容，不保存录音，不调用云端语音 API。

## 系统要求

- macOS 13 或更高版本。当前已在 Apple Silicon 上验证；Intel 尚未实机验证。
- Apple Command Line Tools（`swift`）和 Homebrew。
- 首次安装约需 1.1 GiB 模型空间；`whisper-cpp` 另占少量空间。

## 安装

```bash
git clone https://github.com/Marshall-Qiao/FnWhisper.git
cd FnWhisper
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/install.sh
```

新机器也可以执行 `./scripts/bootstrap-machine.sh`，按 `Brewfile` 安装运行依赖、下载并校验 `large-v3-q5_0` 模型，然后构建和安装 App。已验证的公开部署基线见 [部署机器配置](docs/DEPLOYMENT_MACHINE.md)。

App 默认安装到 `~/Applications/FnWhisper.app` 并启动。第一次启动时，请在“系统设置 → 隐私与安全性”中允许：

1. 输入监听；
2. 辅助功能；
3. 麦克风（第一次长按 Fn 时询问）。

授权后点击菜单栏波形图标，选择“检查权限与运行环境”。如果 macOS 要求，退出并重新打开 App 一次。

如果从旧的 ad-hoc 构建升级后权限反复显示未授权，执行一次：

```bash
tccutil reset All com.marshall.fnwhisper
./scripts/install.sh
```

然后重新授予上述权限。当前构建脚本会给无开发者证书的本地构建写入稳定的 designated requirement，后续重复构建不会再因二进制哈希变化丢失授权。正式分发应通过 `FNWHISPER_SIGN_IDENTITY` 指定 Apple Development 或 Developer ID Application 身份。

## 使用

1. 点击任意可输入文字的位置，保持光标在输入框内。
2. 按住 Fn，看到菜单栏图标变成麦克风后开始说话。
3. 松开 Fn，等待图标恢复为波形；文字会出现在原输入框。

开始录音时必须已有可见输入光标。识别期间可以切换窗口，结果仍会优先写入开始录音时捕获的输入框。密码框等安全输入区域会拒绝辅助功能写入，这是系统的预期保护。

## 整体流程

1. `FnKeyMonitor` 监听全局 Fn 事件；持续按住 350 ms 后触发，短按不会录音。
2. 触发时捕获当前输入框和所属应用，确保转写完成后仍能写回原位置。
3. `AudioRecorder` 从麦克风录音；松开 Fn 后转换为 Whisper 需要的 16 kHz、单声道、16-bit PCM WAV。
4. `WhisperTranscriber` 调用本地 `whisper-cli`，使用 `large-v3-q5_0` 和 Metal GPU 转写；GPU 子进程失败时自动用 CPU 重试。
5. 输出解析器根据 Whisper 分段恢复停顿、规范化中文标点，然后拒绝中英文之外的文字脚本。
6. `TextInjector` 重新定位原输入框，优先通过 Cmd+V 写入，并在需要时回退 Accessibility API；随后恢复用户原剪贴板并删除临时录音。

语音和模型推理全程留在本机。详细的模块边界、权限原因和失败处理见 [架构说明](docs/ARCHITECTURE.md)。

## 时间与准确率取舍

以下是参考机器 Apple M4 Pro（12 核 CPU、16 核 GPU、48 GiB 内存）的本地实测；时间包含 `whisper-cli` 每次启动和模型加载，不包含用户说话的时长：

| 选择 | 实测或影响 | 取舍 |
| --- | --- | --- |
| Metal GPU，`large-v3-q5_0` | 11 秒英文样本 3.03 秒 | 当前默认；与下方 CPU 输出完全一致，速度约为 CPU 的 4.2 倍 |
| CPU 8 线程，`large-v3-q5_0` | 同一英文样本 12.60 秒 | 更适合 Metal 不可用的受限环境；会明显占用 CPU |
| CPU 线程数 | 中英混合样本：4 线程 16.97 秒、8 线程 12.34 秒、10 线程 12.46 秒 | 8 线程在参考机器上最快；更多线程不一定更快，三次输出一致 |
| `large-v3-q5_0` | 1,081,140,203 bytes，约 1.01 GiB | 当前默认，优先准确率；模型加载和磁盘占用更高 |
| `large-v3-turbo-q5_0` | 574,041,195 bytes，约 548 MiB | 模型更小且通常更快，但可能牺牲复杂口音、噪声和中英混说的准确率；项目尚未对真实用户语音给出量化误差值 |

350 ms 的 Fn 长按阈值是误触与响应速度之间的取舍，可以通过 `holdMilliseconds` 调整。当前实现每次转写都会启动一次 CLI：优点是状态简单、失败隔离且完成后释放模型内存，代价是短语音也要支付模型加载时间。未来若改为常驻模型进程，可继续降低连续输入延迟，但会长期占用约 1 GiB 以上内存，并增加进程恢复和升级复杂度。

## 开发与验证

```bash
./scripts/test.sh
swift build
./scripts/build-app.sh
# 可选：用一段 16 kHz WAV 验证真实 whisper-cli 调用
./scripts/smoke-test-whisper.sh /absolute/path/to/audio.wav
# 查看当前安装包实际获得的权限
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose
# 15 秒内打印 Fn 原始键码，排查键盘映射
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --probe-fn 15
# 向当前输入框写入测试文字，单独验证写回链路
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --test-insert "FnWhisper 输入测试"
```

参考部署机器只安装了 Apple Command Line Tools，没有完整 Xcode，因此核心测试使用独立 Swift 测试运行器。测试覆盖 Fn 长按状态机、48 kHz 双声道到 16 kHz 单声道 WAV 的转换和 Whisper 文本清理；`swift build` 覆盖完整 AppKit/AVFoundation 编译。公开仓库也使用 GitHub Actions 的 `macos-26` arm64 runner 执行相同检查。

## 配置

Finder 启动的 App 可以通过 `defaults` 配置：

```bash
# 默认自动判断中文或英文，并保留中英混说
defaults write com.marshall.fnwhisper language auto

# 也可以显式固定一种语言
defaults write com.marshall.fnwhisper language en
defaults write com.marshall.fnwhisper language zh

# 调整 Fn 长按阈值，单位毫秒，范围 150–2000
defaults write com.marshall.fnwhisper holdMilliseconds 450

# 调整 Whisper CPU 线程数；M4 Pro 实测 8 最快
defaults write com.marshall.fnwhisper threadCount 8

# 默认启用 Metal；设为 false 可强制只用 CPU
defaults write com.marshall.fnwhisper useGPU true

# 使用其他本地 GGML 模型
defaults write com.marshall.fnwhisper modelPath "/absolute/path/ggml-small.bin"
```

开发时也可使用 `FNWHISPER_LANGUAGE`、`FNWHISPER_HOLD_MS`、`FNWHISPER_THREADS`、`FNWHISPER_GPU`、`FNWHISPER_MODEL`、`FNWHISPER_WHISPER_CLI` 环境变量覆盖这些值。语言接受 `auto`、`zh` 或 `en`；其他值都会回退到 `auto`，最终输出仍只允许中文和英文脚本。`FNWHISPER_GPU` 接受 `true/false`、`1/0`、`yes/no` 或 `on/off`。

可选模型：

```bash
./scripts/setup-whisper.sh large-v3-turbo-q5_0
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/setup-whisper.sh tiny
./scripts/setup-whisper.sh base
./scripts/setup-whisper.sh small
./scripts/setup-whisper.sh medium
```

下载其他模型后，需要用上面的 `modelPath` 指向对应文件。中文准确率通常随模型变大而提升，同时识别时间和内存占用也会增加。

## 已知边界

- 某些外接键盘或键盘重映射工具不会向 macOS 暴露独立 Fn 标志，此时无法使用 Fn 触发。
- 如果使用的键盘重映射工具在 CGEvent 层之前处理 Fn，App 无法拦截该工具的动作，需要在对应工具中取消 Fn 映射。
- App 运行时短按 Fn 的 macOS 原生动作也会被屏蔽；退出 App 后立即恢复。
- 当前是“按住说话、松开整段转写”，不是边说边实时流式显示。
- 本地临时录音会在转写结束后删除；进程被强制终止时，系统临时目录可能短暂保留未完成文件。

实现取舍和权限边界见 [架构说明](docs/ARCHITECTURE.md)。
