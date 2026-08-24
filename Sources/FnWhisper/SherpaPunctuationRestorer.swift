import Foundation
import SherpaOnnxC

enum PunctuationRestorerError: LocalizedError {
    case modelMissing(URL)
    case initializationFailed
    case inferenceFailed
    case emptyResult

    var errorDescription: String? {
        switch self {
        case let .modelMissing(url):
            return "没有找到 CT-Punc INT8 模型：\(url.path)。请运行 scripts/setup-punctuation.sh。"
        case .initializationFailed:
            return "无法加载 sherpa-onnx CT-Punc INT8 模型。"
        case .inferenceFailed:
            return "sherpa-onnx CT-Punc 标点恢复失败。"
        case .emptyResult:
            return "sherpa-onnx CT-Punc 返回了空结果。"
        }
    }
}

final class SherpaPunctuationRestorer: @unchecked Sendable {
    let modelURL: URL

    private let queue = DispatchQueue(
        label: "com.marshall.fnwhisper.punctuation",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var handle: OpaquePointer?
    private var lastInitializationError: String?

    init(modelURL: URL) {
        self.modelURL = modelURL
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == 1 {
            destroyHandle()
        } else {
            queue.sync {
                destroyHandle()
            }
        }
    }

    func warmUp() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try self.ensureHandle()
            } catch {
                self.lastInitializationError = error.localizedDescription
            }
        }
    }

    func restore(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(returning: try restoreSynchronously(text))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    var diagnosticDescription: String {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return "模型缺失（将使用基础断句）"
        }
        return queue.sync {
            if handle != nil {
                return "CT-Punc INT8 已加载"
            }
            if let lastInitializationError {
                return "加载失败（将使用基础断句）：\(lastInitializationError)"
            }
            return "CT-Punc INT8 正在准备"
        }
    }

    private func restoreSynchronously(_ text: String) throws -> String {
        let handle = try ensureHandle()
        let resultPointer = text.withCString { textPointer in
            SherpaOfflinePunctuationAddPunct(handle, textPointer)
        }
        guard let resultPointer else {
            throw PunctuationRestorerError.inferenceFailed
        }
        defer {
            SherpaOfflinePunctuationFreeText(resultPointer)
        }

        let result = String(cString: resultPointer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw PunctuationRestorerError.emptyResult
        }
        return result
    }

    private func ensureHandle() throws -> OpaquePointer {
        if let handle {
            return handle
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw PunctuationRestorerError.modelMissing(modelURL)
        }

        let createdHandle = modelURL.path.withCString { modelPath in
            "cpu".withCString { provider in
                let model = SherpaOnnxOfflinePunctuationModelConfig(
                    ct_transformer: modelPath,
                    num_threads: 1,
                    debug: 0,
                    provider: provider
                )
                var configuration = SherpaOnnxOfflinePunctuationConfig(
                    model: model
                )
                return SherpaOnnxCreateOfflinePunctuation(&configuration)
            }
        }
        guard let createdHandle else {
            lastInitializationError = PunctuationRestorerError
                .initializationFailed
                .localizedDescription
            throw PunctuationRestorerError.initializationFailed
        }

        handle = createdHandle
        lastInitializationError = nil
        return createdHandle
    }

    private func destroyHandle() {
        if let handle {
            SherpaOnnxDestroyOfflinePunctuation(handle)
            self.handle = nil
        }
    }
}
