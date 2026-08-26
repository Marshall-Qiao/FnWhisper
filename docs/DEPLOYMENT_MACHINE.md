# 部署机器配置

本文记录 FnWhisper 在 2026-08-05 完成安装与输入验证、2026-08-12 完成常驻 Whisper 与 CT-Punc INT8 验证、2026-08-21 完成 Qwen 2507 文字整理验证，并在 2026-08-24 完成新版本安装与进程生命周期验证时的公开基线。它是已验证快照，不是最低硬件要求，也不保证 Homebrew 未来仍提供相同补丁版本。

## 已验证硬件

| 项目 | 配置 |
| --- | --- |
| 设备 | MacBook Pro (`Mac16,8`) |
| 芯片 | Apple M4 Pro，12 核 |
| 内存 | 48 GB |
| 架构 | arm64 |

本文件刻意不记录机器名称、用户名、序列号、硬件 UUID、IP 地址、GitHub token、TCC 权限数据库或其他本机应用清单。

## 已验证软件

| 项目 | 版本 |
| --- | --- |
| macOS | 26.5.2 (`25F84`) |
| Apple Command Line Tools | 26.6.0.0.1781586589 |
| Apple Swift | 6.3.3 |
| Homebrew | 6.0.15 |
| whisper.cpp | 1.9.2 |
| llama.cpp / llama-server | build 9430 |
| ggml | 0.18.1（当前链接版本） |
| sdl3 | 3.4.14 |
| sdl2-compat | 2.32.70 |
| libomp | 22.1.8（当前链接版本） |
| sherpa-onnx | 1.13.5（静态 macOS XCFramework） |
| ONNX Runtime | 1.27.1（静态 macOS XCFramework） |

参考机器没有安装完整 Xcode；项目使用 `/Library/Developer/CommandLineTools` 中的 Swift 工具链完成构建。

## 模型配置

