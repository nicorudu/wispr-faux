import AppKit
import InsertionKit
import Observation
import os

/// Step 3 spike: the "Paste Test String" menu item. Pastes a timestamped line into the
/// app that's in front, then reports how the clipboard restore went, so the §3 app matrix
/// can be checked by hand before dictation is wired up. Replaced by real dictation in Step 6.
@MainActor
@Observable
final class PasteTester {
    private(set) var isRunning = false
    /// e.g. "Pasted into TextEdit in 24 ms".
    private(set) var lastPaste: String?
    /// e.g. "Clipboard restored ✓ (image, 3 types, 1.2 MB)".
    private(set) var lastRestore: String?

    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private var targetName = ""
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "PasteTest")

    init(inserter: TextInserter) {
        self.inserter = inserter
        inserter.verifiesRestore = true
        inserter.onRestore = { [weak self] outcome in
            self?.restoreFinished(outcome)
        }
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            defer { isRunning = false }
            // Let the menu finish closing so ⌘V reaches the app underneath, not the menu.
            try? await Task.sleep(for: .milliseconds(250))

            let app = NSWorkspace.shared.frontmostApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                lastPaste = "Click into a text field in another app first"
                lastRestore = nil
                return
            }
            targetName = app?.localizedName ?? "the front app"
            lastRestore = "Clipboard: restoring…"

            do {
                let report = try await inserter.insert(Self.testString())
                var line = "Pasted into \(targetName) in \(Self.ms(report.pasteLatency)) ms"
                if !report.heldModifiers.isEmpty {
                    line += " (with \(report.heldModifiers.joined()) held)"
                }
                lastPaste = line
                log.notice("""
                    Paste test into \(app?.bundleIdentifier ?? "?", privacy: .public): \
                    \(Self.ms(report.pasteLatency), privacy: .public) ms, V keycode \(report.vKeyCode, privacy: .public)
                    """)
            } catch {
                lastPaste = "Paste failed: \(error.localizedDescription)"
                lastRestore = nil
                log.error("Paste test failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func restoreFinished(_ outcome: TextInserter.RestoreOutcome) {
        lastRestore = switch outcome {
        case .restored(let summary, verified: false):
            "Clipboard restored but differs (\(summary))"
        case .restored(let summary, _) where summary.itemCount == 0:
            "Clipboard was empty and is empty again ✓"
        case .restored(let summary, _):
            "Clipboard restored ✓ (\(summary))"
        case .skippedClipboardChanged:
            "Clipboard left alone: something new was copied"
        case .failed:
            "Clipboard restore failed"
        }
    }

    /// One line, no newline (so a terminal never runs it), with non-ASCII to catch
    /// encoding problems and the time to tell pastes apart.
    private static func testString() -> String {
        "Dictate paste test \(Date.now.formatted(date: .omitted, time: .standard)) · café ✓"
    }

    private static func ms(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
