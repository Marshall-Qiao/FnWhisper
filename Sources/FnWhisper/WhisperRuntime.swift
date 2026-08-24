import Darwin
import Foundation

enum WhisperBackend: String {
    case serverMetal = "常驻 Metal"
    case serverCPU = "常驻 CPU"
    case cliMetal = "whisper-cli Metal"
    case cliCPU = "whisper-cli CPU"
}

struct WhisperRuntimeResult {
    let rawText: String
    let backend: WhisperBackend
    let warning: String?
}

struct WhisperServerEndpoint: Equatable {
    let port: UInt16
    let requestPath: String

    var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(requestPath)/health")!
    }

    var inferenceURL: URL {
        URL(string: "http://127.0.0.1:\(port)\(requestPath)/inference")!
    }
}

enum WhisperServerProtocol {
    static func launchArguments(
        endpoint: WhisperServerEndpoint,
        modelURL: URL,
        language: String,
        threadCount: Int,
        useGPU: Bool
    ) -> [String] {
        var arguments = [
            "--host", "127.0.0.1",
            "--port", String(endpoint.port),
            "--request-path", endpoint.requestPath,
            "--threads", String(max(1, threadCount)),
            "--model", modelURL.path,
            "--language", language,
            "--no-timestamps",
            "--best-of", "5",
            "--beam-size", "5",
        ]
        if !useGPU {
            arguments.append("--no-gpu")
        }
        return arguments
    }

    static func multipartBody(
        audioData: Data,
        language: String,
        boundary: String
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"file\"; "
                + "filename=\"audio.wav\"\r\n"
        )
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        appendField(name: "response_format", value: "json")
        appendField(name: "language", value: language)
        appendField(name: "no_timestamps", value: "true")
        append("--\(boundary)--\r\n")
        return body
    }

    static func parseHealthResponse(
        data: Data,
        statusCode: Int
    ) -> Bool {
        guard statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: String]
        else {
            return false
        }
        return object["status"] == "ok"
    }

    static func parseInferenceResponse(
        data: Data,
        statusCode: Int
    ) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data)
                as? [String: String])?["error"] ?? "HTTP \(statusCode)"
            throw WhisperServerError.httpStatus(statusCode, message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let text = object["text"] as? String
        else {
            throw WhisperServerError.invalidResponse
        }
        return text
    }
}

enum WhisperServerError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case exited(Int32, String)
    case startupTimedOut
    case requestTimedOut
    case transportFailed(String)
    case httpStatus(Int, String)
    case invalidResponse
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            return "没有找到 whisper-server。"
        case let .launchFailed(message):
            return "无法启动 whisper-server：\(message)"
        case let .exited(code, message):
            let detail = message.isEmpty ? "没有诊断信息" : message
            return "whisper-server 已退出（\(code)）：\(detail)"
        case .startupTimedOut:
            return "whisper-server 加载模型超时。"
        case .requestTimedOut:
            return "whisper-server 请求超时。"
        case let .transportFailed(message):
            return "无法连接 whisper-server：\(message)"
        case let .httpStatus(code, message):
            return "whisper-server 请求失败（HTTP \(code)）：\(message)"
        case .invalidResponse:
            return "whisper-server 返回了无法解析的结果。"
        case .shuttingDown:
            return "Whisper 本地服务正在关闭。"
        }
    }

    var allowsCLIFallback: Bool {
        switch self {
        case let .httpStatus(code, _):
            return code >= 500
        case .invalidResponse,
             .executableMissing,
             .launchFailed,
             .exited,
             .startupTimedOut,
             .requestTimedOut,
             .transportFailed:
            return true
        case .shuttingDown:
            return false
        }
    }
}

final class WhisperRuntime: @unchecked Sendable {
    private let cliTranscriber: WhisperTranscriber
    private let serverExecutableURL: URL?
    private let modelURL: URL
    private let language: String
    private let threadCount: Int
    private let useGPU: Bool
    private let queue = DispatchQueue(
        label: "com.marshall.fnwhisper.whisper-runtime",
        qos: .userInitiated
    )
    private let processHolder = WhisperChildProcessHolder()
    private let session: URLSession

    private var serverProcess: Process?
    private var serverErrorPipe: Pipe?
    private var serverDiagnostics = WhisperDiagnosticBuffer()
    private var endpoint: WhisperServerEndpoint?
    private var serverUsesGPU = true
    private var serverWarning: String?
    private var retryServerAfter: Date?
    private var cachedServerFailure: WhisperServerError?

