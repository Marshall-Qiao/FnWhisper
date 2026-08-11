import AVFoundation
import Foundation

private var failureCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard !condition() else {
        return
    }
    failureCount += 1
    FileHandle.standardError.write(
        "FAIL \(file):\(line) — \(description)\n".data(using: .utf8)!
    )
}

private func testShortFnPress() {
    var machine = FnPressStateMachine()

    expect(
        machine.handle(fnIsPressed: true) == .scheduleActivation,
        "Fn 按下后应进入等待激活状态"
    )
    expect(machine.state == .armed, "状态应为 armed")
    expect(
        machine.handle(fnIsPressed: false) == .cancelActivation,
        "短按松开应取消激活"
    )
    expect(machine.state == .idle, "取消后状态应回到 idle")
    expect(
        machine.activationDelayElapsed() == nil,
        "取消后的旧计时器不能启动录音"
    )
}

private func testLongFnPress() {
    var machine = FnPressStateMachine()

    expect(
        machine.handle(fnIsPressed: true) == .scheduleActivation,
        "Fn 按下后应安排激活"
    )
    expect(
        machine.activationDelayElapsed() == .startRecording,
        "超过阈值应开始录音"
    )
    expect(machine.state == .recording, "状态应为 recording")
    expect(
        machine.handle(fnIsPressed: false) == .stopRecording,
        "长按松开应停止录音"
    )
    expect(machine.state == .idle, "停止后状态应回到 idle")
}

private func testRepeatedModifierEvents() {
    var machine = FnPressStateMachine()

    _ = machine.handle(fnIsPressed: true)
    expect(
        machine.handle(fnIsPressed: true) == nil,
        "Fn 保持按下时的重复 flagsChanged 事件应被忽略"
    )
    _ = machine.activationDelayElapsed()
    expect(
        machine.handle(fnIsPressed: true) == nil,
        "录音期间的重复 Fn 事件应被忽略"
    )
}

private func testFnEventConsumptionPolicy() {
    expect(
        FnEventConsumptionPolicy.shouldConsume(
            keyCode: FnEventConsumptionPolicy.functionKeyCode
        ),
        "Fn 按下和松开事件都应由应用独占，避免系统动作抢占"
    )
    expect(
        FnEventConsumptionPolicy.shouldConsume(
            keyCode: FnEventConsumptionPolicy.functionKeyCode
        ),
        "录音期间的 Fn 事件应继续被应用拦截"
    )
    expect(
        !FnEventConsumptionPolicy.shouldConsume(
            keyCode: 56
        ),
        "Fn 按住期间的 Shift 等其他修饰键事件不应被拦截"
    )
}

private func testWhisperOutputParsing() {
    expect(
        WhisperOutputParser.parse("  你好。  \n  This is a test. \n")
            == "你好。 This is a test.",
        "应清理片段空白并用自然间隔合并中英文"
    )
    expect(
        WhisperOutputParser.parse("今天\n天气很好") == "今天，天气很好。",
        "中文分段应恢复为自然停顿"
    )
    expect(
        WhisperOutputParser.parse("[BLANK_AUDIO]\n [Silence] \n实际文字")
            == "实际文字。",
        "应丢弃已知的静音标记"
    )
    expect(
        WhisperOutputParser.parse("你好,这是断句测试,请继续")
            == "你好，这是断句测试，请继续。",
        "中文上下文中的英文标点应规范化并补全句末标点"
    )
    expect(
        WhisperOutputParser.parse("First sentence\nSecond sentence")
            == "First sentence Second sentence",
        "英文分段应保留单词间隔但不能擅自修改命令或代码"
    )
    expect(
        WhisperOutputParser.parse("git status") == "git status",
        "纯英文终端命令不能被自动添加句号"
    )
    expect(
        WhisperOutputParser.parse(" \n\n ").isEmpty,
        "空识别结果应保持为空"
    )
}

private func testBilingualOutputPolicy() {
    expect(
        BilingualOutputPolicy.containsOnlyChineseAndEnglish(
            "明天 schedule a GitHub meeting at 10:30。"
        ),
        "中英文混合结果应被接受"
    )
    expect(
        BilingualOutputPolicy.containsOnlyChineseAndEnglish(
            "Hello, world! 你好，世界！"
        ),
        "纯中英文和常见标点应被接受"
    )
    expect(
        !BilingualOutputPolicy.containsOnlyChineseAndEnglish("こんにちは"),
        "日文假名结果应被拒绝"
    )
    expect(
        !BilingualOutputPolicy.containsOnlyChineseAndEnglish("Привет"),
        "西里尔字母结果应被拒绝"
    )
}

