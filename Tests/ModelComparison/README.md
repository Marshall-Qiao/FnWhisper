# 本地模型比较工具

结果与评分口径见 [2026-09-21 报告](../../docs/MODEL_COMPARISON_2026-09-21.md)。这些是独立运行的真实模型实验，不加入日常快速核心测试。

需要本机 Whisper / llama-server、表中对应模型、macOS 语音以及已准备好的源码工具链。`apple` 比较另需可用的 macOS 26 Foundation Models。脚本只访问本机推理服务，不会下载模型或修改 App 配置。新增 GGUF 来源和固定校验值见 [models.json](models.json)；模型文件不提交到 Git。

从仓库根目录构建实际生产提示词/校验器的 Swift bridge：

```bash
mkdir -p .build/model-comparison-20260921 .build/core-tests/module-cache
swiftc -parse-as-library -module-cache-path .build/core-tests/module-cache \
  Sources/FnWhisper/AppConfiguration.swift \
  Sources/FnWhisper/TextSpokenNumberNormalizer.swift \
  Sources/FnWhisper/TextRefinement.swift \
  Sources/FnWhisper/QwenTextRefiner.swift \
  Sources/FnWhisper/AppleFoundationTextRefiner.swift \
  Tests/ModelComparison/main.swift \
  -o .build/model-comparison-20260921/bridge
```

旧 Qwen 模型从默认 Application Support 目录读取；新增候选默认从 `.build/model-comparison-20260921/models/` 读取。若已安装选中的 4B 模型，可让候选目录引用它：

```bash
mkdir -p .build/model-comparison-20260921/models
ln -s "$HOME/Library/Application Support/FnWhisper/Models/Qwen3.5-4B-Q4_K_M.gguf" \
  .build/model-comparison-20260921/models/Qwen3.5-4B-Q4_K_M.gguf
```

存在同名文件时不要覆盖。所有模型实验必须顺序执行，避免 GPU 竞争污染测量。`--tag` 必须使用新的名字；脚本拒绝覆盖现有 JSONL 证据。

```bash
# 构建并使用与 App 相同的 llama / GGML 运行库
./scripts/build-app.sh
python3 scripts/compare-models.py \
  --tag local-repeat --rounds 1,2,3,5 --models qwen35-4b --repeat 3 \
  --server-executable .build/FnWhisper.app/Contents/Resources/bin/llama-server \
  --ggml-lib-dir .build/FnWhisper.app/Contents/Frameworks/LocalInference

# 初筛：按 models.json 准备新候选、并保留原有旧模型后运行
python3 scripts/compare-models.py \
  --tag local-screen --rounds 1,2 \
  --models qwen3-2507,qwen3-original,qwen35-2b,qwen35-4b,gemma4-e2b,apple \
  --server-executable .build/FnWhisper.app/Contents/Resources/bin/llama-server \
  --ggml-lib-dir .build/FnWhisper.app/Contents/Frameworks/LocalInference

# 对照固定 192 token 与动态预算
python3 scripts/compare-models.py --tag local-long --rounds 3 \
  --models current-192,qwen3-2507,qwen35-4b \
  --server-executable .build/FnWhisper.app/Contents/Resources/bin/llama-server \
  --ggml-lib-dir .build/FnWhisper.app/Contents/Frameworks/LocalInference

# 语音：两个 Whisper 模型需已存在于默认模型目录
python3 scripts/compare-whisper.py --tag local-asr --threads 4,6,8
python3 scripts/compare-whisper.py --tag local-noise --threads 8 --noise-snr 10 --repeat 2
python3 scripts/compare-whisper.py --tag local-holdout --threads 8 --holdout --repeat 3
python3 scripts/compare-whisper.py --tag local-holdout-noise --threads 8 --holdout --noise-snr 10 --repeat 3
```

这套日期固定的实验脚本默认使用 Apple Silicon Homebrew `/opt/homebrew/bin`。其他安装位置需调整脚本或文本脚本的 `--server-executable`。输出在 `.build/model-comparison-20260921/`。音频文件包含 SHA-256，系统语音版本变化可能导致重新合成的波形不同。

`--baseline-protocol` 可读取冻结的早期 Qwen 请求；它不冻结历史 Swift 校验器，也不改变 Apple adapter。`apple` 初筛 adapter 保留当时的 Schema；调度试验 `selection` 调用当前实际生产 `AppleFoundationTextRefiner`。

调度比较可向 bridge 输入以下 JSON（路径替换为实际绝对路径），并在启动 bridge 时将 `DYLD_LIBRARY_PATH` / `GGML_BACKEND_PATH` 指向 App 的 `LocalInference` / `LocalInference/backends`。bridge 在每次延迟配置下运行所有 sources，次序固定为 `0, 1.5, 1.5, 0`，退出时关闭自己的 Qwen helper：

```json
{
  "operation": "selection",
  "executable": "/absolute/FnWhisper.app/Contents/Resources/bin/llama-server",
  "model": "/absolute/Qwen3.5-4B-Q4_K_M.gguf",
  "sources": [{"id": "example", "source": "第一检查日志，第二更新配置。"}]
}
```

繁简统一指标使用 bridge 的 `{"operation":"asr-normalize","source":"原始转写"}`，再调用 `compare-whisper.py` 中同一 `normalized` / `distance` 函数。原始 CER 始终保留。不要将已调试过的 50 条语料再次称为未见留出集。