    init(
        cliTranscriber: WhisperTranscriber,
        serverExecutableURL: URL?,
        modelURL: URL,
        language: String,
        threadCount: Int,
        useGPU: Bool
    ) {
        self.cliTranscriber = cliTranscriber
        self.serverExecutableURL = serverExecutableURL
        self.modelURL = modelURL
        self.language = language
        self.threadCount = max(1, threadCount)
        self.useGPU = useGPU

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func warmUp() {
        queue.async { [weak self] in
            _ = try? self?.ensureServerReady()
        }
    }

    func transcribe(audioURL: URL) async throws -> WhisperRuntimeResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try transcribeSynchronously(audioURL: audioURL)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        session.invalidateAndCancel()
        processHolder.close()
    }

    var diagnosticDescription: String {
        guard let serverExecutableURL else {
            return "未找到 whisper-server（将使用较慢的 CLI 兼容模式）"
        }
        guard FileManager.default.isExecutableFile(atPath: serverExecutableURL.path) else {
            return "whisper-server 不可执行（将使用较慢的 CLI 兼容模式）"
        }
        return "常驻服务已配置：\(serverExecutableURL.path)"
    }

    private func transcribeSynchronously(
        audioURL: URL
    ) throws -> WhisperRuntimeResult {
        guard !processHolder.isClosed else {
            throw WhisperServerError.shuttingDown
        }

        let readyEndpoint: WhisperServerEndpoint
        do {
            readyEndpoint = try ensureServerReady()
        } catch let serverError as WhisperServerError {
            return try fallBackToCLI(
                audioURL: audioURL,
                serverError: serverError
            )
        }

        do {
            let rawText = try requestTranscription(
                audioURL: audioURL,
                endpoint: readyEndpoint
            )
            return WhisperRuntimeResult(
                rawText: rawText,
                backend: serverUsesGPU ? .serverMetal : .serverCPU,
                warning: serverWarning
            )
        } catch let serverError as WhisperServerError {
            if useGPU,
               serverUsesGPU,
               serverError.allowsCLIFallback,
               let serverExecutableURL {
                do {
                    stopServer()
                    let cpuEndpoint = try launchServer(
                        executableURL: serverExecutableURL,
                        useGPU: false
                    )
                    serverUsesGPU = false
                    serverWarning = "Whisper Metal 常驻服务推理失败，已切换到 CPU 常驻服务。"
                    let rawText = try requestTranscription(
                        audioURL: audioURL,
                        endpoint: cpuEndpoint
                    )
                    retryServerAfter = nil
                    cachedServerFailure = nil
                    return WhisperRuntimeResult(
                        rawText: rawText,
                        backend: .serverCPU,
                        warning: serverWarning
                    )
                } catch let cpuError as WhisperServerError {
                    return try fallBackToCLI(
                        audioURL: audioURL,
                        serverError: cpuError
                    )
                }
            }
            return try fallBackToCLI(
                audioURL: audioURL,
                serverError: serverError
            )
        }
    }

    private func fallBackToCLI(
        audioURL: URL,
        serverError: WhisperServerError
    ) throws -> WhisperRuntimeResult {
        guard !processHolder.isClosed else {
            throw WhisperServerError.shuttingDown
        }
        guard serverError.allowsCLIFallback else {
            throw serverError
        }
        cacheServerFailure(serverError)
        stopServer()
        let cliResult = try cliTranscriber.transcribeRaw(audioURL: audioURL)
        return WhisperRuntimeResult(
            rawText: cliResult.rawText,
            backend: cliResult.usedGPU ? .cliMetal : .cliCPU,
            warning: combineWarnings(
                "Whisper 常驻服务不可用，已使用较慢的 whisper-cli 兼容模式。",
                cliResult.warning
            )
        )
    }

    private func ensureServerReady() throws -> WhisperServerEndpoint {
        guard !processHolder.isClosed else {
            throw WhisperServerError.shuttingDown
        }
        if let endpoint,
           let serverProcess,
           serverProcess.isRunning {
            return endpoint
        }

        if let retryServerAfter,
           retryServerAfter > Date(),
           let cachedServerFailure {
            throw cachedServerFailure
        }

        stopServer()
        guard let serverExecutableURL,
              FileManager.default.isExecutableFile(atPath: serverExecutableURL.path)
        else {
            throw WhisperServerError.executableMissing
        }

        var firstFailure: Error?
        let attempts = useGPU ? [true, false] : [false]
        for attemptUsesGPU in attempts {
            guard !processHolder.isClosed else {
                throw WhisperServerError.shuttingDown
            }
            do {
                let readyEndpoint = try launchServer(
                    executableURL: serverExecutableURL,
                    useGPU: attemptUsesGPU
                )
                serverUsesGPU = attemptUsesGPU
                if useGPU && !attemptUsesGPU {
                    serverWarning = "Whisper Metal 常驻服务启动失败，已使用 CPU 常驻服务。"
                } else {
                    serverWarning = nil
                }
                retryServerAfter = nil
                cachedServerFailure = nil
                return readyEndpoint
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
                stopServer()
            }
        }

        if let serverError = firstFailure as? WhisperServerError {
            cacheServerFailure(serverError)
            throw serverError
        }
        let failure = WhisperServerError.launchFailed(
            firstFailure?.localizedDescription ?? "未知错误"
        )
        cacheServerFailure(failure)
        throw failure
    }

