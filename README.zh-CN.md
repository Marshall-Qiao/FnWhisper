# FnWhisper

[English](README.md) | **简体中文**

FnWhisper 是一个仅做语音输入的 macOS 菜单栏 App：在任意输入框中按住 `Fn` 说话，松开后由本机 `whisper.cpp` 转成文字，再由本地模型整理成更清楚、简洁、有条理的表达并写回原输入框。

语音和识别文本不会上传云端。首次安装时需要联网安装 `whisper.cpp` / `llama.cpp`、下载 Whisper、CT-Punc 与 Qwen 模型，并在构建时获取固定版本的静态推理库；之后可以离线使用。

## README 索引

- [最快安装](#最快安装)：新 Mac 从源码、依赖和模型到可运行 App。
- [会安装什么](#会安装什么)：Homebrew 依赖、三个本地模型、系统模型和落盘位置。
- [分步安装](#分步安装)：逐项执行并在安装前运行核心测试。
- [首次授权](#首次授权)：输入监听、辅助功能和麦克风权限。
- [验证安装](#验证安装)：检查权限、模型、签名和进程。
- [升级](#升级)：拉取新代码后安全重建和替换本地 App。
- [使用](#使用)：长按 Fn 完成语音输入。
- [开发与验证](#开发与验证)：开发者测试和真实模型诊断命令。

如果只想安装，直接从[最快安装](#最快安装)开始。

## 当前实现

- 长按 Fn 350 ms 开始录音，短按 Fn 不触发录音。
- App 运行时独占 Fn 的按下和松开事件，避免 macOS 原有的地球仪、表情、输入源或听写功能抢占；其他修饰键不受影响。
- 松开 Fn 后停止录音并开始本地转写。
- 不抢焦点的悬浮状态框会显示“正在听”和“正在本地转成文字”；完成时显示不会写入正文的来源图标和简短说明，例如 `Ⓠ 最终由 Qwen3-4B 本地模型整理`。`Ⓐ` 表示 Apple，`Ⓦ` 表示保留 Whisper/规范化结果。
- 长按 Fn 时固定捕获当前文本输入控件，转写完成后写回同一个输入框；如果焦点在按钮等非输入控件，会立即提示先点击输入位置。
- 支持 macOS Terminal：终端的 `AXTextArea` 即使不允许直接修改 Accessibility 值，也会作为有效输入焦点并通过 Cmd+V 写入命令行。
- 默认让 Whisper 在中文与英文语音之间自动检测，输出层只接受中文、英文和中英混说；检测到其他文字脚本时不会写入。
- 所有输入框（包括 Terminal、IDE 和代码编辑器）都使用同一条本地处理链：CT-Punc 恢复语义标点，再由 Qwen/Apple 整理；不再按应用类型跳过模型。
- 普通输入框的中英文或中英混合结果会做结构化整理：删除口吃和纯语气词、恢复热词、转换口语数字、处理明确改口，并把具有可靠枚举或并列信号的任务、步骤或要求渲染成数字列表；即使原文只说“一个是、然后、还有、最后”也能识别。不会翻译、回答问题或改变原意。
- `Qwen3-4B-Instruct-2507 Q4_K_M` 通过本机 `llama-server` 以 fast/non-thinking 模式运行，并与 Apple Foundation Models 并行。Qwen 按转写长度获得 3–5 秒的动态请求窗口，窗口内返回且通过语义保护时优先；否则使用已并行完成的 Apple 结果；两者都失败时保留经过确定性规范化和标点处理的转写。
- 默认使用完整架构的量化 `large-v3-q5_0` 模型和 Apple Metal GPU 识别；App 启动后会预热仅监听 `127.0.0.1` 的 `whisper-server`，连续输入无需反复加载模型。Metal 常驻服务失败时会明确提示并尝试 CPU，服务整体不可用时再回退到较慢的单次 `whisper-cli`。
- 优先重新聚焦开始录音时的输入框并发送 Cmd+V，兼容网页和 Electron 编辑器；粘贴失败时回退到 Accessibility API，并恢复原剪贴板。
- 菜单栏显示就绪、录音、识别和错误状态；完整处理路径保留在完成阶段的菜单栏悬停提示和本地日志中。
- 不读取键入内容，不保存录音，不调用云端语音 API。

## 系统要求

- macOS 13 或更高版本。当前已在 Apple Silicon 上验证；Intel 尚未实机验证。
- Apple Command Line Tools（`swift`）和 Homebrew。
- 首次安装约需 1.01 GiB Whisper、72 MiB CT-Punc INT8 和 2.33 GiB Qwen 模型空间；Homebrew 运行依赖另占少量空间。Qwen 下载校验和安装期间需预留约 4.66 GiB 可用空间。

## 最快安装

这是新机器的推荐入口。安装脚本只支持 macOS；当前已在 Apple Silicon 上验证。

### 1. 安装一次性前置工具

安装 Apple Command Line Tools：

```bash
xcode-select --install
```

然后从 [brew.sh](https://brew.sh) 安装 Homebrew，并确认两者可用：

```bash
xcode-select -p
brew --version
```

### 2. 克隆并执行完整安装

```bash
git clone https://github.com/Marshall-Qiao/FnWhisper.git
cd FnWhisper
./scripts/bootstrap-machine.sh
```

`bootstrap-machine.sh` 会依次执行以下操作：

1. 按 `Brewfile` 安装 `whisper-cpp` 和 `llama.cpp`；
2. 下载并校验 Whisper、CT-Punc、Qwen 三个本地模型；
3. 通过 Swift Package Manager 获取固定版本的 sherpa-onnx 与 ONNX Runtime 静态库；
4. 构建、签名并安装 `~/Applications/FnWhisper.app`；
5. 备份旧 App、停止它启动的旧 helper，然后启动新 App。

脚本可以重复执行。已经存在且校验正确的模型不会重新下载。

## 会安装什么

### 代码和运行依赖

| 组件 | 用途 | 来源/安装方式 |
| --- | --- | --- |
| Apple Swift、AppKit、AVFoundation | 编译 App、录音和菜单栏界面 | Apple Command Line Tools / macOS |
| `whisper-cli`、`whisper-server` | 本地语音识别；常驻服务失败时支持 CLI 回退 | Homebrew `whisper-cpp` |
| `llama-server` | 运行本地 Qwen 文字整理模型 | Homebrew `llama.cpp` |
| sherpa-onnx 1.13.5 | 本地中英文 CT-Punc 标点恢复 | SwiftPM 固定版本静态 XCFramework |
| ONNX Runtime 1.27.1 | 执行 CT-Punc ONNX 模型 | SwiftPM 固定版本静态 XCFramework |

### 本地模型

| 模型 | 用途 | 大小 | 默认位置 |
| --- | --- | ---: | --- |
| `ggml-large-v3-q5_0.bin` | Whisper 中英文及中英混说识别 | 约 1.01 GiB | `~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin` |
| `model.int8.onnx` | sherpa-onnx CT-Punc 中英文标点 | 约 72 MiB | `~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` |
| `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | 本地 fast/non-thinking 文字整理 | 约 2.33 GiB | `~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |

三个下载脚本都校验固定哈希后才写入最终路径。Qwen 下载和安装期间会短暂保留两份文件，因此首次安装应至少预留约 4.66 GiB 可用空间；整个安装还需要为 Whisper、CT-Punc、Homebrew 依赖和构建缓存预留额外空间。

Apple Foundation Models 不是本项目下载的模型。它是 macOS 26 提供的可选系统能力；系统模型不可用时，FnWhisper 仍可使用本地 Qwen，或者保留经过 Whisper、标点和确定性规范化处理的文字。

最终主要文件布局如下：

```text
~/Applications/FnWhisper.app
~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin
~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx
~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
```

已验证的公开软件版本、哈希和硬件基线见[部署机器配置](docs/DEPLOYMENT_MACHINE.md)。

## 分步安装

如果希望逐项观察依赖、模型和测试结果，执行：

```bash
brew bundle --file Brewfile
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/setup-punctuation.sh
./scripts/setup-qwen.sh
./scripts/test.sh
./scripts/install.sh
```

各脚本职责：

| 脚本 | 作用 |
| --- | --- |
| `scripts/setup-whisper.sh` | 安装/检查 `whisper.cpp`，下载并校验指定 Whisper 模型 |
| `scripts/setup-punctuation.sh` | 下载、解压并校验 CT-Punc INT8 模型 |
| `scripts/setup-qwen.sh` | 检查 `llama-server` 必需参数，下载并校验固定 revision 的 Qwen GGUF |
| `scripts/test.sh` | 运行不依赖 XCTest 的核心 Swift 测试 |
| `scripts/build-app.sh` | Release 构建、组装 `.app`、打包许可证并完成代码签名验证 |
| `scripts/install.sh` | 构建、备份旧 App、替换安装、结束旧 helper 并启动新 App |

默认安装目录是 `~/Applications`。开发者可以在安装前设置 `FNWHISPER_INSTALL_DIR` 改变目标目录；模型根目录可通过 `FNWHISPER_APP_SUPPORT_DIR` 改变。

## 首次授权

App 首次启动后，在“系统设置 → 隐私与安全性”中允许：

1. 输入监听；
2. 辅助功能；
3. 麦克风（第一次长按 Fn 时询问）。

这些权限属于当前 Mac 登录用户，安装脚本不能代替用户授予。授权后点击菜单栏波形图标，选择“检查权限与运行环境”；如果 macOS 要求，退出并重新打开 App 一次。

如果从旧的 ad-hoc 构建升级后权限反复显示未授权，执行一次：

```bash
tccutil reset All com.marshall.fnwhisper
./scripts/install.sh
```

然后重新授予上述权限。当前构建脚本会给无开发者证书的本地构建写入稳定的 designated requirement，后续重复构建不会再因二进制哈希变化丢失授权。正式分发应通过 `FNWHISPER_SIGN_IDENTITY` 指定 Apple Development 或 Developer ID Application 身份。

## 验证安装

授予权限后执行：

```bash
# 检查依赖、三个模型和当前权限；缺少权限时命令会返回非零状态
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose

# 检查 App 签名
codesign --verify --deep --strict ~/Applications/FnWhisper.app

# 确认 App 已运行
pgrep -fl '/FnWhisper.app/Contents/MacOS/FnWhisper'
```

最后在任意普通输入框中做一次真实验证：保持光标可见，按住 Fn 说一句中英文或中英混合内容，松开后确认文字回到同一个输入框。

## 升级

在干净工作区中更新代码并重复运行完整安装脚本：

```bash
git pull --ff-only
./scripts/bootstrap-machine.sh
```

安装脚本会把现有 App 移到同目录下带时间戳的 `FnWhisper.app.backup-*`，再安装并启动新构建；模型哈希正确时不会重复下载。升级不会自动提交、推送或删除源码工作区中的文件。

## 使用

1. 点击任意可输入文字的位置，保持光标在输入框内。
2. 按住 Fn，看到菜单栏图标变成麦克风后开始说话。
3. 松开 Fn，等待图标恢复为波形；文字会出现在原输入框。

开始录音时必须已有可见输入光标。识别期间可以切换窗口，结果仍会优先写入开始录音时捕获的输入框。密码框等安全输入区域会拒绝辅助功能写入，这是系统的预期保护。

## 整体流程

1. `FnKeyMonitor` 监听全局 Fn 事件；持续按住 350 ms 后触发，短按不会录音。
2. 触发时捕获当前输入框和所属应用，确保转写完成后仍能写回原位置。
3. `AudioRecorder` 从麦克风录音；松开 Fn 后转换为 Whisper 需要的 16 kHz、单声道、16-bit PCM WAV。
4. `WhisperRuntime` 将 WAV 发送到本机回环地址上的常驻 `whisper-server`，使用 `large-v3-q5_0` 和 Metal GPU 转写；服务失败时按“常驻 CPU → 单次 CLI”顺序显式回退。
5. 普通文本目标把 Whisper 原始文字交给进程内常驻的 `sherpa-onnx` CT-Punc INT8 恢复中英文标点，再进行确定性的语气词、热词和口述数字规范化，随后同时请求本机 Qwen fast 模式和 Apple Foundation Models。Qwen 计时只在说话、Whisper 转写和标点处理全部完成后开始：短、中、长文本分别等待 3、4、5 秒；窗口内返回且通过结构与语义校验时优先，否则使用 Apple；两者均失败则保留经过确定性规范化和标点处理的转写。
6. 所有目标都使用相同的标点与文字整理流程，最后统一拒绝中英文之外的文字脚本。
7. `TextInjector` 重新定位原输入框，优先通过 Cmd+V 写入，并在需要时回退 Accessibility API；随后恢复用户原剪贴板并删除临时录音。

语音和模型推理全程留在本机。详细的模块边界、权限原因和失败处理见 [架构说明](docs/ARCHITECTURE.md)。

## 时间与准确率取舍

以下是参考机器 Apple M4 Pro（12 核 CPU、16 核 GPU、48 GiB 内存）的本地实测；时间不包含用户说话时长：

| 选择 | 实测或影响 | 取舍 |
| --- | --- | --- |
| 常驻 Metal，`large-v3-q5_0` | 6.95 秒中文样本：多轮首次请求 2.967–3.206 秒；同进程热请求 1.949–1.999 秒 | 当前默认；首次可能包含服务预热，连续输入约 2 秒 |
| 单次 CLI Metal，`large-v3-q5_0` | 11 秒英文样本 3.03 秒 | 常驻服务不可用时的兼容路径；每段都重新启动并加载模型 |
| CPU 8 线程，`large-v3-q5_0` | 同一英文样本 12.60 秒 | 更适合 Metal 不可用的受限环境；会明显占用 CPU |
| CPU 线程数 | 中英混合样本：4 线程 16.97 秒、8 线程 12.34 秒、10 线程 12.46 秒 | 8 线程在参考机器上最快；更多线程不一定更快，三次输出一致 |
| `large-v3-q5_0` | 1,081,140,203 bytes，约 1.01 GiB | 当前默认，优先准确率；模型加载和磁盘占用更高 |
| `large-v3-turbo-q5_0` | 574,041,195 bytes，约 548 MiB | 模型更小且通常更快，但可能牺牲复杂口音、噪声和中英混说的准确率；项目尚未对真实用户语音给出量化误差值 |
| CT-Punc 中英 INT8 | 75,519,198 bytes，约 72 MiB；独立冷启动处理测试句共 0.08 秒 | 只处理最终文本，几乎不增加 Whisper 推理负担；相比基础分段更自然，但模型仍可能误判问号或逗号 |
| Qwen3-4B-Instruct-2507 Q4_K_M fast 模式 | 2,497,281,120 bytes；预热 1.5–2.7 秒，27 条热请求语料为 0.18–1.31 秒 | 默认文字整理结果；常驻本机内存，不启用 thinking，并按转写长度设置 3–5 秒回退窗口 |
| Apple Foundation Models 回退 | 当前端到端样本约 0.9–1.7 秒完成 | macOS 26 且系统模型可用时提供快速回退；输出仍需通过相同结构与语义保护 |

350 ms 的 Fn 长按阈值是误触与响应速度之间的取舍，可以通过 `holdMilliseconds` 调整。常驻 Whisper 去掉了连续输入时重复加载模型的成本，但 App 运行期间会长期占用约 1 GiB 以上模型内存；退出 App 会同步结束它启动的 helper。当前仍在松开 Fn 后对完整语音做一次最终识别，不是边说边输出 partial，因此准确率与写入稳定性优先于首字延迟。

## 开发与验证

```bash
./scripts/test.sh
swift build
./scripts/build-app.sh
# 可选：用一段 16 kHz WAV 验证真实 whisper-cli 调用
./scripts/smoke-test-whisper.sh /absolute/path/to/audio.wav
# 验证常驻 Whisper 的连续请求和后端/耗时
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-whisper-runtime /absolute/path/to/audio.wav 3
# 验证真实 CT-Punc 模型
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-punctuation "你好这是标点测试"
# 验证 Qwen/Apple 并行、输出模型和文字整理耗时
.build/FnWhisper.app/Contents/MacOS/FnWhisper --test-text-refinement "嗯 use cloud code 修复这个 bug"
# 查看当前安装包实际获得的权限
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --diagnose
# 15 秒内打印 Fn 原始键码，排查键盘映射
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --probe-fn 15
# 向当前输入框写入测试文字，单独验证写回链路
~/Applications/FnWhisper.app/Contents/MacOS/FnWhisper --test-insert "FnWhisper 输入测试"
```

参考部署机器只安装了 Apple Command Line Tools，没有完整 Xcode，因此核心测试使用独立 Swift 测试运行器。测试覆盖 Fn 状态机、音频转换、目标分类、Whisper server 协议、CLI 回退参数、标点和口语数字规范化、文字整理校验、Qwen fast 模式参数与动态超时；`./scripts/build-app.sh` 覆盖 AppKit、AVFoundation、sherpa-onnx 与 ONNX Runtime 的完整 Release 链接。公开仓库也使用 GitHub Actions 的 `macos-26` arm64 runner 执行自动检查。

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

# 使用其他本地 CT-Punc INT8 模型文件
defaults write com.marshall.fnwhisper punctuationModelPath "/absolute/path/model.int8.onnx"

# 使用其他本地 Qwen GGUF 文件
defaults write com.marshall.fnwhisper textModelPath "/absolute/path/model.gguf"
```

开发时也可使用 `FNWHISPER_LANGUAGE`、`FNWHISPER_HOLD_MS`、`FNWHISPER_THREADS`、`FNWHISPER_GPU`、`FNWHISPER_MODEL`、`FNWHISPER_TEXT_MODEL`、`FNWHISPER_PUNCTUATION_MODEL`、`FNWHISPER_LLAMA_SERVER`、`FNWHISPER_WHISPER_SERVER`、`FNWHISPER_WHISPER_CLI` 环境变量覆盖这些值。语言接受 `auto`、`zh` 或 `en`；其他值都会回退到 `auto`，最终输出仍只允许中文和英文脚本。`FNWHISPER_GPU` 接受 `true/false`、`1/0`、`yes/no` 或 `on/off`。

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
- Terminal、IDE 和代码编辑器也会经过 CT-Punc 与 Qwen/Apple 整理，因此口述命令或代码可能被自动加标点或重新排版。
- Apple Foundation Models 需要 macOS 26 且系统模型处于可用状态；不可用时 Qwen 仍可独立工作。Qwen 超时或结果未通过语义保护时会使用 Apple 或保留经过确定性规范化和标点处理的转写，不会写入被判定为改变原意的结果。
- 本地临时录音会在转写结束后删除；进程被强制终止时，系统临时目录可能短暂保留未完成文件。

实现取舍和权限边界见 [架构说明](docs/ARCHITECTURE.md)。
