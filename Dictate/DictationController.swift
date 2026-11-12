import AppKit
import AudioKit
import HistoryKit
import HotkeyKit
import InsertionKit
import Observation
import os
import TranscriptionKit

/// Owns the dictation state machine (BUILD_PLAN.md §2):
///
///     idle ─hotkey down─▶ recording ─hotkey up─▶ transcribing ─▶ inserting ─▶ idle
///
/// Step 2 wires in the hotkey and permissions: holding the trigger switches to
/// `.recording` (the menu bar icon fills in) and every event is logged. Step 3 adds the
/// `inserter`, exercised for now by `pasteTester`. Step 4 records while the trigger is
/// held and hands the audio to `recordingTester` for playback. Step 5 transcribes each
/// recording with `transcription` and shows the text in the menu. Step 6 pastes it.
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

    /// Pastes text into the focused app and puts the clipboard back afterwards.
    let inserter = TextInserter()
    /// Step 3 spike: "Paste Test String" in the menu.
    let pasteTester: PasteTester

    /// Records the microphone while the trigger is held.
    let recorder = MicrophoneRecorder()
    /// Step 4 spike: plays back the last recording and shows its stats in the menu.
    let recordingTester = RecordingTester()
    /// Live microphone level, 0…1, while recording; 0 otherwise.
    private(set) var inputLevel: Float = 0

    /// On-device Whisper: loads at launch, transcribes each recording.
    let transcription = TranscriptionService()
    @ObservationIgnored private let speechGate = SpeechGate()

    @ObservationIgnored private let monitor: EventTapMonitor
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var pressStartedAt: ContinuousClock.Instant?
    /// Permission state at the last failed tap start; a change allows another attempt.
    @ObservationIgnored private var permissionsAtLastFailure: [PermissionStatus]?
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Hotkey")
    @ObservationIgnored private let audioLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Audio")

    private static let triggersDefaultsKey = "hotkey.triggers"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.triggersDefaultsKey) ?? []
        let parsed = Set(saved.compactMap(HotkeyTrigger.init(rawValue:)))
        let triggers = parsed.isEmpty ? HotkeyTrigger.defaultTriggers : parsed
        enabledTriggers = triggers
        monitor = EventTapMonitor(triggers: triggers)
        pasteTester = PasteTester(inserter: inserter)
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        transcription.loadIfDownloaded()
        log.notice("""
            Started. Microphone: \(String(describing: self.permissions.microphone), privacy: .public), \
            Accessibility: \(String(describing: self.permissions.accessibility), privacy: .public), \
            Input Monitoring: \(String(describing: self.permissions.inputMonitoring), privacy: .public), \
            triggers: \(self.triggerDescription, privacy: .public)
            """)
        eventTask = Task { [weak self, events = monitor.events] in
            // One event at a time: a release waits for the microphone to finish starting.
            for await event in events {
                await self?.handle(event)
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
        // Don't quit with Dictate's text still standing in for the user's clipboard.
        inserter.restoreNow()
        recordingTester.deleteRecording()
    }

    func refreshNow() {
        _ = poll()
    }

    // MARK: - Hotkey events

    private func handle(_ event: HotkeyEvent) async {
        switch event {
        case .pushToTalkPressed:
            let requestedAt = mach_absolute_time()
            pressStartedAt = .now
            isHandsFree = false
            state = .recording
            log.notice("Push-to-talk down")
            await startRecording(requestedAt: requestedAt)

        case .handsFreeToggled:
            isHandsFree = true
            log.notice("Hands-free locked")

        case .pushToTalkReleased:
            let releasedAt = mach_absolute_time()
            let releaseInstant = ContinuousClock.now
            let held = pressStartedAt.map { ContinuousClock.now - $0 }
            lastHoldDuration = held
            log.notice("Push-to-talk up after \(Self.milliseconds(held), privacy: .public) ms")
            let recording = await finishRecording(keep: true, heldFor: held, releasedAt: releasedAt)
            endSession()
            if let recording { startTranscription(of: recording, releasedAt: releaseInstant) }

        case .cancel:
            log.notice("Dictation cancelled")
            await finishRecording(keep: false, heldFor: nil, releasedAt: mach_absolute_time())
            endSession()
        }
    }

    // MARK: - Recording

    private func startRecording(requestedAt: UInt64) async {
        recordingTester.stopPlayback()
        permissions.refresh()
        guard permissions.microphone == .granted else {
            recordingTester.didFail("Not recording: Microphone access is off (see Permissions…)")
            audioLog.notice("Not recording: microphone permission is \(String(describing: self.permissions.microphone), privacy: .public)")
            return
        }
        do {
            let device = try await recorder.start(requestedAt: requestedAt)
            audioLog.notice("""
                Recording from \(device.name, privacy: .public) \
                (\(device.transport.rawValue, privacy: .public), \(Int(device.sampleRate), privacy: .public) Hz \
                × \(device.channelCount, privacy: .public) ch)
                """)
            startLevelUpdates()
        } catch {
            recordingTester.didFail("Not recording: \(error.localizedDescription)")
            audioLog.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the microphone. `keep` hands the audio to the recording tester; otherwise
    /// it's thrown away (Esc).
    @discardableResult
    private func finishRecording(keep: Bool, heldFor: Duration?, releasedAt: UInt64) async -> Recording? {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
        guard keep else {
            await recorder.cancel()
            return nil
        }
        let recording = await recorder.stop(releasedAt: releasedAt)
        if let recording {
            recordingTester.didRecord(recording, heldFor: heldFor)
        }
        return recording
    }

    /// Transcribes in the background, so the hotkey stays responsive meanwhile.
    private func startTranscription(of recording: Recording, releasedAt: ContinuousClock.Instant) {
        let verdict = speechGate.verdict(duration: recording.duration, levels: recording.levels)
        guard verdict == .speech else {
            transcription.skip(verdict)
            return
        }
        state = .transcribing
        Task {
            await transcription.transcribe(recording, releasedAt: releasedAt)
            // A new recording may have started meanwhile; leave its state alone.
            if state == .transcribing { state = .idle }
        }
    }

    /// Mirrors the recorder's level into `inputLevel` for the setup window's meter.
    private func startLevelUpdates() {
        levelTask?.cancel()
        levelTask = Task { [weak self, recorder] in
            while !Task.isCancelled {
                guard let self else { return }
                let level = recorder.level
                if abs(level - inputLevel) > 0.01 { inputLevel = level }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    #if DEBUG
    /// Records for `seconds` without the hotkey, to check the microphone path from a
    /// script or the Debug menu: `open Dictate.app --args -DebugRecordSeconds 3`.
    func debugRecord(seconds: Double) {
        guard state == .idle else { return }
        Task {
            state = .recording
            await startRecording(requestedAt: mach_absolute_time())
            try? await Task.sleep(for: .seconds(seconds))
            let releaseInstant = ContinuousClock.now
            let recording = await finishRecording(keep: true, heldFor: .seconds(seconds), releasedAt: mach_absolute_time())
            endSession()
            if let recording { startTranscription(of: recording, releasedAt: releaseInstant) }
        }
    }
    #endif

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

    /// Plain-language name of the enabled triggers, e.g. "Control (⌃) or Fn (🌐)".
    var triggerDescription: String {
        var names = HotkeyTrigger.allCases
            .filter(enabledTriggers.contains)
            .map(\.displayName)
        if enabledTriggers.isSuperset(of: [.leftControl, .rightControl]) {
            // "Left Control or Right Control" reads better as one key.
            names.removeAll { $0 == HotkeyTrigger.rightControl.displayName }
            names[names.firstIndex(of: HotkeyTrigger.leftControl.displayName)!] = "Control (⌃)"
        }
        return names.joined(separator: " or ")
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
