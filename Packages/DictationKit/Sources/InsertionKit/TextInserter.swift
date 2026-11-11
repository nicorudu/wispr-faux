import AppKit
import Foundation
import HotkeyKit
import os

/// Timings observed in the teardown (BUILD_PLAN.md, Appendix).
public enum PasteTiming {
    public static let keyDownToUp: Duration = .milliseconds(5)
    public static let afterPasteboardWrite: Duration = .milliseconds(10)
    public static let afterCommandV: Duration = .milliseconds(10)
    /// Restoring sooner risks the target app pasting the old clipboard.
    public static let beforeRestore: Duration = .milliseconds(500)
}

/// Inserts text into the focused app by pasting it (BUILD_PLAN.md §1, "Insertion"):
/// 1. back up every pasteboard item;
/// 2. clear and write the string, marked transient for clipboard managers;
/// 3. wait briefly and check the pasteboard still holds it;
/// 4. post a layout-aware ⌘V tagged with `syntheticEventTag`;
/// 5. restore the backup after `PasteTiming.beforeRestore`, unless the user copied
///    something in the meantime.
///
/// `insert(_:)` returns once ⌘V has been sent; the restore happens later, and its result
/// goes to `onRestore`. An insert that arrives before the previous restore reuses the
/// backup that is still waiting, so the user's clipboard is never lost between pastes.
@MainActor
public final class TextInserter {
    public enum InsertionError: Error, LocalizedError, Equatable {
        /// Another insert is still running.
        case busy
        /// No Accessibility access, so macOS would drop the synthetic ⌘V.
        case notAllowedToPostEvents
        /// The text didn't stick on the pasteboard. The backup has been put back.
        case pasteboardWriteFailed

        public var errorDescription: String? {
            switch self {
            case .busy: "Another paste is still in progress."
            case .notAllowedToPostEvents: "Dictate needs Accessibility access to paste."
            case .pasteboardWriteFailed: "Couldn't put the text on the clipboard."
            }
        }
    }

    public struct Report: Sendable {
        /// What was backed up (or is still backed up from an earlier insert).
        public var backup: PasteboardSnapshot.Summary
        /// The backup was carried over from an insert whose restore hadn't run yet.
        public var reusedPendingBackup: Bool
        public var backupDuration: Duration
        /// From the call to the ⌘V key up.
        public var pasteLatency: Duration
        public var vKeyCode: CGKeyCode
        /// Modifiers held while ⌘V was posted (they may change what the app does).
        public var heldModifiers: [String]
    }

    public enum RestoreOutcome: Sendable, Equatable {
        /// The clipboard is back as it was. `verified` is set when `verifiesRestore` is on
        /// and the clipboard read back identical to the backup.
        case restored(PasteboardSnapshot.Summary, verified: Bool?)
        /// The clipboard changed after the paste (the user copied something), so the backup
        /// was dropped instead of overwriting it.
        case skippedClipboardChanged
        /// The pasteboard refused the backup.
        case failed
    }

    /// Called on the main actor after each restore attempt.
    public var onRestore: ((RestoreOutcome) -> Void)?
    /// Read the clipboard back after restoring and compare it with the backup. Doubles the
    /// work for large clipboards; meant for testing.
    public var verifiesRestore = false

    public private(set) var isInserting = false

    private let pasteboard: NSPasteboard
    private let keySender: any PasteKeySender
    private let restoreDelay: Duration
    private var pending: PendingRestore?
    private var nextRestoreID = 0
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Insertion")

    private struct PendingRestore {
        let id: Int
        let snapshot: PasteboardSnapshot
        /// The pasteboard's `changeCount` right after Dictate wrote its text.
        let changeCount: Int
        let task: Task<Void, Never>
    }

    public convenience init() {
        self.init(pasteboard: .general, keySender: KeyPoster(), restoreDelay: PasteTiming.beforeRestore)
    }

    init(pasteboard: NSPasteboard, keySender: any PasteKeySender, restoreDelay: Duration) {
        self.pasteboard = pasteboard
        self.keySender = keySender
        self.restoreDelay = restoreDelay
    }

    /// Tag stamped on every synthetic key event so `EventTapMonitor` ignores it.
    nonisolated public static let eventTag = syntheticEventTag

    /// A backup is waiting to be put back.
    public var hasPendingRestore: Bool { pending != nil }

    // MARK: - Insert

