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
    ],
    targets: [
        .target(name: "HotkeyKit"),
        .target(name: "AudioKit", dependencies: ["ObjCExceptions"]),
        // Catches Objective-C exceptions from AVAudioEngine, which Swift can't.
        .target(name: "ObjCExceptions"),
        .target(name: "TranscriptionKit"),
        .target(name: "PostProcessKit"),
        .target(name: "ContextKit"),
        .target(name: "InsertionKit", dependencies: ["HotkeyKit"]),
        .target(name: "HistoryKit"),
        .testTarget(
            name: "DictationKitTests",
            dependencies: [
                "AudioKit",
                "HotkeyKit",
                "PostProcessKit",
                "HistoryKit",
                "InsertionKit",
            ]
        ),
    ]
)
