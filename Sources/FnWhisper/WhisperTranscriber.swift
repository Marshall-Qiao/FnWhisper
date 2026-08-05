import Foundation

enum WhisperTranscriberError: LocalizedError {
    case executableMissing
    case modelMissing(URL)
    case processFailed(Int32, String)
    case emptyResult
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "没有找到 whisper-cli。请先运行 scripts/setup-whisper.sh。"
        case let .modelMissing(url):
            return "没有找到 Whisper 模型：\(url.path)。请先运行 scripts/setup-whisper.sh。"
        case let .processFailed(code, message):
            return "Whisper 识别失败（退出码 \(code)）：\(message)"
        case .emptyResult:
            return "Whisper 没有识别到可输入的文字。"
        case .unsupportedLanguage:
            return "检测到中文和英文之外的语言，本次结果未输入。"
        }
    }
}

enum BilingualOutputPolicy {
    static func containsOnlyChineseAndEnglish(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            guard CharacterSet.letters.contains(scalar) else {
                return true
            }
            return isBasicLatinLetter(scalar) || isCJK(scalar)
        }
    }

    private static func isBasicLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value)
            || (0x61...0x7A).contains(scalar.value)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }
}

enum WhisperOutputParser {
    private static let ignoredMarkers: Set<String> = [
        "[blank_audio]",
        "[silence]",
        "(silence)",
        "[music]",
    ]

    static func parse(_ rawOutput: String) -> String {
        let segments = rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !ignoredMarkers.contains($0.lowercased()) }

        return segments.reduce(into: "") { result, segment in
            if needsSeparator(between: result, and: segment) {
                result.append(" ")
            }
            result.append(segment)
        }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func needsSeparator(
        between existingText: String,
        and nextSegment: String
    ) -> Bool {
        guard let previous = existingText.last,
              let next = nextSegment.first
        else {
            return false
        }
        if next.isPunctuation || previous.isWhitespace || next.isWhitespace {
            return false
        }
        return !(previous.isCJK && next.isCJK)
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0x3040...0x30FF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }
}

struct WhisperTranscriber {
    let executableURL: URL
    let modelURL: URL
    let language: String
    let threadCount: Int
    let useGPU: Bool

    init(
        executableURL: URL,
        modelURL: URL,
        language: String,
        threadCount: Int = 4,
        useGPU: Bool = true
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.language = language
        self.threadCount = max(1, threadCount)
        self.useGPU = useGPU
    }

    func transcribe(audioURL: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw WhisperTranscriberError.executableMissing
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperTranscriberError.modelMissing(modelURL)
        }

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("FnWhisper-output-\(UUID().uuidString)")
        let outputTextURL = outputBase.appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: outputTextURL)
        }

        if useGPU {
            do {
                try runWhisper(
                    audioURL: audioURL,
                    outputBase: outputBase,
                    useGPU: true
                )
            } catch let gpuError as WhisperTranscriberError {
                guard case .processFailed = gpuError else {
                    throw gpuError
                }

                try? FileManager.default.removeItem(at: outputTextURL)
                NSLog(
                    "FnWhisper: Metal failed; retrying on CPU. %@",
                    gpuError.localizedDescription
                )
                do {
                    try runWhisper(
                        audioURL: audioURL,
                        outputBase: outputBase,
                        useGPU: false
                    )
                } catch let cpuError as WhisperTranscriberError {
                    guard case let .processFailed(code, message) = cpuError else {
                        throw cpuError
                    }
                    throw WhisperTranscriberError.processFailed(
                        code,
                        "Metal 失败后 CPU 回退也失败。\nMetal：\(gpuError.localizedDescription)\nCPU：\(message)"
                    )
                }
            }
        } else {
            try runWhisper(
                audioURL: audioURL,
                outputBase: outputBase,
                useGPU: false
            )
        }

        let rawOutput = try String(contentsOf: outputTextURL, encoding: .utf8)
        let result = WhisperOutputParser.parse(rawOutput)
        guard !result.isEmpty else {
            throw WhisperTranscriberError.emptyResult
        }
        guard BilingualOutputPolicy.containsOnlyChineseAndEnglish(result) else {
            throw WhisperTranscriberError.unsupportedLanguage
        }
        return result
    }

    static func commandArguments(
        audioURL: URL,
        outputBase: URL,
        modelURL: URL,
        language: String,
        threadCount: Int,
        useGPU: Bool
    ) -> [String] {
        var arguments = [
            "--threads", String(threadCount),
            "--model", modelURL.path,
            "--file", audioURL.path,
            "--language", language,
            "--output-txt",
            "--output-file", outputBase.path,
            "--no-timestamps",
            "--no-prints",
        ]
        if !useGPU {
            arguments.insert("--no-gpu", at: 0)
        }
        return arguments
    }

    private func runWhisper(
        audioURL: URL,
        outputBase: URL,
        useGPU: Bool
    ) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = Self.commandArguments(
            audioURL: audioURL,
            outputBase: outputBase,
            modelURL: modelURL,
            language: language,
            threadCount: threadCount,
            useGPU: useGPU
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let diagnosticData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let diagnostic = String(data: diagnosticData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard process.terminationStatus == 0 else {
            throw WhisperTranscriberError.processFailed(
                process.terminationStatus,
                diagnostic
            )
        }
    }
}
