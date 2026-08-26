import Darwin
import Foundation

struct QwenServerEndpoint: Equatable {
    let port: UInt16

    var healthURL: URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    var chatCompletionsURL: URL {
        URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
    }
}

enum QwenServerProtocol {
    static let modelAlias = "qwen3-4b-instruct-2507-q4-k-m"

    static func launchArguments(
        endpoint: QwenServerEndpoint,
        modelURL: URL
    ) -> [String] {
        [
            "--offline",
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(endpoint.port),
            "--alias", modelAlias,
            "--ctx-size", "4096",
            "--parallel", "1",
            "--n-gpu-layers", "auto",
            "--reasoning", "off",
            "--reasoning-budget", "0",
            "--chat-template-kwargs", "{\"enable_thinking\":false}",
            "--no-ui",
        ]
    }

    static func requestBody(
        input: TextRefinementInput,
        maximumTokens: Int = 192
    ) throws -> Data {
        let expectedItemCount = max(
            TextLayoutHeuristics.explicitOrdinalCount(in: input.source),
            TextLayoutHeuristics.declaredItemCount(in: input.source) ?? 0
        )
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["lead", "items", "tail"],
            "properties": [
                "lead": ["type": "string"],
                "items": [
                    "type": "array",
                    "minItems": input.requiredFormat == .numberedList
                        ? max(2, expectedItemCount) : 1,
                    "maxItems": input.requiredFormat == .paragraph
                        ? 1 : (expectedItemCount >= 2 ? expectedItemCount : 8),
                    "items": ["type": "string"],
                ],
                "tail": ["type": "string"],
            ],
        ]
        let body: [String: Any] = [
            "model": modelAlias,
            "messages": [
                [
                    "role": "system",
                    "content": TextRefinementPrompt.instructions,
                ],
                [
                    "role": "user",
                    "content": TextRefinementPrompt.request(for: input),
                ],
            ],
            "temperature": 0,
            "max_tokens": max(1, maximumTokens),
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "refined_text",
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func requestBody(
        text: String,
        maximumTokens: Int = 192
    ) throws -> Data {
        try requestBody(
            input: TextRefinementInput.prepare(text),
            maximumTokens: maximumTokens
        )
    }

    static func parseResponse(data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            let error = object?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(statusCode)"
            throw TextRefinementError.unavailable(
                "Qwen 请求失败（HTTP \(statusCode)）：\(message)"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty
        else {
            throw TextRefinementError.invalidResponse("Qwen 响应无法解析")
        }
        return content
    }
}

final class QwenTextRefiner: TextRefining, @unchecked Sendable {
    private let executableURL: URL
    private let modelURL: URL
    private let stateQueue = DispatchQueue(
        label: "com.marshall.fnwhisper.qwen-state",
        qos: .userInitiated
    )
    private let inferenceQueue = DispatchQueue(
        label: "com.marshall.fnwhisper.qwen-inference",
        qos: .userInitiated
    )
    private let processHolder = QwenChildProcessHolder()
    private let readyState = QwenReadyState()
    private let session: URLSession

    private var process: Process?
    private var errorPipe: Pipe?
    private var endpoint: QwenServerEndpoint?
    private var isReady = false
    private var isLaunching = false

    init(
        executableURL: URL,
        modelURL: URL
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func warmUp() {
        stateQueue.async { [weak self] in
            _ = try? self?.ensureServerReady()
        }
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async { [self] in
                do {
                    _ = try ensureServerReady()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func refine(
        _ text: String,
        context: TextRefinementContext
    ) async throws -> TextRefinementResult {
        guard let endpoint = readyEndpoint() else {
            warmUp()
            throw TextRefinementError.unavailable("Qwen 正在启动")
        }

        do {
            let input = TextRefinementInput.prepare(text)
            let payload = try await requestRefinement(
                input: input,
                context: context,
                endpoint: endpoint
            )
            return TextRefinementResult(
                text: try TextRefinementValidator.validateAndRender(
                    payload,
                    source: input.source,
                    requiredFormat: input.requiredFormat
                ),
                provider: .qwen
            )
        } catch {
            if shouldRestart(after: error) {
                scheduleRestart()
            }
            throw error
        }
    }

    func shutdown() {
        session.invalidateAndCancel()
        processHolder.close()
        stateQueue.async { [weak self] in
            self?.clearServerState()
        }
    }

    var diagnosticDescription: String {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return "llama-server 不可执行"
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return "Qwen 模型未找到：\(modelURL.path)"
        }
        return "\(modelURL.lastPathComponent) fast 模式已配置（按文本与录音时长动态回退）"
    }

    private func readyEndpoint() -> QwenServerEndpoint? {
        guard !processHolder.isClosed else {
            return nil
        }
        return readyState.endpointIfReady
    }

    private func ensureServerReady() throws -> QwenServerEndpoint {
        guard !processHolder.isClosed else {
            throw TextRefinementError.shuttingDown
        }
        if isReady,
           let endpoint,
           process?.isRunning == true {
            return endpoint
        }
        guard !isLaunching else {
            throw TextRefinementError.unavailable("Qwen 正在启动")
        }
        isLaunching = true
        defer { isLaunching = false }

        stopServer()
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw TextRefinementError.unavailable("未找到 llama-server")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw TextRefinementError.unavailable("未找到 Qwen 模型")
        }

        let endpoint = QwenServerEndpoint(
            port: UInt16.random(in: 49_152...65_535)
        )
        let process = Process()
        let errorPipe = Pipe()
        let diagnostics = QwenDiagnosticBuffer()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnostics.append(data)
            }
        }
        process.executableURL = executableURL
        process.arguments = QwenServerProtocol.launchArguments(
            endpoint: endpoint,
            modelURL: modelURL
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw TextRefinementError.unavailable(
                "无法启动 llama-server：\(error.localizedDescription)"
            )
        }
        self.process = process
        self.errorPipe = errorPipe
        self.endpoint = endpoint
        guard processHolder.set(process) else {
            throw TextRefinementError.shuttingDown
        }

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard !processHolder.isClosed else {
                throw TextRefinementError.shuttingDown
            }
            guard process.isRunning else {
                throw TextRefinementError.unavailable(
                    "llama-server 已退出（\(process.terminationStatus)）：\(diagnostics.text)"
                )
            }
            if healthCheck(endpoint: endpoint) {
                try primeServer(endpoint: endpoint)
                isReady = true
                readyState.set(endpoint: endpoint, process: process)
                return endpoint
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TextRefinementError.unavailable("Qwen 模型加载超时")
    }

    private func healthCheck(endpoint: QwenServerEndpoint) -> Bool {
        var request = URLRequest(url: endpoint.healthURL)
        request.httpMethod = "GET"
        guard let response = try? synchronousRequest(request, timeout: 0.5) else {
            return false
        }
        return response.statusCode == 200
    }

    private func primeServer(endpoint: QwenServerEndpoint) throws {
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try QwenServerProtocol.requestBody(
            text: "嗯帮我用cloud code写一个脚本",
            maximumTokens: 64
        )
        let response = try synchronousRequest(request, timeout: 30)
        _ = try QwenServerProtocol.parseResponse(
            data: response.data,
            statusCode: response.statusCode
        )
    }

    private func requestRefinement(
        input: TextRefinementInput,
        context: TextRefinementContext,
        endpoint: QwenServerEndpoint
    ) async throws -> TextRefinementPayload {
        let timeout = AppConfiguration.textRefinementTimeout(
            for: input.source,
            speechDuration: context.speechDuration
        )
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try QwenServerProtocol.requestBody(input: input)

        return try await withCheckedThrowingContinuation { continuation in
            inferenceQueue.async { [self] in
                do {
                    let response = try synchronousRequest(
                        request,
                        timeout: timeout
                    )
                    let content = try QwenServerProtocol.parseResponse(
                        data: response.data,
                        statusCode: response.statusCode
                    )
                    guard let data = content.data(using: .utf8),
                          let payload = try? JSONDecoder().decode(
                            TextRefinementPayload.self,
                            from: data
                          )
                    else {
                        throw TextRefinementError.invalidResponse(
                            "Qwen 返回的结构无法解析"
                        )
                    }
                    continuation.resume(returning: payload)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func synchronousRequest(
        _ request: URLRequest,
        timeout: TimeInterval
    ) throws -> QwenHTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = QwenHTTPResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.set(data: data, response: response, error: error)
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw TextRefinementError.timedOut
        }
        return try box.result()
    }

    private func scheduleRestart() {
        stateQueue.async { [weak self] in
            guard let self, !processHolder.isClosed else {
                return
            }
            stopServer()
            _ = try? ensureServerReady()
        }
    }

    private func shouldRestart(after error: Error) -> Bool {
        guard let error = error as? TextRefinementError else {
            return true
        }
        switch error {
        case .unavailable:
            return true
        case .timedOut, .invalidResponse, .semanticMismatch, .shuttingDown:
            return false
        }
    }

    private func stopServer() {
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe = nil
        processHolder.terminateCurrentProcess()
        clearServerState()
    }

    private func clearServerState() {
        readyState.clear()
        process = nil
        endpoint = nil
        isReady = false
    }
}

private struct QwenHTTPResponse {
    let data: Data
    let statusCode: Int
}

private final class QwenHTTPResponseBox: @unchecked Sendable {
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

    func result() throws -> QwenHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        if let error {
            throw TextRefinementError.unavailable(
                "Qwen 连接失败：\(error.localizedDescription)"
            )
        }
        guard let response = response as? HTTPURLResponse else {
            throw TextRefinementError.invalidResponse("Qwen 未返回 HTTP 响应")
        }
        return QwenHTTPResponse(
            data: data ?? Data(),
            statusCode: response.statusCode
        )
    }
}

private final class QwenDiagnosticBuffer: @unchecked Sendable {
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

private final class QwenChildProcessHolder: @unchecked Sendable {
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

private final class QwenReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoint: QwenServerEndpoint?
    private weak var process: Process?

    var endpointIfReady: QwenServerEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning == true else {
            return nil
        }
        return endpoint
    }

    func set(endpoint: QwenServerEndpoint, process: Process) {
        lock.lock()
        self.endpoint = endpoint
        self.process = process
        lock.unlock()
    }

    func clear() {
        lock.lock()
        endpoint = nil
        process = nil
        lock.unlock()
    }
}