    /// Pastes `text` into the focused app. Throws before touching the clipboard when it
    /// can't paste.
    @discardableResult
    public func insert(_ text: String) async throws -> Report {
        guard !isInserting else { throw InsertionError.busy }
        guard keySender.canPost else { throw InsertionError.notAllowedToPostEvents }
        isInserting = true
        defer { isInserting = false }
        let start = ContinuousClock.now

        // 1. Back up. If an earlier restore is still waiting and nobody has copied since,
        //    the pasteboard holds Dictate's previous text: keep the original backup.
        let backup: PasteboardSnapshot
        let reused: Bool
        if let pending, pasteboard.changeCount == pending.changeCount {
            backup = pending.snapshot
            reused = true
        } else {
            backup = PasteboardSnapshot(capturing: pasteboard)
            reused = false
        }
        pending?.task.cancel()
        pending = nil
        let backupDuration = ContinuousClock.now - start

        // 2. Write the text.
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .transient)
        let wrote = pasteboard.writeObjects([item])
        let writtenChangeCount = pasteboard.changeCount

        // 3. Give the pasteboard a moment, then make sure the text is still what's on it.
        try? await Task.sleep(for: PasteTiming.afterPasteboardWrite)
        guard wrote, pasteboard.changeCount == writtenChangeCount,
              pasteboard.string(forType: .string) == text
        else {
            if pasteboard.changeCount == writtenChangeCount {
                backup.write(to: pasteboard)
            }
            log.error("Pasteboard write didn't stick; nothing pasted")
            throw InsertionError.pasteboardWriteFailed
        }

        // 4. ⌘V.
        let held = KeyPoster.heldModifierNames
        if !held.isEmpty {
            log.warning("Modifiers held during paste: \(held.joined(), privacy: .public)")
        }
        let vKeyCode = await keySender.sendPaste()
        let pasteLatency = ContinuousClock.now - start
        try? await Task.sleep(for: PasteTiming.afterCommandV)

        // 5. Put the user's clipboard back later.
        scheduleRestore(of: backup, expectingChangeCount: writtenChangeCount)

        let report = Report(
            backup: backup.summary,
            reusedPendingBackup: reused,
            backupDuration: backupDuration,
            pasteLatency: pasteLatency,
            vKeyCode: vKeyCode,
            heldModifiers: held
        )
        log.notice("""
            Pasted \(text.count, privacy: .public) chars in \(Self.ms(pasteLatency), privacy: .public) ms \
            (V keycode \(vKeyCode, privacy: .public)); backup: \(report.backup.description, privacy: .public)\
            \(reused ? " (reused)" : "", privacy: .public) in \(Self.ms(backupDuration), privacy: .public) ms
            """)
        return report
    }

    // MARK: - Restore

    /// Puts the backup back right away instead of waiting, e.g. when the app quits.
    @discardableResult
    public func restoreNow() -> RestoreOutcome? {
        guard let pending else { return nil }
        return restore(pending)
    }

    private func scheduleRestore(of snapshot: PasteboardSnapshot, expectingChangeCount changeCount: Int) {
        nextRestoreID += 1
        let id = nextRestoreID
        let delay = restoreDelay
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let pending = self.pending, pending.id == id else { return }
            self.restore(pending)
        }
        pending = PendingRestore(id: id, snapshot: snapshot, changeCount: changeCount, task: task)
    }

    @discardableResult
    private func restore(_ pending: PendingRestore) -> RestoreOutcome {
        pending.task.cancel()
        self.pending = nil

        let outcome: RestoreOutcome
        if pasteboard.changeCount != pending.changeCount {
            outcome = .skippedClipboardChanged
        } else if pending.snapshot.write(to: pasteboard) {
            let verified = verifiesRestore ? PasteboardSnapshot(capturing: pasteboard) == pending.snapshot : nil
            outcome = .restored(pending.snapshot.summary, verified: verified)
        } else {
            outcome = .failed
        }

        switch outcome {
        case .restored(let summary, let verified):
            let check = verified.map { $0 ? ", verified identical" : ", DIFFERS from backup" } ?? ""
            log.notice("Clipboard restored: \(summary.description, privacy: .public)\(check, privacy: .public)")
        case .skippedClipboardChanged:
            log.notice("Clipboard changed after the paste; backup dropped")
        case .failed:
            log.error("Clipboard restore failed")
        }
        onRestore?(outcome)
        return outcome
    }

    private static func ms(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}
