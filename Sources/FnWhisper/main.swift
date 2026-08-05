import AppKit
import Foundation

if CommandLine.arguments.contains("--diagnose") {
    let configuration = AppConfiguration()
    print(PermissionManager.diagnosticReport)
    print("识别语言：\(configuration.language)")
    print("计算后端：\(configuration.useGPU ? "Metal GPU（失败时自动回退 CPU）" : "CPU")")
    print("CPU 线程：\(configuration.threadCount)")
    print("Whisper CLI：\(configuration.resolveWhisperCLI()?.path ?? "未找到")")
    print("模型：\(configuration.modelURL.path)")
    print(
        "模型状态：\(FileManager.default.fileExists(atPath: configuration.modelURL.path) ? "已找到" : "未找到")"
    )
    let runtimeReady = PermissionManager.missingInputPermissionNames.isEmpty
        && configuration.resolveWhisperCLI() != nil
        && FileManager.default.fileExists(atPath: configuration.modelURL.path)
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

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()

    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
