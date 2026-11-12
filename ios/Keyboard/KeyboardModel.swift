import Observation
import PostProcessKit
import UIKit

/// The keyboard's state: the session as the app reports it, the mic button, and typing.
@MainActor
@Observable
final class KeyboardModel {
    enum Shift { case off, once, locked }
    enum Page { case letters, numbers, symbols }

    // MARK: Session, as the app reports it

    private(set) var phase: SessionChannel.Phase = .off
    private(set) var level: Float = 0
    /// A short message in the mic bar, e.g. "Didn't hear anything".
    private(set) var notice: String?
    /// Recording continues after the finger lifts (a short tap locks it); the next tap stops.
    private(set) var isLocked = false
    /// The press is waiting for its transcript.
    private(set) var isWaiting = false
    private(set) var hasFullAccess = false
    private(set) var showsGlobe = true

    // MARK: Typing

    var shift: Shift = .once
    var page: Page = .letters

    private unowned let controller: KeyboardViewController
    @ObservationIgnored private var request: Int?
    @ObservationIgnored private var pressedAt: Date?
    @ObservationIgnored private var waitingSince: Date?
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var noticeTimer: Timer?
    @ObservationIgnored private var observer: SessionChannel.Observer?
    @ObservationIgnored private var lastShiftTap: Date?

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }

    // MARK: Lifecycle

    func appear() {
        hasFullAccess = controller.hasFullAccess
        showsGlobe = controller.needsInputModeSwitchKey
        if hasFullAccess { SessionChannel.markKeyboardSeen() }
        observer = SessionChannel.observe(.changed) { [weak self] in self?.poll() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
        textDidChange()
    }

    func disappear() {
        // Don't leave the app recording when the keyboard goes away.
        if phase == .recording, request != nil { SessionChannel.post(.cancel) }
        reset()
        pollTimer?.invalidate()
        pollTimer = nil
        observer = nil
    }

    private func reset() {
        request = nil
        pressedAt = nil
        isLocked = false
        isWaiting = false
        waitingSince = nil
    }

    /// Reads the app's state, and types the transcript once it arrives.
    func poll() {
        guard hasFullAccess else { return }
        phase = SessionChannel.phase
        level = phase == .recording ? SessionChannel.level : 0

        guard isWaiting, let request else { return }
        if let text = SessionChannel.result(for: request) {
            reset()
            insertDictation(text)
        } else if let message = SessionChannel.notice(for: request) {
            reset()
            if !message.isEmpty { show(message) }
        } else if phase == .off {
            reset()
            show("The session ended. Tap the mic to start a new one")
        } else if let since = waitingSince, Date().timeIntervalSince(since) > 60 {
            reset()
            show("No answer from Wispr Faux")
        }
    }

    // MARK: Mic button

    func micPressed() {
        notice = nil
        guard hasFullAccess else {
            show("Turn on Allow Full Access: Settings → General → Keyboard → Keyboards → Wispr Faux")
            return
        }
        if isWaiting { return } // Still transcribing the last one.
        if isLocked {
            stop()
            return
        }
        guard SessionChannel.isSessionAlive else {
            show("Starting a session in Wispr Faux… then come back with ◀")
            controller.openApp(SessionChannel.startSessionURL)
            return
        }
        let id = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000
        request = id
        pressedAt = Date()
        SessionChannel.currentRequest = id
        SessionChannel.post(.start)
        phase = .recording
    }

    func micReleased() {
        guard let pressedAt, request != nil, !isLocked, !isWaiting else { return }
        if Date().timeIntervalSince(pressedAt) < 0.3 {
            // A tap: keep listening hands-free until the next tap.
            isLocked = true
            return
        }
        stop()
    }

    private func stop() {
        isLocked = false
        isWaiting = true
        waitingSince = Date()
        pressedAt = nil
        SessionChannel.post(.stop)
        phase = .transcribing
    }

    func cancel() {
        guard request != nil else { return }
        SessionChannel.post(.cancel)
        reset()
        show("Cancelled")
    }

    private func show(_ message: String) {
        notice = message
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.notice = nil }
        }
    }

    // MARK: Typing

    private func insertDictation(_ text: String) {
        let before = proxy.documentContextBeforeInput?.last
        proxy.insertText(TextCleaner.needsLeadingSpace(after: before) ? " " + text : text)
        textDidChange()
    }

    func type(_ key: String) {
        var text = key
        if page == .letters, shift != .off { text = key.uppercased() }
        proxy.insertText(text)
        if shift == .once { shift = .off }
        if page != .letters, key == "'" { page = .letters }
    }

    func space() {
        // Two spaces after a word end the sentence, as on the system keyboard.
        if let before = proxy.documentContextBeforeInput, before.hasSuffix(" "),
           let last = before.dropLast().last, last.isLetter || last.isNumber {
            proxy.deleteBackward()
            proxy.insertText(". ")
        } else {
            proxy.insertText(" ")
        }
        if page != .letters { page = .letters }
        textDidChange()
    }

    func deleteBackward() {
        proxy.deleteBackward()
    }

    func returnKey() {
        proxy.insertText("\n")
        textDidChange()
    }

    func shiftTapped() {
        let now = Date()
        if let last = lastShiftTap, now.timeIntervalSince(last) < 0.35 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
    }

    func nextKeyboard() {
        controller.advanceToNextInputMode()
    }

    var returnKeyTitle: String {
        switch proxy.returnKeyType ?? .default {
        case .go: "go"
        case .search, .google, .yahoo: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        case .join: "join"
        default: "return"
        }
    }

    /// Capitalises the first letter of a sentence, like the system keyboard.
    func textDidChange() {
        guard shift != .locked else { return }
        let autocap = proxy.autocapitalizationType ?? .sentences
        guard autocap != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = proxy.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let atSentenceStart = trimmed.isEmpty || before.hasSuffix("\n")
            || (before.hasSuffix(" ") && [".", "!", "?"].contains(trimmed.last.map(String.init) ?? ""))
        shift = atSentenceStart ? .once : .off
    }
}
