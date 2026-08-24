import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleFoundationTextRefinerFactory {
    static func makeIfAvailable() -> TextRefining? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationTextRefiner.makeIfAvailable()
        }
        #endif
        return nil
    }

    static var diagnosticDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return "可用"
            }
            return "当前不可用"
        }
        #endif
        return "系统不支持"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AppleFoundationTextRefiner: TextRefining, @unchecked Sendable {
    static func makeIfAvailable() -> AppleFoundationTextRefiner? {
        guard case .available = SystemLanguageModel.default.availability else {
            return nil
        }
        return AppleFoundationTextRefiner()
    }

    func refine(_ text: String) async throws -> TextRefinementResult {
        guard case .available = SystemLanguageModel.default.availability else {
            throw TextRefinementError.unavailable(
                "Apple Foundation Models 当前不可用"
            )
        }

        let input = TextRefinementInput.prepare(text)
        let session = LanguageModelSession(
            instructions: TextRefinementPrompt.instructions
        )
        let response = try await session.respond(
            to: TextRefinementPrompt.request(for: input),
            schema: try Self.generationSchema(
                requiredFormat: input.requiredFormat
            ),
            options: GenerationOptions(
                sampling: .greedy,
                maximumResponseTokens: 192
            )
        )
        guard let data = response.content.jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(
                TextRefinementPayload.self,
                from: data
              )
        else {
            throw TextRefinementError.invalidResponse(
                "Apple 返回的结构无法解析"
            )
        }
        return TextRefinementResult(
            text: try TextRefinementValidator.validateAndRender(
                payload,
                source: input.source,
                requiredFormat: input.requiredFormat
            ),
            provider: .apple
        )
    }

    private static func generationSchema(
        requiredFormat: TextRefinementFormat?
    ) throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        let isList = requiredFormat == .numberedList
        let items = DynamicGenerationSchema(
            arrayOf: text,
            minimumElements: isList ? 2 : 1,
            maximumElements: isList ? 8 : 1
        )
        let root = DynamicGenerationSchema(
            name: "RefinedText",
            properties: [
                .init(name: "items", schema: items),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }
}
#endif
