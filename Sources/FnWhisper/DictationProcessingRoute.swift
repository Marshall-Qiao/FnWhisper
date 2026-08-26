enum DictationPunctuationProcessor: String, Equatable {
    case ctPunc = "CT-Punc（本地）"
    case basic = "基础断句"
}

enum DictationTextProcessing: Equatable {
    case refined(DictationPunctuationProcessor, TextRefinementProvider)
    case noRefiner(DictationPunctuationProcessor)
    case refinementFailed(DictationPunctuationProcessor)

    var indicatorText: String {
        switch self {
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
        case let .refined(_, provider):
            return provider.rawValue
        case .noRefiner:
            return "未使用 Qwen/Apple"
        case .refinementFailed:
            return "Qwen/Apple 未采用"
        }
    }

    var completionText: String {
        switch self {
        case let .refined(_, provider):
            switch provider {
            case .qwen:
                return "最终由 Qwen3-4B 本地模型整理"
            case .apple:
                return "最终由 Apple 本地模型整理"
            }
        case .noRefiner:
            return "由 Whisper 本地生成"
        case .refinementFailed:
            return "已保留 Whisper 本地结果"
        }
    }

    var pathComponents: [String] {
        switch self {
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

    var completionText: String {
        textProcessing.completionText
    }

    var displayText: String {
        (["Whisper \(whisperBackend.rawValue)"] + textProcessing.pathComponents)
            .joined(separator: " → ")
    }
}
