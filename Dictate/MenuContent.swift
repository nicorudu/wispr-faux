import HistoryKit
import SwiftUI

struct MenuContent: View {
    let controller: DictationController
    let openSetup: @MainActor () -> Void

    var body: some View {
        Text(hotkeyLine)

        if controller.isSecureInputActive, controller.hotkeyStatus == .running {
            Text("⚠︎ Secure input is on in another app")
        }
        if !controller.transcription.isReady {
            Text(controller.transcription.statusLine)
            if controller.transcription.status == .notDownloaded {
                Button(controller.transcription.downloadButtonTitle, action: controller.transcription.download)
            }
        }

        Divider()

        Button("Paste Last Transcript", action: controller.pasteLastTranscript)
            .disabled(controller.recentTranscripts.isEmpty)
        Button("Copy Last Transcript", action: controller.copyLastTranscript)
            .disabled(controller.recentTranscripts.isEmpty)
        Menu("Recent") {
            if controller.recentTranscripts.isEmpty {
                Text("Nothing dictated yet")
            } else {
                Text("Click to copy")
                ForEach(controller.recentTranscripts.prefix(15)) { record in
                    Button(Self.menuTitle(for: record)) { controller.copy(record) }
                }
                Divider()
                Button("Clear History", action: controller.clearHistory)
            }
        }

        Divider()

        Button(controller.permissions.allGranted ? "Permissions…" : "Finish Setup…", action: openSetup)

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        #if DEBUG
        Menu("Debug") {
            Text(controller.transcription.statusLine)
            if let timing = controller.lastTiming {
                Text("Last: \(timing)")
            }
            Divider()
            if let summary = controller.recordingTester.summary {
                Text(summary)
            }
            if let detail = controller.recordingTester.detail {
                Text(detail)
            }
            Button("Play Last Recording", action: controller.recordingTester.play)
                .disabled(controller.recordingTester.wavURL == nil)
            Button("Show Recording in Finder", action: controller.recordingTester.revealInFinder)
                .disabled(controller.recordingTester.wavURL == nil)
            Button("Record 3 Seconds Without the Hotkey") { controller.debugRecord(seconds: 3) }
            Divider()
            Button("Simulate Event-Tap Timeout on Next Key", action: controller.simulateTapTimeout)
            Text("Tap re-enabled: \(controller.tapStats.reenableCount)×\(lastReason)")
            Text("Slow callbacks: \(controller.tapStats.slowCallbackCount)")
        }
        #endif

        Divider()

        Button("Quit Dictate") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var hotkeyLine: String {
        switch controller.hotkeyStatus {
        case .running: "Hold \(controller.triggerDescription) to dictate"
        case .waitingForPermission: "Hotkey off: needs Accessibility"
        case .failed: "Hotkey off: relaunch needed"
        }
    }

    private var lastReason: String {
        controller.tapStats.lastReenableReason.map { " (last: \($0))" } ?? ""
    }

    /// One line: the start of the transcript, and where it went.
    private static func menuTitle(for record: TranscriptRecord) -> String {
        let text = record.text.count > 60 ? record.text.prefix(59) + "…" : record.text
        return record.appName.map { "\(text)  —  \($0)" } ?? String(text)
    }
}
