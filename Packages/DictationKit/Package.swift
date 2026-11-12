// swift-tools-version: 6.0
import PackageDescription

// Core modules for Wispr Faux. Each module maps to a box in BUILD_PLAN.md §2 and is
// testable on its own; the app target imports them through the DictationKit product.
let package = Package(
    name: "DictationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "DictationKit",
            targets: [
                "HotkeyKit",
                "AudioKit",
                "TranscriptionKit",
                "CleanupKit",
                "PostProcessKit",
                "ContextKit",
                "InsertionKit",
                "HistoryKit",
            ]
        ),
        // Benchmarks Whisper models on audio files from the command line (Step 5).
        .executable(name: "wisprfaux-bench", targets: ["WisprFauxBench"]),
    ],
    dependencies: [
        // On-device Whisper on Core ML. Pinned: model loading and the offline guarantees in
        // TranscriptionKit depend on its internals (download paths, tokenizer lookup).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // On-device language models (MLX, Apple GPU) for cleaning up stumbles. Pinned to the
        // last release that builds with Swift 6.0 (Xcode 16); 2.31+ needs Swift 6.1.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "2.30.6"),
        // Hub downloads for those models; the same 1.1.x line mlx-swift-lm uses.
        .package(url: "https://github.com/huggingface/swift-transformers.git", .upToNextMinor(from: "1.1.6")),
    ],
    targets: [
        .target(name: "HotkeyKit"),
        .target(name: "AudioKit", dependencies: ["ObjCExceptions"]),
        // Catches Objective-C exceptions from AVAudioEngine, which Swift can't.
        .target(name: "ObjCExceptions"),
        .target(
            name: "TranscriptionKit",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .target(
            name: "CleanupKit",
            dependencies: [
                "PostProcessKit",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "WisprFauxBench",
            dependencies: ["AudioKit", "TranscriptionKit", "CleanupKit", "PostProcessKit"]
        ),
        .target(name: "PostProcessKit"),
        .target(name: "ContextKit"),
        .target(name: "InsertionKit", dependencies: ["HotkeyKit"]),
        .target(name: "HistoryKit"),
        .testTarget(
            name: "DictationKitTests",
            dependencies: [
                "AudioKit",
                "TranscriptionKit",
                "CleanupKit",
                "ContextKit",
                "HotkeyKit",
                "PostProcessKit",
                "HistoryKit",
                "InsertionKit",
            ]
        ),
    ]
)
