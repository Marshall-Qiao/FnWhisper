import AppKit
import Foundation

// Dependency readiness is separate from user-granted macOS permissions.
// The installer runs this before stopping/replacing a working installation.
if CommandLine.arguments.contains("--check-runtime") {
    let configuration = AppConfiguration()
    let dependencies: [(String, URL?)] = [
        ("whisper-cli", configuration.resolveWhisperCLI()),
        ("whisper-server", configuration.resolveWhisperServer()),
        ("llama-server", configuration.resolveLlamaServer()),
        ("Whisper 模型", configuration.modelURL),
        ("CT-Punc 模型", configuration.punctuationModelURL),
        ("Qwen 模型", configuration.textModelURL),
    ]
    let missing = dependencies.filter { _, url in
        guard let url,
              let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        else { return true }
        return values.isRegularFile != true || (values.fileSize ?? 0) == 0
    }
    for (name, url) in missing {
        print("未就绪：\(name) — \(url?.path ?? "未找到可执行文件")")
    }
    if missing.isEmpty {
        print("运行依赖和模型文件已就绪；首次使用仍需授予系统权限。")
    }
    exit(missing.isEmpty ? 0 : 2)
}

if CommandLine.arguments.contains("--diagnose") {
    let configuration = AppConfiguration()
    print(PermissionManager.diagnosticReport)
    print("识别语言：\(configuration.language)")
    print("计算后端：\(configuration.useGPU ? "Metal GPU（失败时自动回退 CPU）" : "CPU")")
    print("CPU 线程：\(configuration.threadCount)")
    print("Whisper CLI：\(configuration.resolveWhisperCLI()?.path ?? "未找到")")
    print("Whisper Server：\(configuration.resolveWhisperServer()?.path ?? "未找到")")
    print("模型：\(configuration.modelURL.path)")
    print(
        "模型状态：\(FileManager.default.fileExists(atPath: configuration.modelURL.path) ? "已找到" : "未找到")"
    )
    print("CT-Punc INT8 模型：\(configuration.punctuationModelURL.path)")
    print(
        "标点模型状态：\(FileManager.default.fileExists(atPath: configuration.punctuationModelURL.path) ? "已找到" : "未找到")"
    )
    print("llama-server：\(configuration.resolveLlamaServer()?.path ?? "未找到")")
    print("本地文字模型：\(configuration.textModelURL.path)")
    print(
        "Qwen 模型状态：\(FileManager.default.fileExists(atPath: configuration.textModelURL.path) ? "已找到" : "未找到")"
    )
    print(
        "Qwen 模式：fast/non-thinking，按文本与录音时长动态等待 \(Int(AppConfiguration.minimumTextRefinementTimeout))–\(Int(AppConfiguration.maximumTextRefinementTimeout)) 秒"
    )
    print(
        "Apple Foundation Models：\(AppleFoundationTextRefinerFactory.diagnosticDescription)"
    )
    let runtimeReady = PermissionManager.missingInputPermissionNames.isEmpty
        && configuration.resolveWhisperCLI() != nil
        && configuration.resolveWhisperServer() != nil
        && FileManager.default.fileExists(atPath: configuration.modelURL.path)
        && FileManager.default.fileExists(
            atPath: configuration.punctuationModelURL.path
        )
        && configuration.resolveLlamaServer() != nil
        && FileManager.default.fileExists(
            atPath: configuration.textModelURL.path
        )
    exit(runtimeReady ? 0 : 2)
}

if let probeIndex = CommandLine.arguments.firstIndex(of: "--probe-fn") {
    let duration: TimeInterval
    if CommandLine.arguments.indices.contains(probeIndex + 1),
       let value = TimeInterval(CommandLine.arguments[probeIndex + 1]) {
        duration = min(max(value, 3), 60)
    } else {
        duration = 15
    }

    do {
        let observed = try FnEventProbe().run(duration: duration)
        exit(observed ? 0 : 3)
    } catch {
        FileHandle.standardError.write(
            "Fn 探针失败：\(error.localizedDescription)\n".data(using: .utf8)!
        )
        exit(4)
    }
}

if let insertIndex = CommandLine.arguments.firstIndex(of: "--test-insert") {
    let text: String
    if CommandLine.arguments.indices.contains(insertIndex + 1) {
        text = CommandLine.arguments[insertIndex + 1]
    } else {
        text = "FnWhisper 输入测试"
    }

    MainActor.assumeIsolated {
        let injector = TextInjector()
        Task { @MainActor in
            do {
                let method = try await injector.insert(text)
                print("文字写入成功，方式：\(method.rawValue)")
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    "文字写入失败：\(error.localizedDescription)\n".data(using: .utf8)!
                )
                exit(5)
            }
        }
    }
    RunLoop.main.run()
}

if let punctuationIndex = CommandLine.arguments.firstIndex(
    of: "--test-punctuation"
) {
    guard CommandLine.arguments.indices.contains(punctuationIndex + 1) else {
        FileHandle.standardError.write(
            "用法：FnWhisper --test-punctuation \"待恢复标点的文字\"\n"
                .data(using: .utf8)!
        )
        exit(6)
    }

    let input = CommandLine.arguments[punctuationIndex + 1]
    let configuration = AppConfiguration()
    let restorer = SherpaPunctuationRestorer(
        modelURL: configuration.punctuationModelURL
    )
    Task {
        do {
            let punctuationInput = WhisperOutputParser.punctuationInput(input)
            let restored = try await restorer.restore(punctuationInput)
            print(WhisperOutputParser.finalizePunctuated(restored))
            exit(0)
        } catch {
            FileHandle.standardError.write(
                "标点恢复失败：\(error.localizedDescription)\n".data(using: .utf8)!
            )
            exit(7)
        }
    }
    RunLoop.main.run()
}

