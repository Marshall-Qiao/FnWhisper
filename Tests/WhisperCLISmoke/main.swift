import Foundation

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(
        "用法：FnWhisperCLISmoke <whisper-cli> <model> <audio.wav>\n"
            .data(using: .utf8)!
    )
    exit(2)
}

let transcriber = WhisperTranscriber(
    executableURL: URL(fileURLWithPath: CommandLine.arguments[1]),
    modelURL: URL(fileURLWithPath: CommandLine.arguments[2]),
    language: "auto",
    threadCount: min(
        8,
        max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    ),
    useGPU: true
)

do {
    let text = try transcriber.transcribe(
        audioURL: URL(fileURLWithPath: CommandLine.arguments[3])
    )
    print(text)
} catch {
    FileHandle.standardError.write(
        "Whisper 冒烟测试失败：\(error.localizedDescription)\n"
            .data(using: .utf8)!
    )
    exit(1)
}
