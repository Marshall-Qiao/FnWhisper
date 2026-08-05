import Foundation
import os

enum DictationPhase: Equatable {
    case waitingForPermissions(String)
    case idle
    case preparing
    case recording
    case transcribing
    case completed(String)
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
            return "正在本地识别并输入…"
        case let .completed(preview):
            return "已输入：\(preview)"
        case let .failed(message):
            return "错误：\(message)"
        }
    }
}

@MainActor
final class DictationCoordinator {
    var onPhaseChange: ((DictationPhase) -> Void)?

    private let recorder: AudioRecorder
    private let transcriber: WhisperTranscriber
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
        transcriber: WhisperTranscriber,
        textInjector: TextInjector
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
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

        let transcriber = self.transcriber
        let transcription = try await Task.detached(priority: .userInitiated) {
            try transcriber.transcribe(audioURL: audioURL)
        }.value
        logger.notice(
            "Whisper transcription completed; characters=\(transcription.count, privacy: .public)"
        )
        let method = try await textInjector.insert(
            transcription,
            target: insertionTarget
        )
        insertionTarget = nil
        logger.notice(
            "Text insertion completed; method=\(method.rawValue, privacy: .public)"
        )

        let preview = String(transcription.prefix(60))
        phase = .completed(preview)
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