| 项目 | 值 |
| --- | --- |
| 模型 | `ggml-large-v3-q5_0.bin`，完整 Large-v3 量化版 |
| 文件大小 | 1,081,140,203 bytes |
| SHA-1 | `e6e2ed78495d403bef4b7cff42ef4aaadcfea8de` |
| 默认位置 | `~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin` |
| 标点模型 | `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` |
| 标点模型大小 | 75,519,198 bytes |
| 标点模型 SHA-256 | `65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1` |
| 标点模型默认位置 | `~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx` |
| 文字整理模型 | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |
| Qwen 模型大小 | 2,497,281,120 bytes |
| Qwen 模型 SHA-256 | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` |
| Qwen 默认位置 | `~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf` |

模型不会提交到 Git。`scripts/setup-whisper.sh` 从 whisper.cpp 官方模型位置下载并校验 SHA-1；`scripts/setup-punctuation.sh` 从 sherpa-onnx 官方 punctuation-model release 下载并校验 SHA-256；`scripts/setup-qwen.sh` 从固定 revision 的 Unsloth GGUF 仓库下载基于官方 Qwen 模型的 Q4_K_M 文件，并校验 SHA-256。

Qwen 最终占用约 2.33 GiB；下载校验后写入最终路径时会短暂同时保留两份文件，因此安装时需预留约 4.66 GiB 可用空间。

## 部署布局

```text
~/Applications/FnWhisper.app
~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin
~/Library/Application Support/FnWhisper/Models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx
~/Library/Application Support/FnWhisper/Models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
/opt/homebrew/bin/whisper-cli        # Apple Silicon Homebrew
/opt/homebrew/bin/whisper-server     # Apple Silicon Homebrew
/opt/homebrew/bin/llama-server       # Apple Silicon Homebrew
/usr/local/bin/whisper-cli           # Intel Homebrew 兼容查找路径
/usr/local/bin/whisper-server        # Intel Homebrew 兼容查找路径
/usr/local/bin/llama-server          # Intel Homebrew 兼容查找路径
```

参考机器没有 Apple 代码签名身份。构建脚本因此使用 ad-hoc 签名，并加入只适合本地开发的稳定 designated requirement，避免每次二进制哈希变化都让 TCC 权限失效。它不包含 Apple Developer ID、私钥或公证凭据，也不应作为正式分发的信任方案；正式构建应通过 `FNWHISPER_SIGN_IDENTITY` 指定 Apple Development 或 Developer ID Application 身份。

公开仓库只构建 App；macOS 的输入监听、辅助功能和麦克风权限必须由当前登录用户在系统设置中手工授予，不能安全地随代码部署。首次从旧 ad-hoc 构建迁移时需执行一次 `tccutil reset All com.marshall.fnwhisper`，重新安装后再手动授权。

## 新机器部署

1. 安装 Apple Command Line Tools：`xcode-select --install`。
2. 安装 [Homebrew](https://brew.sh)。
3. 克隆仓库并运行：

```bash
./scripts/bootstrap-machine.sh
```

包含核心测试的分步部署命令是：

```bash
brew bundle --file Brewfile
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/setup-punctuation.sh
./scripts/setup-qwen.sh
./scripts/test.sh
./scripts/install.sh
```

安装完成后，在“系统设置 → 隐私与安全性”中授予输入监听、辅助功能和麦克风权限，再通过菜单栏的“检查权限与运行环境”确认状态。

## 已验证边界

- 核心测试：Fn 状态机、长按冲突拦截、音频格式转换、目标分类、Whisper server 协议、CLI 回退参数、标点和口语数字规范化、文字整理校验、Qwen fast 模式参数与动态超时。
- 构建：Swift Release 构建、sherpa-onnx / ONNX Runtime 静态链接、`.app` 打包与签名验证通过；可执行文件约 33.1 MiB。
- 安装：`~/Applications/FnWhisper.app` 稳定本地开发要求的 ad-hoc 签名验证通过。
- 识别：中文、英文和中英混说的真实 16 kHz WAV 均经 `large-v3-q5_0` 成功转写。
- 性能：同一中英混说样本 4 线程为 16.97 秒，8 线程为 12.34 秒，10 线程为 12.46 秒；默认选择 8 线程且三次输出一致。
- Metal：11 秒 JFK 样本在 M4 Pro 16 核 GPU 上为 3.03 秒，CPU 8 线程为 12.60 秒；输出完全一致，Metal 快约 4.2 倍。
- 常驻 Whisper：6.95 秒中文样本多轮首次请求 2.967–3.206 秒，热请求 1.949–1.999 秒；测试退出后确认没有遗留 `whisper-server` helper。
- CT-Punc：中英文 INT8 模型真实恢复中文陈述句、问句和中英混排标点；独立冷启动测试句总耗时 0.08 秒。模型输出仍可能误判个别问号或逗号。
- 文字整理：Qwen3-4B-Instruct-2507 Q4_K_M 使用 fast/non-thinking 模式，预热 1.5–2.7 秒，27 条固定中英语料的热请求为 0.18–1.31 秒且全部通过；回退窗口同时参考转写长度和 WAV 录音时长，范围 3–10 秒（10 秒录音为 6.5 秒）。2026-08-26 追加真实模型验证：因果/时间叙事保持段落；明确 3 个动作输出局部 1–3 列表并保留前后段落，Qwen 热请求分别为约 0.59 秒和 0.44 秒。Apple Foundation Models 当前端到端回退样本为 0.9–1.7 秒。热词、口语数字、改口、状态标记、责任归属、段落与数字列表均完成真实模型验证。
- 写回：原生 TextEdit 与 macOS Terminal 均完成实际 Cmd+V 写入验证；Terminal 测试命令只输出本地测试标记。
- GPU：Apple M4 Pro 16 核。Homebrew whisper.cpp 1.9.2 Metal 在普通应用环境工作正常；受限命令沙箱会拒绝 Metal buffer 分配，应用会自动回退 CPU。
- Intel：源代码包含 Intel Homebrew 路径，但尚未在 Intel Mac 上完成实机验证。

2026-08-24 已通过 `scripts/install.sh` 实际替换 `~/Applications/FnWhisper.app`。安装后确认 Release 与已安装可执行文件 SHA-256 一致、签名有效、旧版 helper 已退出，且新 App 只拥有自己的 Whisper 与 Qwen 2507 常驻进程；无关的本地模型服务未受影响。已安装可执行文件通过合成中文 WAV 的常驻 Whisper 冷/热请求、CT-Punc、Qwen 列表整理和 Apple Foundation Models 回退样本测试。当前登录用户仍需在系统设置中手工授予输入监听、辅助功能和麦克风权限，因此本轮没有把 Fn 热键与目标应用写入标记为已验证。
