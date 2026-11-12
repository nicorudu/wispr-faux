// swift-tools-version: 6.0
import PackageDescription

// Core modules for Dictate. Each module maps to a box in BUILD_PLAN.md §2 and is
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
                "PostProcessKit",
                "ContextKit",
                "InsertionKit",
                "HistoryKit",
            ]
        ),
        // Benchmarks Whisper models on audio files from the command line (Step 5).
        .executable(name: "dictate-bench", targets: ["DictateBench"]),
    ],
    dependencies: [
        // On-device Whisper on Core ML. Pinned: model loading and the offline guarantees in
        // TranscriptionKit depend on its internals (download paths, tokenizer lookup).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
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
        .executableTarget(name: "DictateBench", dependencies: ["AudioKit", "TranscriptionKit"]),
        .target(name: "PostProcessKit"),
        .target(name: "ContextKit"),
        .target(name: "InsertionKit", dependencies: ["HotkeyKit"]),
        .target(name: "HistoryKit"),
        .testTarget(
            name: "DictationKitTests",
            dependencies: [
                "AudioKit",
                "TranscriptionKit",
                "HotkeyKit",
                "PostProcessKit",
                "HistoryKit",
                "InsertionKit",
            ]
        ),
    ]
)
