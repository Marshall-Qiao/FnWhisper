import Foundation

enum TextInputContext: Equatable, Sendable {
    case prose
    case commandOrCode
}

enum TextTargetClassifier {
    private static let commandOrCodeBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.apple.dt.Xcode",
        "com.github.wez.wezterm",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4",
        "com.todesktop.230313mzl4w4u92",
        "com.vscodium",
        "dev.warp.Warp-Stable",
        "io.alacritty",
        "net.kovidgoyal.kitty",
    ]

    static func classify(bundleIdentifier: String?) -> TextInputContext {
        guard let bundleIdentifier else {
            return .prose
        }
        if commandOrCodeBundleIdentifiers.contains(bundleIdentifier)
            || bundleIdentifier.hasPrefix("com.jetbrains.") {
            return .commandOrCode
        }
        return .prose
    }
}
