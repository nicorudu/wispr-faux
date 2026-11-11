import AppKit
import HistoryKit
import HotkeyKit
import Observation
import os

/// Owns the dictation state machine (BUILD_PLAN.md §2):
///
///     idle ─hotkey down─▶ recording ─hotkey up─▶ transcribing ─▶ inserting ─▶ idle
///
/// Step 2 wires in the hotkey and permissions: holding the trigger switches to
/// `.recording` (the menu bar icon fills in) and every event is logged. Audio (Step 4),
/// transcription (Step 5) and insertion (Step 3) hook into `handle(_:)` in Step 6.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case inserting

        var label: String {
            switch self {
            case .idle: "Idle"
            case .recording: "Listening…"
            case .transcribing: "Transcribing…"
            case .inserting: "Inserting…"
            }
        }

        var menuBarSymbol: String {
            switch self {
            case .idle: "mic"
            case .recording: "mic.fill"
            case .transcribing, .inserting: "ellipsis.circle"
            }
        }
    }

    enum HotkeyStatus: Equatable {
        /// The event tap can't start until Accessibility is granted.
        case waitingForPermission
        case running
        /// Permissions look granted but macOS still refused the tap. Usually fixed by
        /// relaunching after granting Input Monitoring.
        case failed
    }

    private(set) var state: State = .idle
    /// Locked with trigger + Space: recording continues after the trigger is released.
    private(set) var isHandsFree = false
    /// How long the last push-to-talk was held, for the setup window's test area.
    private(set) var lastHoldDuration: Duration?

    private(set) var hotkeyStatus: HotkeyStatus = .waitingForPermission
    private(set) var isSecureInputActive = false
    private(set) var tapStats = TapStats()

    /// Keys that start dictation when held. Persisted; at least one stays enabled.
    private(set) var enabledTriggers: Set<HotkeyTrigger>

    /// Set by the setup window; while it's open, permissions are polled every second.
    var isSetupWindowVisible = false {
        didSet { if isSetupWindowVisible { refreshNow() } }
    }

    let permissions = PermissionsManager()

    /// Recent transcripts; backs "Paste Last Transcript".
    let history = HistoryStore(capacity: 100)

    @ObservationIgnored private let monitor: EventTapMonitor
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pressStartedAt: ContinuousClock.Instant?
    /// Permission state at the last failed tap start; a change allows another attempt.
    @ObservationIgnored private var permissionsAtLastFailure: [PermissionStatus]?
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Hotkey")

    private static let triggersDefaultsKey = "hotkey.triggers"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.triggersDefaultsKey) ?? []
        let parsed = Set(saved.compactMap(HotkeyTrigger.init(rawValue:)))
        let triggers: Set<HotkeyTrigger> = parsed.isEmpty ? [.fn] : parsed
        enabledTriggers = triggers
        monitor = EventTapMonitor(triggers: triggers)
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        log.notice("""
            Started. Microphone: \(String(describing: self.permissions.microphone), privacy: .public), \
            Accessibility: \(String(describing: self.permissions.accessibility), privacy: .public), \
            Input Monitoring: \(String(describing: self.permissions.inputMonitoring), privacy: .public), \
            triggers: \(self.triggerDescription, privacy: .public)
            """)
        eventTask = Task { [weak self, events = monitor.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        pollTask = Task { [weak self] in
            while let interval = self?.poll() {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        eventTask?.cancel()
        monitor.stop()
    }

    func refreshNow() {
        _ = poll()
    }

    // MARK: - Hotkey events

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pushToTalkPressed:
            pressStartedAt = .now
            isHandsFree = false
            state = .recording
            log.notice("Push-to-talk down")

        case .handsFreeToggled:
            isHandsFree = true
            log.notice("Hands-free locked")

        case .pushToTalkReleased:
            let held = pressStartedAt.map { ContinuousClock.now - $0 }
            lastHoldDuration = held
            endSession()
            log.notice("Push-to-talk up after \(Self.milliseconds(held), privacy: .public) ms")

        case .cancel:
            endSession()
            log.notice("Dictation cancelled")
        }
    }

    private func endSession() {
        pressStartedAt = nil
        isHandsFree = false
        state = .idle
    }

    // MARK: - Settings

    func setTrigger(_ trigger: HotkeyTrigger, enabled: Bool) {
        var triggers = enabledTriggers
        if enabled {
            triggers.insert(trigger)
        } else {
            triggers.remove(trigger)
        }
        guard !triggers.isEmpty, triggers != enabledTriggers else { return }
        enabledTriggers = triggers
        UserDefaults.standard.set(triggers.map(\.rawValue).sorted(), forKey: Self.triggersDefaultsKey)
        monitor.setTriggers(triggers)
    }

    /// Plain-language name of the enabled triggers, e.g. "Fn (🌐) or Right Option (⌥)".
    var triggerDescription: String {
        HotkeyTrigger.allCases
            .filter(enabledTriggers.contains)
            .map(\.displayName)
            .joined(separator: " or ")
    }

    // MARK: - Hotkey health

    /// Tries to start the tap again, e.g. after the user fixed a permission.
    func retryHotkey() {
        permissionsAtLastFailure = nil
        refreshNow()
    }

    func simulateTapTimeout() {
        monitor.simulateStallOnNextEvent()
    }

    /// Refreshes permissions, starts or stops the tap to match them, and returns how long
    /// to wait before the next poll.
    private func poll() -> Duration {
        permissions.refresh(includeGlobeKey: isSetupWindowVisible)
        updateMonitor()

        let secureInput = EventTapMonitor.isSecureEventInputEnabled
        if isSecureInputActive != secureInput {
            isSecureInputActive = secureInput
            log.notice("Secure Event Input is \(secureInput ? "on" : "off", privacy: .public)")
        }
        let stats = monitor.stats
        if tapStats != stats { tapStats = stats }

        // Poll fast while the user is setting things up; slowly otherwise, to notice
        // permissions being revoked and Secure Event Input changing.
        return isSetupWindowVisible || hotkeyStatus != .running ? .seconds(1) : .seconds(5)
    }

    private func updateMonitor() {
        let accessibilityGranted = permissions.accessibility == .granted

        if monitor.isRunning {
            guard !accessibilityGranted else { return }
            monitor.stop()
            hotkeyStatus = .waitingForPermission
            log.notice("Accessibility was revoked; event tap stopped")
            return
        }

        guard accessibilityGranted else {
            if hotkeyStatus != .waitingForPermission { hotkeyStatus = .waitingForPermission }
            return
        }

        // Don't retry every second; wait until a permission changes or the user asks.
        let snapshot = Permission.allCases.map(permissions.status(of:))
        if hotkeyStatus == .failed, snapshot == permissionsAtLastFailure { return }

        do {
            try monitor.start()
            hotkeyStatus = .running
            permissionsAtLastFailure = nil
        } catch {
            hotkeyStatus = .failed
            permissionsAtLastFailure = snapshot
            log.error("Event tap failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func milliseconds(_ duration: Duration?) -> Int {
        guard let duration else { return -1 }
        return Int((duration / .milliseconds(1)).rounded())
    }
}