private func testLanguageNormalization() {
    expect(
        AppConfiguration.normalizedLanguage(nil) == "auto",
        "默认应自动选择中文或英文"
    )
    expect(
        AppConfiguration.normalizedLanguage("auto") == "auto",
        "auto 配置应保持中英自动检测模式"
    )
    expect(
        AppConfiguration.normalizedLanguage("zh") == "zh",
        "中文配置应保持 zh"
    )
    expect(
        AppConfiguration.normalizedLanguage("en") == "en",
        "显式英文配置应保持 en"
    )
    expect(
        AppConfiguration.normalizedLanguage("fr") == "auto",
        "不支持的语言配置应回退到中英自动检测模式"
    )
    expect(
        AppConfiguration.defaultModelFilename
            == "ggml-large-v3-q5_0.bin",
        "默认模型应为 large-v3-q5_0"
    )
    expect(
        AppConfiguration.normalizedThreadCount(nil, processorCount: 12) == 8,
        "12 核机器默认应使用实测最优的 8 个线程"
    )
    expect(
        AppConfiguration.normalizedThreadCount(20, processorCount: 12) == 12,
        "线程数不能超过可用处理器数量"
    )
    expect(
        AppConfiguration.normalizedThreadCount(0, processorCount: 12) == 1,
        "线程数至少为 1"
    )
    expect(AppConfiguration.parseBoolean("true") == true, "true 应启用 GPU")
    expect(AppConfiguration.parseBoolean("0") == false, "0 应关闭 GPU")
    expect(AppConfiguration.parseBoolean("invalid") == nil, "无效布尔值应被忽略")
}

private func testWhisperCommandArguments() {
    let audioURL = URL(fileURLWithPath: "/tmp/input.wav")
    let outputURL = URL(fileURLWithPath: "/tmp/output")
    let modelURL = URL(fileURLWithPath: "/tmp/model.bin")
    let gpuArguments = WhisperTranscriber.commandArguments(
        audioURL: audioURL,
        outputBase: outputURL,
        modelURL: modelURL,
        language: "auto",
        threadCount: 8,
        useGPU: true
    )
    let cpuArguments = WhisperTranscriber.commandArguments(
        audioURL: audioURL,
        outputBase: outputURL,
        modelURL: modelURL,
        language: "auto",
        threadCount: 8,
        useGPU: false
    )

    expect(!gpuArguments.contains("--no-gpu"), "Metal 模式不应传入 --no-gpu")
    expect(cpuArguments.first == "--no-gpu", "CPU 模式应显式传入 --no-gpu")
    expect(gpuArguments.contains("8"), "命令应保留线程数配置")
}

private func testAudioConversion() {
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let sourceURL = temporaryDirectory
        .appendingPathComponent("FnWhisper-audio-test-\(UUID().uuidString)")
        .appendingPathExtension("caf")
    let destinationURL = temporaryDirectory
        .appendingPathComponent("FnWhisper-audio-test-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: destinationURL)
    }

    var stage = "创建测试音频"
    do {
        let sourceSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var sourceFile: AVAudioFile? = try AVAudioFile(
            forWriting: sourceURL,
            settings: sourceSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let processingFormat = sourceFile?.processingFormat,
              let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: 24_000
        ), let channels = buffer.floatChannelData else {
            expect(false, "应能创建测试音频缓冲区")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000)) * 0.2
            channels[0][frame] = sample
            channels[1][frame] = sample
        }

        try sourceFile?.write(from: buffer)
        sourceFile = nil
        stage = "转换音频"
        try AudioRecorder.convertToWhisperWAV(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        stage = "读取转换结果"
        let outputFile = try AVAudioFile(forReading: destinationURL)
        expect(
            outputFile.processingFormat.sampleRate == 16_000,
            "Whisper WAV 应为 16 kHz"
        )
        expect(
            outputFile.processingFormat.channelCount == 1,
            "Whisper WAV 应为单声道"
        )
        expect(
            outputFile.fileFormat.commonFormat == .pcmFormatInt16,
            "Whisper WAV 文件应为 16-bit PCM"
        )
        expect(outputFile.length > 0, "转换后的 Whisper WAV 不应为空")
    } catch {
        expect(false, "\(stage)不应失败：\(error.localizedDescription)")
    }
}

testShortFnPress()
testLongFnPress()
testRepeatedModifierEvents()
testFnEventConsumptionPolicy()
testWhisperOutputParsing()
testBilingualOutputPolicy()
testLanguageNormalization()
testWhisperCommandArguments()
testAudioConversion()

if failureCount > 0 {
    FileHandle.standardError.write(
        "\(failureCount) 个核心测试失败。\n".data(using: .utf8)!
    )
    exit(1)
}

print("核心测试通过：Fn 状态机、冲突拦截、音频转换与 Whisper 输出解析。")
