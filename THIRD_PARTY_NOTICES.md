# Third-party components / 第三方组件

FnWhisper uses the following open-source components:

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp), MIT License. It is installed separately through Homebrew and runs only on the local Mac.
- [OpenAI Whisper](https://github.com/openai/whisper) model weights, MIT License. The setup script downloads the GGML conversion from the official `whisper.cpp` model location.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Apache License 2.0. FnWhisper statically links its official macOS XCFramework for local punctuation restoration.
- [ONNX Runtime](https://github.com/microsoft/onnxruntime), MIT License. FnWhisper statically links the macOS XCFramework version pinned by sherpa-onnx. See its [Third Party Notices](https://github.com/microsoft/onnxruntime/blob/v1.27.1/ThirdPartyNotices.txt).
- [FunASR CT-Punc](https://huggingface.co/funasr/ct-punc), Apache License 2.0. The setup script downloads the sherpa-onnx INT8 conversion from the official sherpa-onnx punctuation-model release.
- [llama.cpp](https://github.com/ggml-org/llama.cpp), MIT License. Homebrew provides the build input. The app snapshots llama-server and its matching GGML runtime for local loopback inference, with both MIT license texts included in the bundle.
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B), Apache License 2.0. The setup script downloads the pinned Q4_K_M conversion from [unsloth/Qwen3.5-4B-GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) for local text cleanup.

The setup scripts verify the downloaded Whisper, CT-Punc, and Qwen model files against pinned checksums. Model files are not committed to this repository. Full license and notice texts for the statically linked libraries are included in the app's `Resources/ThirdPartyLicenses` directory. Each component and model remains subject to its upstream license and notices.

---

FnWhisper 使用以下开源组件：

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)，MIT License；通过 Homebrew 独立安装，仅在本机运行。
- [OpenAI Whisper](https://github.com/openai/whisper) 模型权重，MIT License；安装脚本从 `whisper.cpp` 官方模型位置下载 GGML 转换版本。
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)，Apache License 2.0；FnWhisper 静态链接其官方 macOS XCFramework，在本机恢复标点。
- [ONNX Runtime](https://github.com/microsoft/onnxruntime)，MIT License；FnWhisper 静态链接 sherpa-onnx 固定版本的 macOS XCFramework。另见其[第三方声明](https://github.com/microsoft/onnxruntime/blob/v1.27.1/ThirdPartyNotices.txt)。
- [FunASR CT-Punc](https://huggingface.co/funasr/ct-punc)，Apache License 2.0；安装脚本从 sherpa-onnx 官方 punctuation-model release 下载 INT8 转换模型。
- [llama.cpp](https://github.com/ggml-org/llama.cpp)，MIT License；通过 Homebrew 准备构建输入；App 打包 llama-server 和匹配的 GGML 运行库，仅在本机回环地址推理，并附带两者的 MIT 许可证。
- [Qwen3.5-4B](https://huggingface.co/Qwen/Qwen3.5-4B)，Apache License 2.0；安装脚本从 [unsloth/Qwen3.5-4B-GGUF](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) 下载固定 revision 的 Q4_K_M 转换文件，用于本地文字整理。

安装脚本会使用固定校验值验证 Whisper、CT-Punc 和 Qwen 模型。模型文件不会提交到本仓库；静态链接库的完整许可证与第三方声明会放入 App 的 `Resources/ThirdPartyLicenses` 目录。第三方组件和模型仍分别受其上游许可证及声明约束。
