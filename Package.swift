// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FnWhisper",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "FnWhisper", targets: ["FnWhisper"]),
    ],
    targets: [
        .executableTarget(name: "FnWhisper"),
    ],
    swiftLanguageModes: [.v5]
)
