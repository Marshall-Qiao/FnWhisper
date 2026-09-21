import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

private final class CountingRefiner: TextRefining, @unchecked Sendable {
    private let inner: TextRefining
    private let lock = NSLock()
    private var calls = 0
    init(_ inner: TextRefining) { self.inner = inner }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func record() { lock.lock(); calls += 1; lock.unlock() }
    func refine(_ text: String, context: TextRefinementContext) async throws -> TextRefinementResult {
        record()
        return try await inner.refine(text, context: context)
    }
}

// JSON bridge: use the application's actual prompt, schema and validator.
// Golden answers and scoring live independently in cases.json / compare-models.py.
@main
struct ModelComparisonBridge {
    static func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let command = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let operation = command["operation"] as! String
            let source = command["source"] as? String ?? ""
            let input = TextRefinementInput.prepare(source)
            let budget = command["tokens"] as? Int ?? 192
            switch operation {
            case "selection":
                let qwen = QwenTextRefiner(executableURL: URL(fileURLWithPath: command["executable"] as! String),
                                          modelURL: URL(fileURLWithPath: command["model"] as! String))
                defer { qwen.shutdown() }
                try await qwen.prepare()
                let sources = command["sources"] as! [[String: String]]
                for delay in [0.0, 1.5, 1.5, 0.0] {
                    for entry in sources {
                        let trackedQwen = CountingRefiner(qwen)
                        let trackedApple = AppleFoundationTextRefinerFactory.makeIfAvailable().map(CountingRefiner.init)
                        let refiner = ParallelTextRefiner(qwen: trackedQwen, apple: trackedApple, fallbackDelay: delay)
                        let started = Date()
                        var row: [String: Any] = ["id": entry["id"]!, "delay": delay]
                        do {
                            let result = try await refiner.refine(entry["source"]!, context: .init(speechDuration: 10))
                            row["rendered"] = result.text
                            row["provider"] = result.provider.rawValue
                        } catch { row["error"] = String(describing: error) }
                        row["seconds"] = Date().timeIntervalSince(started)
                        row["qwen_calls"] = trackedQwen.count
                        row["apple_calls"] = trackedApple?.count ?? 0
                        emit(row)
                    }
                }
            case "asr-normalize":
                emit(["text": source.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? source])
            case "request":
                let body = try QwenServerProtocol.requestBody(input: input, maximumTokens: budget)
                emit(["body": try JSONSerialization.jsonObject(with: body), "source": input.source])
            case "validate":
                let content = command["content"] as! String
                let payload = try JSONDecoder().decode(TextRefinementPayload.self, from: Data(content.utf8))
                let rendered = try TextRefinementValidator.validateAndRender(
                    payload, source: input.source, requiredFormat: input.requiredFormat
                )
                emit(["valid": true, "rendered": rendered,
                      "lead": payload.lead, "items": payload.items, "tail": payload.tail])
            case "apple":
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    let started = Date()
                    let content = try await apple(input: input, budget: budget)
                    emit(["content": content, "seconds": Date().timeIntervalSince(started)])
                } else {
                    emit(["error": "Foundation Models requires macOS 26"])
                }
                #else
                emit(["error": "Foundation Models SDK unavailable"])
                #endif
            default:
                emit(["error": "Unknown operation"])
            }
        } catch {
            emit(["error": String(describing: error)])
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func apple(input: TextRefinementInput, budget: Int) async throws -> String {
        guard case .available = SystemLanguageModel.default.availability else {
            throw TextRefinementError.unavailable("Apple Foundation Models unavailable")
        }
        let count = max(TextLayoutHeuristics.explicitOrdinalCount(in: input.source),
                        TextLayoutHeuristics.declaredItemCount(in: input.source) ?? 0)
        let string = DynamicGenerationSchema(type: String.self)
        let items = DynamicGenerationSchema(
            arrayOf: string,
            minimumElements: input.requiredFormat == .numberedList ? max(2, count) : 1,
            maximumElements: input.requiredFormat == .paragraph ? 1 : (count >= 2 ? count : 8)
        )
        let root = DynamicGenerationSchema(name: "RefinedText", properties: [
            .init(name: "lead", schema: string), .init(name: "items", schema: items),
            .init(name: "tail", schema: string),
        ])
        let session = LanguageModelSession(instructions: TextRefinementPrompt.instructions)
        let response = try await session.respond(
            to: TextRefinementPrompt.request(for: input),
            schema: GenerationSchema(root: root, dependencies: []),
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: budget)
        )
        return response.content.jsonString
    }
    #endif
}