if let runtimeIndex = CommandLine.arguments.firstIndex(
    of: "--test-whisper-runtime"
) {
    guard CommandLine.arguments.indices.contains(runtimeIndex + 1) else {
        FileHandle.standardError.write(
            "用法：FnWhisper --test-whisper-runtime /absolute/path/audio.wav [1-5]\n"
                .data(using: .utf8)!
        )
        exit(8)
    }

    let audioURL = URL(
        fileURLWithPath: CommandLine.arguments[runtimeIndex + 1]
    )
    let repeatCount: Int
    if CommandLine.arguments.indices.contains(runtimeIndex + 2),
       let requested = Int(CommandLine.arguments[runtimeIndex + 2]) {
        repeatCount = min(max(requested, 1), 5)
    } else {
        repeatCount = 1
    }
    let configuration = AppConfiguration()
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        FileHandle.standardError.write(
            "未找到音频：\(audioURL.path)\n".data(using: .utf8)!
        )
        exit(9)
    }
    guard let cliURL = configuration.resolveWhisperCLI() else {
        FileHandle.standardError.write("未找到 whisper-cli。\n".data(using: .utf8)!)
        exit(10)
    }

    let cliTranscriber = WhisperTranscriber(
        executableURL: cliURL,
        modelURL: configuration.modelURL,
        language: configuration.language,
        threadCount: configuration.threadCount,
        useGPU: configuration.useGPU
    )
    let runtime = WhisperRuntime(
        cliTranscriber: cliTranscriber,
        serverExecutableURL: configuration.resolveWhisperServer(),
        modelURL: configuration.modelURL,
        language: configuration.language,
        threadCount: configuration.threadCount,
        useGPU: configuration.useGPU
    )
    Task {
        do {
            var lastResult: WhisperRuntimeResult?
            for attempt in 1...repeatCount {
                let startedAt = Date()
                let result = try await runtime.transcribe(audioURL: audioURL)
                lastResult = result
                let elapsed = Date().timeIntervalSince(startedAt)
                let warning = result.warning.map { "；\($0)" } ?? ""
                FileHandle.standardError.write(
                    "第 \(attempt) 次：\(result.backend.rawValue)；耗时：\(String(format: "%.3f", elapsed)) 秒\(warning)\n"
                        .data(using: .utf8)!
                )
            }
            print(
                lastResult?.rawText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
            )
            runtime.shutdown()
            exit(0)
        } catch {
            runtime.shutdown()
            FileHandle.standardError.write(
                "Whisper runtime 测试失败：\(error.localizedDescription)\n"
                    .data(using: .utf8)!
            )
            exit(11)
        }
    }
    RunLoop.main.run()
}

if let refinementIndex = CommandLine.arguments.firstIndex(
    of: "--test-text-refinement"
) {
    guard CommandLine.arguments.indices.contains(refinementIndex + 1) else {
        FileHandle.standardError.write(
            "用法：FnWhisper --test-text-refinement \"待整理文字\"\n"
                .data(using: .utf8)!
        )
        exit(12)
    }

    let input = CommandLine.arguments[refinementIndex + 1]
    let configuration = AppConfiguration()
    let qwen: QwenTextRefiner?
    if let llamaServerURL = configuration.resolveLlamaServer(),
       FileManager.default.fileExists(atPath: configuration.textModelURL.path) {
        qwen = QwenTextRefiner(
            executableURL: llamaServerURL,
            modelURL: configuration.textModelURL
        )
    } else {
        qwen = nil
    }
    let apple = AppleFoundationTextRefinerFactory.makeIfAvailable()
    let refiner = ParallelTextRefiner(
        qwen: qwen,
        apple: apple,
        failureReporter: { provider, error in
            FileHandle.standardError.write(
                "\(provider) 整理未采用：\(error.localizedDescription)\n"
                    .data(using: .utf8)!
            )
        }
    )

    Task {
        if let qwen {
            do {
                let warmupStartedAt = Date()
                try await qwen.prepare()
                let elapsed = Date().timeIntervalSince(warmupStartedAt)
                FileHandle.standardError.write(
                    "Qwen 预热完成：\(String(format: "%.3f", elapsed)) 秒\n"
                        .data(using: .utf8)!
                )
            } catch {
                FileHandle.standardError.write(
                    "Qwen 预热失败，将测试 Apple 回退：\(error.localizedDescription)\n"
                        .data(using: .utf8)!
                )
            }
        }

        do {
            let startedAt = Date()
            let result = try await refiner.refine(input)
            let elapsed = Date().timeIntervalSince(startedAt)
            FileHandle.standardError.write(
                "文字整理：\(result.provider.rawValue)；耗时：\(String(format: "%.3f", elapsed)) 秒\n"
                    .data(using: .utf8)!
            )
            print(result.text)
            qwen?.shutdown()
            exit(0)
        } catch {
            qwen?.shutdown()
            FileHandle.standardError.write(
                "文字整理测试失败：\(error.localizedDescription)\n"
                    .data(using: .utf8)!
            )
            exit(13)
        }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
