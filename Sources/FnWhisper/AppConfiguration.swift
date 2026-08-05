import Foundation

struct AppConfiguration {
    static let defaultModelFilename = "ggml-large-v3-q5_0.bin"

    static let applicationSupportDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("FnWhisper", isDirectory: true)
    }()

    let holdDuration: TimeInterval
    let language: String
    let modelURL: URL
    let threadCount: Int
    let useGPU: Bool
    private let environment: [String: String]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        self.environment = environment

        let configuredHoldMilliseconds = environment["FNWHISPER_HOLD_MS"]
            .flatMap(Double.init)
            ?? defaults.object(forKey: "holdMilliseconds") as? Double
            ?? 350
        holdDuration = max(0.15, min(configuredHoldMilliseconds / 1_000, 2.0))

        let requestedLanguage = environment["FNWHISPER_LANGUAGE"]
            ?? defaults.string(forKey: "language")
        language = Self.normalizedLanguage(requestedLanguage)

        let requestedThreadCount = environment["FNWHISPER_THREADS"]
            .flatMap(Int.init)
            ?? defaults.object(forKey: "threadCount") as? Int
        threadCount = Self.normalizedThreadCount(
            requestedThreadCount,
            processorCount: ProcessInfo.processInfo.activeProcessorCount
        )

        let configuredGPU = environment["FNWHISPER_GPU"]
            .flatMap(Self.parseBoolean)
        if let configuredGPU {
            useGPU = configuredGPU
        } else if defaults.object(forKey: "useGPU") != nil {
            useGPU = defaults.bool(forKey: "useGPU")
        } else {
            useGPU = true
        }

        let configuredModelPath = environment["FNWHISPER_MODEL"]
            ?? defaults.string(forKey: "modelPath")
        modelURL = configuredModelPath.map { URL(fileURLWithPath: $0) }
            ?? Self.applicationSupportDirectory
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(Self.defaultModelFilename)
    }

    static func normalizedLanguage(_ requestedLanguage: String?) -> String {
        switch requestedLanguage?.lowercased() {
        case "zh":
            return "zh"
        case "en":
            return "en"
        default:
            return "auto"
        }
    }

    static func normalizedThreadCount(
        _ requestedThreadCount: Int?,
        processorCount: Int
    ) -> Int {
        let availableProcessors = max(1, processorCount)
        let defaultThreadCount = min(
            8,
            max(1, availableProcessors - 2)
        )
        return min(
            availableProcessors,
            max(1, requestedThreadCount ?? defaultThreadCount)
        )
    }

    static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    func resolveWhisperCLI() -> URL? {
        var candidates: [URL] = []

        if let configuredPath = environment["FNWHISPER_WHISPER_CLI"] {
            candidates.append(URL(fileURLWithPath: configuredPath))
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(
                resourceURL
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("whisper-cli")
            )
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"),
            URL(fileURLWithPath: "/usr/local/bin/whisper-cli"),
        ])

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
