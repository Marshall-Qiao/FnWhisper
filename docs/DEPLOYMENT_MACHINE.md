# 部署机器配置

本文记录 FnWhisper 在 2026-08-05 完成构建、安装、签名、音频转换和真实 Whisper 转写验证时的公开基线。它是已验证快照，不是最低硬件要求，也不保证 Homebrew 未来仍提供相同补丁版本。

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
| ggml | 0.18.1（当前链接版本） |
| sdl3 | 3.4.14 |
| sdl2-compat | 2.32.70 |
| libomp | 22.1.8（当前链接版本） |

参考机器没有安装完整 Xcode；项目使用 `/Library/Developer/CommandLineTools` 中的 Swift 工具链完成构建。

## 模型配置

| 项目 | 值 |
| --- | --- |
| 模型 | `ggml-large-v3-q5_0.bin`，完整 Large-v3 量化版 |
| 文件大小 | 1,081,140,203 bytes |
| SHA-1 | `e6e2ed78495d403bef4b7cff42ef4aaadcfea8de` |
| 默认位置 | `~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin` |

模型不会提交到 Git。`scripts/setup-whisper.sh` 从 whisper.cpp 官方模型位置下载，并在移动到最终目录前校验 SHA-1。

## 部署布局

```text
~/Applications/FnWhisper.app
~/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin
/opt/homebrew/bin/whisper-cli        # Apple Silicon Homebrew
/usr/local/bin/whisper-cli           # Intel Homebrew 兼容查找路径
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

等价的分步命令是：

```bash
brew bundle --file Brewfile
./scripts/setup-whisper.sh large-v3-q5_0
./scripts/test.sh
./scripts/install.sh
```

安装完成后，在“系统设置 → 隐私与安全性”中授予输入监听、辅助功能和麦克风权限，再通过菜单栏的“检查权限与运行环境”确认状态。

## 已验证边界

- 核心测试：Fn 状态机、长按冲突拦截、音频格式转换、Whisper 输出解析。
- 构建：Swift release 构建和 `.app` 打包通过。
- 安装：`~/Applications/FnWhisper.app` 稳定本地开发要求的 ad-hoc 签名验证通过。
- 识别：中文、英文和中英混说的真实 16 kHz WAV 均经 `large-v3-q5_0` 成功转写。
- 性能：同一中英混说样本 4 线程为 16.97 秒，8 线程为 12.34 秒，10 线程为 12.46 秒；默认选择 8 线程且三次输出一致。
- Metal：11 秒 JFK 样本在 M4 Pro 16 核 GPU 上为 3.03 秒，CPU 8 线程为 12.60 秒；输出完全一致，Metal 快约 4.2 倍。
- 写回：原生 TextEdit 与 macOS Terminal 均完成实际 Cmd+V 写入验证；Terminal 测试命令只输出本地测试标记。
- GPU：Apple M4 Pro 16 核。Homebrew whisper.cpp 1.9.2 Metal 在普通应用环境工作正常；受限命令沙箱会拒绝 Metal buffer 分配，应用会自动回退 CPU。
- Intel：源代码包含 Intel Homebrew 路径，但尚未在 Intel Mac 上完成实机验证。