    private func launchServer(
        executableURL: URL,
        useGPU: Bool
    ) throws -> WhisperServerEndpoint {
        guard !processHolder.isClosed else {
            throw WhisperServerError.shuttingDown
        }
        let endpoint = WhisperServerEndpoint(
            port: UInt16.random(in: 49_152...65_535),
            requestPath: "/fnwhisper-\(UUID().uuidString.lowercased())"
        )
        let process = Process()
        let errorPipe = Pipe()
        let diagnostics = WhisperDiagnosticBuffer()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnostics.append(data)
            }
        }

        process.executableURL = executableURL
        process.arguments = WhisperServerProtocol.launchArguments(
            endpoint: endpoint,
            modelURL: modelURL,
            language: language,
            threadCount: threadCount,
            useGPU: useGPU
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw WhisperServerError.launchFailed(error.localizedDescription)
        }

        serverProcess = process
        serverErrorPipe = errorPipe
        serverDiagnostics = diagnostics
        self.endpoint = endpoint
        guard processHolder.set(process) else {
            throw WhisperServerError.shuttingDown
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard process.isRunning else {
                throw WhisperServerError.exited(
                    process.terminationStatus,
                    diagnostics.text
                )
            }

            var request = URLRequest(url: endpoint.healthURL)
            request.httpMethod = "GET"
            if let response = try? synchronousRequest(request, timeout: 0.5),
               WhisperServerProtocol.parseHealthResponse(
                   data: response.data,
                   statusCode: response.statusCode
               ) {
                return endpoint
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        throw WhisperServerError.startupTimedOut
    }

    private func requestTranscription(
        audioURL: URL,
        endpoint: WhisperServerEndpoint
    ) throws -> String {
        let audioData = try Data(contentsOf: audioURL)
        let boundary = "FnWhisper-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.inferenceURL)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = WhisperServerProtocol.multipartBody(
            audioData: audioData,
            language: language,
            boundary: boundary
        )

        let response = try synchronousRequest(request, timeout: 120)
        return try WhisperServerProtocol.parseInferenceResponse(
            data: response.data,
            statusCode: response.statusCode
        )
    }

    private func synchronousRequest(
        _ request: URLRequest,
        timeout: TimeInterval
    ) throws -> WhisperHTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = WhisperHTTPResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.set(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw WhisperServerError.requestTimedOut
        }
        return try box.result()
    }

    private func stopServer() {
        serverErrorPipe?.fileHandleForReading.readabilityHandler = nil
        serverErrorPipe = nil
        processHolder.terminateCurrentProcess()
        serverProcess = nil
        endpoint = nil
        serverWarning = nil
    }

    private func cacheServerFailure(_ error: WhisperServerError) {
        guard error.allowsCLIFallback else {
            return
        }
        if let retryServerAfter, retryServerAfter > Date() {
            return
        }
        cachedServerFailure = error
        retryServerAfter = Date().addingTimeInterval(30)
    }
}

private struct WhisperHTTPResponse {
    let data: Data
    let statusCode: Int
}

private final class WhisperHTTPResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    private var error: Error?

    func set(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
    }

    func result() throws -> WhisperHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw WhisperServerError.transportFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperServerError.invalidResponse
        }
        return WhisperHTTPResponse(
            data: data ?? Data(),
            statusCode: httpResponse.statusCode
        )
    }
}

private final class WhisperDiagnosticBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maximumBytes = 16_384

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        if data.count > maximumBytes {
            data.removeFirst(data.count - maximumBytes)
        }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }
}

private final class WhisperChildProcessHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func set(_ process: Process) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            Self.terminate(process)
            return false
        }
        self.process = process
        lock.unlock()
        return true
    }

    func terminateCurrentProcess() {
        lock.lock()
        let process = self.process
        self.process = nil
        lock.unlock()

        guard let process else {
            return
        }
        Self.terminate(process)
    }

    func close() {
        lock.lock()
        closed = true
        let process = self.process
        self.process = nil
        lock.unlock()

        guard let process else {
            return
        }
        Self.terminate(process)
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()

        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private func combineWarnings(_ first: String?, _ second: String?) -> String? {
    [first, second]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
