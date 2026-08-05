# 第三方组件

FnWhisper 通过本机命令行调用以下独立开源组件，不复制其源代码或二进制到本项目仓库：

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)，MIT License。
- [OpenAI Whisper](https://github.com/openai/whisper) 模型权重，MIT License；本项目的安装脚本从 `whisper.cpp` 官方模型清单指向的位置下载 GGML 转换版本。

安装脚本会对模型文件执行 `whisper.cpp` 官方清单提供的 SHA-1 校验。第三方组件和模型仍分别受其上游许可证约束。
