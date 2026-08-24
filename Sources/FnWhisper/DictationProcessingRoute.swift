enum DictationPunctuationProcessor: String, Equatable {
    case ctPunc = "CT-Punc（本地）"
    case basic = "基础断句"
}

enum DictationTextProcessing: Equatable {
    case commandOrCode
    case refined(DictationPunctuationProcessor, TextRefinementProvider)
    case noRefiner(DictationPunctuationProcessor)
    case refinementFailed(DictationPunctuationProcessor)

    var indicatorText: String {
        switch self {
        case .commandOrCode:
            return "⌘"
        case let .refined(_, provider):
            switch provider {
            case .qwen:
                return "Ⓠ"
            case .apple:
                return "Ⓐ"
            }
        case .noRefiner, .refinementFailed:
            return "Ⓦ"
        }
    }

    var finalProcessorText: String {
        switch self {
        case .commandOrCode:
            return "命令/代码直出"
        case let .refined(_, provider):
            return provider.rawValue
        case .noRefiner:
            return "未使用 Qwen/Apple"
        case .refinementFailed:
            return "Qwen/Apple 未采用"
        }
    }

    var pathComponents: [String] {
        switch self {
        case .commandOrCode:
            return ["命令/代码直出"]
        case let .refined(punctuation, provider):
            return [punctuation.rawValue, provider.rawValue]
        case let .noRefiner(punctuation):
            return [punctuation.rawValue, "未使用文字整理模型"]
        case let .refinementFailed(punctuation):
            return [punctuation.rawValue, "整理失败，保留规范化转写"]
        }
    }
}

struct DictationProcessingRoute: Equatable {
    let whisperBackend: WhisperBackend
    let textProcessing: DictationTextProcessing

    var finalProcessorText: String {
        textProcessing.finalProcessorText
    }

    var indicatorText: String {
        textProcessing.indicatorText
    }

    var displayText: String {
        (["Whisper \(whisperBackend.rawValue)"] + textProcessing.pathComponents)
            .joined(separator: " → ")
    }
}
