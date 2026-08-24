# FnWhisper 架构

## 方案选择

FnWhisper 是 macOS 菜单栏辅助功能 App，不实现系统输入法扩展。系统输入法扩展适合维护候选词、组合文本和输入源切换，但这个项目只有一条短流程：全局按键触发、录音、离线转写、写入当前焦点。辅助功能 App 能更直接地覆盖浏览器、编辑器和原生输入框。

## 运行链路

1. `FnKeyMonitor` 使用可拦截的全局 `flagsChanged` 事件监听。App 运行时消费 Fn 的按下和松开事件，避免系统的地球仪、表情、切换输入源或听写动作抢占；其他修饰键继续传给系统。状态机仍只在长按达到阈值后开始录音。
2. `FnPressStateMachine` 区分 Fn 短按和 350 ms 长按，避免正常点按 Fn 时误触发。
3. `TextInjector` 在录音开始前捕获当前文本 Accessibility 元素和所属 App 的 bundle ID；焦点不是文本控件时立即在悬浮状态框中报错。`TextTargetPolicy` 将 Terminal、常见 IDE 和代码编辑器归为命令/代码目标，其余目标按普通文本处理。Terminal 的 `AXTextArea` 虽然不可直接改写 `AXValue`，仍作为有效目标交由键盘粘贴路径处理。
4. `AudioRecorder` 使用 `AVAudioEngine` 录音，并转换为 Whisper 所需的 16 kHz、单声道、16-bit WAV。
5. `WhisperRuntime` 在 App 启动后预热本机 `whisper-server`，默认用 Metal 和完整架构的量化 `large-v3-q5_0` 输出原始文本。服务只监听 `127.0.0.1`，端口和请求路径每次随机生成；所有请求串行发送。Metal 服务失败时尝试常驻 CPU，服务整体失败时明确提示并回退到一次性 `whisper-cli`。失败会短暂退避，避免每段语音重复等待启动超时；退出 App 时以不可逆关闭门闩同步回收其子进程。
6. 普通文本目标把原始结果交给进程内常驻的 `SherpaPunctuationRestorer`。它使用静态链接的 `sherpa-onnx` / ONNX Runtime 和约 72 MiB 的中英 CT-Punc INT8 模型恢复语义标点，随后统一中英文标点与混排间距。若模型缺失或推理失败，界面明确提示并使用基础分段结果。命令/代码目标完全跳过 CT-Punc 与句末补全，防止修改 Terminal 命令或代码。
7. 普通文本随后进入 `TextRefinement`。确定性预处理先删除明确的纯语气词，修正 Claude Code、CLIProxyAPI、Qwen、codex 等热词，并把高置信度中英文口语数字规范成阿拉伯数字。整理层使用只有 `items` 的最小结构：段落只允许 1 项，可靠并列内容允许 2–8 项并由客户端渲染数字列表；显式枚举的共同前提和收尾由客户端保留，避免小模型重复或遗漏。`QwenTextRefiner` 与 Apple Foundation Models 同时开始推理。Qwen 使用 `Qwen3-4B-Instruct-2507 Q4_K_M`、Metal、fast/non-thinking 和严格 JSON Schema；请求计时从转写与标点完成后开始，并按非空白字符数为短、中、长文本提供 3、4、5 秒窗口。窗口内成功且通过校验时优先；超时或无效时等待已经并行执行的 Apple 结果。两边均失败时保留已经过确定性规范化的 CT-Punc 结果，并明确显示回退提示。
8. 统一校验器只接受 paragraph 或 2–8 项 numbered list，并保护原文已有的数字、时间、路径、URL、技术标识符和否定范围；额外 JSON 残片、思考标签、序号数量变化或受保护内容变化都会使该模型结果失效。中文、英文和中英混合输入保持原语言，不执行、回答或翻译原文中的指令。Terminal/IDE 目标完全跳过此层。
9. `BilingualOutputPolicy` 在最终写入前拒绝中英文之外的字母脚本。语言仍默认使用 `auto` 以保留中英混说；固定 `zh` 或 `en` 仅作为显式配置。
10. `TextInjector` 重新激活并聚焦开始录音时捕获的输入框，再发送 Cmd+V；这规避了部分网页和 Electron 控件对 Accessibility 写入返回成功但不刷新界面的问题。事件构造失败时回退到 Accessibility API，并在粘贴完成后恢复原剪贴板。

## 状态与失败边界

```text
idle -> armed -> recording -> transcribing -> idle
          |                         |
          +---- short press --------+
                                    +-> failed -> idle
```

- Fn 在麦克风授权完成前已经松开时，不开始录音。
- 同一时刻最多处理一段语音；识别期间的新 Fn 事件不会开启第二个任务。
- 临时录音与转写文件在成功或失败后清理。
- 模型文件使用官方 `whisper.cpp` 清单中的 SHA-1 校验。
- CT-Punc 压缩包和解压后的 INT8 模型都使用固定 SHA-256 校验；模型文件不提交到仓库。
- Qwen GGUF 使用固定 SHA-256 校验；`llama-server` 仅绑定随机的 `127.0.0.1` 端口，以 offline 和 no-UI 模式运行。App 启动时在后台预热并填充公共提示词缓存，退出时同步回收它启动的 Qwen 子进程。
- `whisper-server` 只接受本机回环请求，随机请求路径降低其他本机进程误调用的机会；它不对局域网开放。
- 语音和识别文本不发送给任何云端；网络只用于首次安装依赖、下载模型和构建时获取固定版本的静态 XCFramework。
- 当前仍在松开 Fn 后做完整语音的最终识别；不会把可能反复修订的 partial 文本直接写进任意输入框。

## 权限

- 输入监听：识别全局 Fn 状态。
- 麦克风：录制用户主动按住 Fn 时的语音。
- 辅助功能/事件输入：将文字写入当前输入框。

App 不启用 App Sandbox，因为全局按键监听、跨 App Accessibility 写入和执行本地 `whisper-server` / `whisper-cli` / `llama-server` 都超出沙盒输入法的合适边界。Info.plist 为回环 HTTP 推理声明 macOS 的本地网络 ATS 例外；真正的访问边界由两个本地 server 强制绑定 `127.0.0.1` 实现。
