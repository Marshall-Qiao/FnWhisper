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

    enum Style: Equatable {
        case proseBasic
        case commandOrCode
    }

    static func parse(
        _ rawOutput: String,
        style: Style = .proseBasic
    ) -> String {
        let merged = merge(
            segments(in: rawOutput),
            inferCJKPause: style == .proseBasic
        )

        switch style {
        case .proseBasic:
            return finishSentence(normalizePunctuationStyle(in: merged))
        case .commandOrCode:
            return merged
        }
    }

    static func punctuationInput(_ rawOutput: String) -> String {
        let merged = merge(
            segments(in: rawOutput),
            inferCJKPause: false
        )
        return stripRestorablePunctuation(from: merged)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func finalizePunctuated(_ punctuatedText: String) -> String {
        let merged = merge(
            segments(in: punctuatedText),
            inferCJKPause: false
        )
        let normalized = normalizePunctuationStyle(in: merged)
        return finishSentence(normalizeMixedScriptSpacing(in: normalized))
    }

    private static func segments(in rawOutput: String) -> [String] {
        rawOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !ignoredMarkers.contains($0.lowercased()) }
    }

    private static func merge(
        _ segments: [String],
        inferCJKPause: Bool
    ) -> String {
        segments.reduce(into: "") { result, segment in
            result.append(
                separator(
                    between: result,
                    and: segment,
                    inferCJKPause: inferCJKPause
                )
            )
            result.append(segment)
        }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func separator(
        between existingText: String,
        and nextSegment: String,
        inferCJKPause: Bool
    ) -> String {
        guard let previous = existingText.last,
              let next = nextSegment.first
        else {
            return ""
        }
        if next.isPunctuation || previous.isWhitespace || next.isWhitespace {
            return ""
        }
        if previous.isPunctuation {
            let previousContent = existingText.dropLast().last
            return previousContent?.isCJK == true && next.isCJK ? "" : " "
        }
        if previous.isCJK && next.isCJK {
            return inferCJKPause ? "，" : ""
        }
        return " "
    }

    private static func stripRestorablePunctuation(from text: String) -> String {
        let characters = Array(text)
        return characters.indices.reduce(into: "") { result, index in
            let character = characters[index]
            if ",;!?，；！？、。…".contains(character) {
                return
            }
            if character == "." {
                let previous = index > characters.startIndex
                    ? characters[characters.index(before: index)]
                    : nil
                let nextIndex = characters.index(after: index)
                let next = nextIndex < characters.endIndex
                    ? characters[nextIndex]
                    : nil
                if previous?.isBasicLatinLetterOrDigit == true,
                   next?.isBasicLatinLetterOrDigit == true {
                    result.append(character)
                }
                return
            }
            result.append(character)
        }
    }

    private static func normalizePunctuationStyle(in text: String) -> String {
        let characters = Array(text)
        return characters.indices.reduce(into: "") { result, index in
            let character = characters[index]
            let previous = index > characters.startIndex
                ? characters[characters.index(before: index)]
                : nil
            let nextIndex = characters.index(after: index)
            let next = nextIndex < characters.endIndex
                ? characters[nextIndex]
                : nil

            switch character {
            case "," where previous?.isCJK == true || next?.isCJK == true:
                result.append("，")
            case ";" where previous?.isCJK == true || next?.isCJK == true:
                result.append("；")
            case "." where previous?.isCJK == true:
                result.append("。")
            case "?" where previous?.isCJK == true:
                result.append("？")
            case "!" where previous?.isCJK == true:
                result.append("！")
            case "，" where previous?.isCJK != true && next?.isCJK != true:
                result.append(",")
            case "；" where previous?.isCJK != true && next?.isCJK != true:
                result.append(";")
            case "。" where previous?.isCJK != true:
                result.append(".")
            case "？" where previous?.isCJK != true:
                result.append("?")
            case "！" where previous?.isCJK != true:
                result.append("!")
            default:
                result.append(character)
            }
        }
    }

    private static func normalizeMixedScriptSpacing(in text: String) -> String {
        let characters = Array(text)
        return characters.indices.reduce(into: "") { result, index in
            let character = characters[index]
            if let previous = result.last,
               !previous.isWhitespace,
               ((previous.isCJK && character.isBasicLatinLetter)
                   || (previous.isBasicLatinLetter && character.isCJK)) {
                result.append(" ")
            }
            result.append(character)

            let nextIndex = characters.index(after: index)
            guard nextIndex < characters.endIndex,
                  !characters[nextIndex].isWhitespace,
                  ".,;:!?".contains(character),
                  let previous = index > characters.startIndex
                    ? characters[characters.index(before: index)]
                    : nil,
                  previous.isBasicLatinLetterOrDigit,
                  (characters[nextIndex].isBasicLatinLetterOrDigit
                    || characters[nextIndex].isCJK),
                  !(previous.isASCIIDigit && characters[nextIndex].isASCIIDigit),
                  !isProtectedInlinePeriod(
                    character,
                    in: characters,
                    at: index
                  )
            else {
                return
            }
            result.append(" ")
        }
    }

    private static func isProtectedInlinePeriod(
        _ punctuation: Character,
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard punctuation == "." else {
            return false
        }
        var suffix = ""
        var cursor = characters.index(after: index)
        while cursor < characters.endIndex,
              characters[cursor].isBasicLatinLetter {
            suffix.append(characters[cursor])
            cursor = characters.index(after: cursor)
        }
        return [
            "ai", "app", "ca", "cn", "co", "com", "dev", "edu", "gov",
            "io", "js", "json", "md", "me", "net", "org", "pdf", "png",
            "swift", "ts", "txt", "xyz",
        ].contains(suffix.lowercased())
    }

    private static func finishSentence(_ text: String) -> String {
        guard let last = text.last else {
            return text
        }
        if last.isSentenceTerminator {
            return text
        }
        if last.isClauseTerminator {
            let contentBeforeTerminator = text.dropLast().last
            guard contentBeforeTerminator?.isCJK == true else {
                return text
            }
            var result = text
            result.removeLast()
            result.append("。")
            return result
        }
        if last.isPunctuation {
            return text
        }
        return last.isCJK ? text + "。" : text
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

    var isSentenceTerminator: Bool {
        ".!?。！？…".contains(self)
    }

    var isClauseTerminator: Bool {
        ",;，；、".contains(self)
    }

    var isBasicLatinLetterOrDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
                || (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
        }
    }

    var isBasicLatinLetter: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value)
        }
    }

    var isASCIIDigit: Bool {
        unicodeScalars.count == 1 && unicodeScalars.allSatisfy { scalar in
            (0x30...0x39).contains(scalar.value)
        }
    }
}

struct WhisperCLIRawResult {
    let rawText: String
    let usedGPU: Bool
    let warning: String?
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
        let rawResult = try transcribeRaw(audioURL: audioURL)
        let result = WhisperOutputParser.parse(rawResult.rawText)
        guard !result.isEmpty else {
            throw WhisperTranscriberError.emptyResult
        }
        guard BilingualOutputPolicy.containsOnlyChineseAndEnglish(result) else {
            throw WhisperTranscriberError.unsupportedLanguage
        }
        return result
    }

    func transcribeRaw(audioURL: URL) throws -> WhisperCLIRawResult {
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

        let usedGPU: Bool
        var warning: String?
        if useGPU {
            do {
                try runWhisper(
                    audioURL: audioURL,
                    outputBase: outputBase,
                    useGPU: true
                )
                usedGPU = true
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
                    usedGPU = false
                    warning = "Metal 识别失败，已使用 CPU 兼容模式。"
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
            usedGPU = false
        }

        let rawOutput = try String(contentsOf: outputTextURL, encoding: .utf8)
        return WhisperCLIRawResult(
            rawText: rawOutput,
            usedGPU: usedGPU,
            warning: warning
        )
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
