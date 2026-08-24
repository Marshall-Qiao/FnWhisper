import Foundation
import os

enum DictationPhase: Equatable {
    case waitingForPermissions(String)
    case idle
    case preparing
    case recording
    case transcribing
    case completed(preview: String, route: DictationProcessingRoute)
    case failed(String)

    var statusText: String {
        switch self {
        case let .waitingForPermissions(names):
            return "等待权限：\(names)"
        case .idle:
            return "就绪：长按 Fn 说话"
        case .preparing:
            return "正在准备麦克风…"
        case .recording:
            return "正在录音：松开 Fn 完成"
        case .transcribing:
            return "正在本地识别、整理并输入…"
        case let .completed(_, route):
            return route.indicatorText
        case let .failed(message):
            return "错误：\(message)"
        }
    }
}

@MainActor
final class DictationCoordinator {
    var onPhaseChange: ((DictationPhase) -> Void)?

    private let recorder: AudioRecorder
    private let whisperRuntime: WhisperRuntime
    private let punctuationRestorer: SherpaPunctuationRestorer
    private let textRefiner: TextRefining?
    private let textInjector: TextInjector
    private let logger = Logger(
        subsystem: "com.marshall.fnwhisper",
        category: "DictationCoordinator"
    )
    private var fnIsStillHeld = false
    private var insertionTarget: TextInsertionTarget?
    private(set) var phase: DictationPhase = .idle {
        didSet {
            onPhaseChange?(phase)
        }
    }

    init(
        recorder: AudioRecorder,
        whisperRuntime: WhisperRuntime,
        punctuationRestorer: SherpaPunctuationRestorer,
        textRefiner: TextRefining?,
        textInjector: TextInjector
    ) {
        self.recorder = recorder
        self.whisperRuntime = whisperRuntime
        self.punctuationRestorer = punctuationRestorer
        self.textRefiner = textRefiner
        self.textInjector = textInjector
    }

    func beginDictation() {
        guard phase == .idle || isFailed else {
            return
        }

        fnIsStillHeld = true
        insertionTarget = textInjector.captureFocusedTarget()
        logger.notice(
            "Dictation requested; focused target captured=\(self.insertionTarget != nil, privacy: .public)"
        )
        guard insertionTarget != nil else {
            fnIsStillHeld = false
            fail(TextInjectorError.noFocusedTextInput)
            return
        }
        phase = .preparing

        Task { [weak self] in
            guard let self else {
                return
            }

            let granted = await recorder.requestPermission()
            guard granted else {
                fail(AudioRecorderError.microphonePermissionDenied)
                return
            }
            guard fnIsStillHeld else {
                phase = .idle
                return
            }

            do {
                try recorder.start()
                if fnIsStillHeld {
                    logger.notice("Audio recording started")
                    phase = .recording
                } else {
                    try await finishRecording()
                }
            } catch {
                fail(error)
            }
        }
    }

    func endDictation() {
        fnIsStillHeld = false
        guard phase == .recording else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await finishRecording()
            } catch {
                fail(error)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    private func finishRecording() async throws {
        phase = .transcribing
        let audioURL = try recorder.stop()
        let fileSize = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        logger.notice("Audio recording stopped; wavBytes=\(fileSize, privacy: .public)")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let inputContext = insertionTarget?.inputContext ?? .prose
        let whisperResult = try await whisperRuntime.transcribe(audioURL: audioURL)
        var warnings = [whisperResult.warning].compactMap { $0 }
        var transcription: String
        let textProcessing: DictationTextProcessing
        switch inputContext {
        case .commandOrCode:
            transcription = WhisperOutputParser.parse(
                whisperResult.rawText,
                style: .commandOrCode
            )
            textProcessing = .commandOrCode
        case .prose:
            let punctuationInput = WhisperOutputParser.punctuationInput(
                whisperResult.rawText
            )
            guard !punctuationInput.isEmpty else {
                throw WhisperTranscriberError.emptyResult
            }
            let punctuationProcessor: DictationPunctuationProcessor
            do {
                let punctuated = try await punctuationRestorer.restore(
                    punctuationInput
                )
                transcription = WhisperOutputParser.finalizePunctuated(
                    punctuated
                )
                punctuationProcessor = .ctPunc
            } catch {
                logger.error(
                    "CT-Punc failed; using basic punctuation: \(error.localizedDescription, privacy: .public)"
                )
                transcription = WhisperOutputParser.parse(whisperResult.rawText)
                warnings.append("智能标点不可用，已使用基础断句。")
                punctuationProcessor = .basic
            }

            transcription = TextTranscriptionNormalizer.normalize(transcription)
            if let textRefiner {
                do {
                    let result = try await textRefiner.refine(transcription)
                    transcription = result.text
                    textProcessing = .refined(
                        punctuationProcessor,
                        result.provider
                    )
                    logger.notice(
                        "Text refinement completed; provider=\(result.provider.rawValue, privacy: .public); characters=\(transcription.count, privacy: .public)"
                    )
                } catch {
                    logger.error(
                        "Text refinement failed; preserving punctuation result: \(error.localizedDescription, privacy: .public)"
                    )
                    warnings.append("文字整理不可用，已保留规范化转写。")
                    textProcessing = .refinementFailed(punctuationProcessor)
                }
            } else {
                textProcessing = .noRefiner(punctuationProcessor)
            }
        }

        guard !transcription.isEmpty else {
            throw WhisperTranscriberError.emptyResult
        }
        guard BilingualOutputPolicy.containsOnlyChineseAndEnglish(transcription) else {
            throw WhisperTranscriberError.unsupportedLanguage
        }
        logger.notice(
            "Whisper transcription completed; backend=\(whisperResult.backend.rawValue, privacy: .public); characters=\(transcription.count, privacy: .public)"
        )
        let method = try await textInjector.insert(
            transcription,
            target: insertionTarget
        )
        insertionTarget = nil
        logger.notice(
            "Text insertion completed; method=\(method.rawValue, privacy: .public)"
        )

        var preview = String(transcription.prefix(60))
        if !warnings.isEmpty {
            preview += " · " + warnings.joined(separator: " ")
        }
        let route = DictationProcessingRoute(
            whisperBackend: whisperResult.backend,
            textProcessing: textProcessing
        )
        logger.notice(
            "Dictation processing route=\(route.displayText, privacy: .public)"
        )
        phase = .completed(preview: preview, route: route)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard case .completed = phase else {
            return
        }
        phase = .idle
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        insertionTarget = nil
        logger.error("Dictation failed: \(message, privacy: .public)")
        phase = .failed(message)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isFailed else {
                return
            }
            self.phase = .idle
        }
    }
}
