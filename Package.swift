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
        .binaryTarget(
            name: "SherpaOnnxMacOS",
            url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.5-macos-static.xcframework.zip",
            checksum: "56bbe822793786e88ff9f459986a78b58a8253d85510054c1591bd2d1bd4bdf4"
        ),
        .binaryTarget(
            name: "OnnxruntimeMacOS",
            url: "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.27.1/onnxruntime-macos-static-xcframework-1.27.1.xcframework.zip",
            checksum: "89769c25a63985e2ab7a12e72215c173c5078e49dc4a2273cb84b75e587d7b96"
        ),
        .executableTarget(
            name: "FnWhisper",
            dependencies: [
                "SherpaOnnxMacOS",
                "OnnxruntimeMacOS",
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreML"),
                .linkedLibrary("c++"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
