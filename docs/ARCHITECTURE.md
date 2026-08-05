# FnWhisper 架构

## 方案选择

FnWhisper 是 macOS 菜单栏辅助功能 App，不实现系统输入法扩展。系统输入法扩展适合维护候选词、组合文本和输入源切换，但这个项目只有一条短流程：全局按键触发、录音、离线转写、写入当前焦点。辅助功能 App 能更直接地覆盖浏览器、编辑器和原生输入框。

## 运行链路

1. `FnKeyMonitor` 使用可拦截的全局 `flagsChanged` 事件监听。App 运行时消费 Fn 的按下和松开事件，避免系统的地球仪、表情、切换输入源或听写动作抢占；其他修饰键继续传给系统。状态机仍只在长按达到阈值后开始录音。
2. `FnPressStateMachine` 区分 Fn 短按和 350 ms 长按，避免正常点按 Fn 时误触发。
3. `TextInjector` 在录音开始前捕获当前文本 Accessibility 元素；焦点不是文本控件时立即在悬浮状态框中报错，避免完成识别后静默丢失结果。Terminal 的 `AXTextArea` 虽然不可直接改写 `AXValue`，仍作为有效目标交由键盘粘贴路径处理。
4. `AudioRecorder` 使用 `AVAudioEngine` 录音，并转换为 Whisper 所需的 16 kHz、单声道、16-bit WAV。
5. `WhisperTranscriber` 调用本机开源 `whisper.cpp` 的 `whisper-cli`，默认使用完整架构的量化 `large-v3-q5_0` GGML 模型输出纯文本。语言使用 `auto` 识别中文或英文并保留中英混说，输出策略拒绝中英文之外的文字脚本；固定 `zh` 会让 full Large-v3 将纯英文错误转成中文，因此不再作为默认值。计算默认使用 Apple Metal GPU；若子进程因受限沙箱等原因退出，删除不完整输出后自动用 CPU 重试。M4 Pro 的 11 秒 JFK 样本实测 Metal 为 3.03 秒、CPU 为 12.60 秒，文字完全一致。
6. `TextInjector` 重新激活并聚焦开始录音时捕获的输入框，再发送 Cmd+V；这规避了部分网页和 Electron 控件对 Accessibility 写入返回成功但不刷新界面的问题。事件构造失败时回退到 Accessibility API，并在粘贴完成后恢复原剪贴板。

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
- 语音和识别文本不发送给任何云端；网络只用于首次安装 `whisper.cpp` 和下载模型。

## 权限

- 输入监听：识别全局 Fn 状态。
- 麦克风：录制用户主动按住 Fn 时的语音。
- 辅助功能/事件输入：将文字写入当前输入框。

App 不启用 App Sandbox，因为全局按键监听、跨 App Accessibility 写入和执行本地 `whisper-cli` 都超出沙盒输入法的合适边界。
