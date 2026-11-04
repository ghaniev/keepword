// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetNotes",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/jkrukowski/swift-embeddings.git", from: "0.0.10"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        // llama.cpp (build b11457, 2026-10-06), Metal-accelerated, for the built-in local LLM.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11457/llama-b11457-xcframework.zip",
            checksum: "4c344f0b9ec2c972b2262eb45b2c5b23d6ff4a644135f40642a7a37336e94f1c"
        ),
        .executableTarget(
            name: "MeetNotes",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Embeddings", package: "swift-embeddings"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                "llama",
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
