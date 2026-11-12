import AppKit
import AudioKit
import ContextKit
import HistoryKit
import HotkeyKit
import InsertionKit
import Observation
import os
import PostProcessKit
import TranscriptionKit

/// Owns the dictation state machine (BUILD_PLAN.md §2):
///
///     idle ─hotkey down─▶ recording ─hotkey up─▶ transcribing ─▶ inserting ─▶ idle
///
/// Holding the trigger records (`recorder`); releasing it stops the mic, and a recording
/// that passes the speech gate is transcribed on-device (`transcription`), cleaned up,
/// and pasted into the focused field (`inserter`), with the user's clipboard put back.
/// Password fields are never pasted into; when focus isn't on a text field, or the user
/// switched apps meanwhile, the text is copied instead and the pill says so. Esc cancels
/// while recording or transcribing. Every transcript goes into `history`.
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
    let loginItem = LoginItem()

    /// The last 100 transcripts, kept on disk; backs Paste Last and the Recent menu.
    let history = HistoryStore(
        capacity: 100,
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Dictate/history.json")
    )
    /// Newest first, mirrored from `history` for the menu.
    private(set) var recentTranscripts: [TranscriptRecord] = []

    /// Pastes text into the focused app and puts the clipboard back afterwards.
    let inserter = TextInserter()
    @ObservationIgnored private let fieldReader = FocusedFieldReader()
    @ObservationIgnored private let cleaner = TextCleaner()

    /// A short message for the pill; clears itself after a few seconds.
    private(set) var notice: Notice?
    /// Timings of the last dictation, for the Debug menu.
    private(set) var lastTiming: String?

    /// Records the microphone while the trigger is held.
    let recorder = MicrophoneRecorder()
    /// Step 4 spike: plays back the last recording and shows its stats in the menu.
    let recordingTester = RecordingTester()
    /// Live microphone level, 0…1, while recording; 0 otherwise.
    private(set) var inputLevel: Float = 0

    /// Counts presses, so a cancelled dictation's late transcript can be recognised.
    @ObservationIgnored private var dictationCount = 0
    /// The dictation being transcribed, if any (what Esc cancels after release).
    @ObservationIgnored private var transcribingID: Int?
    @ObservationIgnored private var cancelledIDs: Set<Int> = []
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

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
    @ObservationIgnored private let pasteLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "Paste")

    private static let triggersDefaultsKey = "hotkey.triggers"

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.triggersDefaultsKey) ?? []
        let parsed = Set(saved.compactMap(HotkeyTrigger.init(rawValue:)))
        let triggers = parsed.isEmpty ? HotkeyTrigger.defaultTriggers : parsed
        enabledTriggers = triggers
        monitor = EventTapMonitor(triggers: triggers)
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        transcription.loadIfDownloaded()
        Task { recentTranscripts = await history.all }
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
            dictationCount += 1
            pressStartedAt = .now
            isHandsFree = false
            clearNotice()
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
            let recording = await finishRecording(keep: true, releasedAt: releasedAt)
            endSession()
            if let recording { handOff(recording, heldFor: held, id: dictationCount, releasedAt: releaseInstant) }

        case .cancel:
            if pressStartedAt != nil {
                log.notice("Dictation cancelled while recording")
                await finishRecording(keep: false, releasedAt: mach_absolute_time())
                endSession()
            } else if let id = transcribingID {
                // Esc after release: drop the transcript when it arrives.
                log.notice("Dictation cancelled while transcribing")
                cancelledIDs.insert(id)
                finishTranscribing(id)
                state = .idle
                showNotice(Notice(text: "Cancelled", systemImage: "xmark.circle"))
            }
        }
    }

    // MARK: - Recording

    private func startRecording(requestedAt: UInt64) async {
        recordingTester.stopPlayback()
        permissions.refresh()
        guard permissions.microphone == .granted else {
            recordingTester.didFail("Not recording: Microphone access is off (see Permissions…)")
            audioLog.notice("Not recording: microphone permission is \(String(describing: self.permissions.microphone), privacy: .public)")
            state = .idle
            showNotice(Notice(text: "Microphone access is off. See Permissions in the menu", systemImage: "mic.slash", isWarning: true))
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
            state = .idle
            showNotice(Notice(text: error.localizedDescription, systemImage: "mic.slash", isWarning: true))
        }
    }

    /// Stops the microphone. `keep` hands the audio to the recording tester; otherwise
    /// it's thrown away (Esc).
    @discardableResult
    private func finishRecording(keep: Bool, releasedAt: UInt64) async -> Recording? {
        levelTask?.cancel()
        levelTask = nil
        inputLevel = 0
        guard keep else {
            await recorder.cancel()
            return nil
        }
        return await recorder.stop(releasedAt: releasedAt)
    }

    // MARK: - Transcribing and pasting

    /// Starts transcribing, then logs the recording (and in Debug builds saves its WAV).
    /// Main-actor tasks run in order, so that bookkeeping waits until transcription has
    /// handed the audio to the Neural Engine and never delays the text.
    private func handOff(_ recording: Recording, heldFor: Duration?, id: Int, releasedAt: ContinuousClock.Instant) {
        startTranscription(of: recording, id: id, releasedAt: releasedAt)
        Task { recordingTester.didRecord(recording, heldFor: heldFor) }
    }

    /// Transcribes in the background, so the hotkey stays responsive meanwhile, then
    /// delivers the text to the app that was in front at release.
    private func startTranscription(of recording: Recording, id: Int, releasedAt: ContinuousClock.Instant) {
        switch speechGate.verdict(duration: recording.duration, levels: recording.levels) {
        case .speech:
            break
        case .tooShort:
            return // An accidental tap: nothing to say about it.
        case .tooQuiet:
            showNotice(Notice(text: "Didn't hear anything. Check the microphone", systemImage: "mic.slash", isWarning: true))
            return
        }
        guard transcription.isAvailable else {
            showNotice(Notice(text: "Download the model first (see the menu)", systemImage: "arrow.down.circle", isWarning: true))
            return
        }
        let targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state = .transcribing
        transcribingID = id
        monitor.setEscapeCancels(true)

        Task {
            let result = await transcription.transcribe(recording, releasedAt: releasedAt)
            finishTranscribing(id)
            guard !cancelledIDs.contains(id) else {
                cancelledIDs.remove(id)
                return
            }
            if state == .transcribing { state = .inserting }
            if let result {
                await deliver(result, recording: recording, targetApp: targetApp, releasedAt: releasedAt)
            } else {
                showNotice(Notice(text: "Transcription failed", systemImage: "exclamationmark.triangle", isWarning: true))
            }
            // A new recording may have started meanwhile; leave its state alone.
            if state == .inserting || state == .transcribing { state = .idle }
        }
    }

    private func finishTranscribing(_ id: Int) {
        guard transcribingID == id else { return }
        transcribingID = nil
        monitor.setEscapeCancels(false)
    }

    private func deliver(
        _ result: TranscriptionService.Result,
        recording: Recording,
        targetApp: pid_t?,
        releasedAt: ContinuousClock.Instant
    ) async {
        let text = cleaner.clean(result.text)
        // Whisper describes silence ("[BLANK_AUDIO]") or invents a polite phrase for it.
        let quiet = recording.levels.loudestWindowDBFS < -40
        if text.isEmpty || TextCleaner.isNonSpeechMarker(text) || (quiet && TextCleaner.isLikelySilenceArtifact(text)) {
            pasteLog.notice("Dropped a non-speech transcript (\(text.count, privacy: .public) characters)")
            showNotice(Notice(text: "Didn't catch that", systemImage: "questionmark.bubble"))
            return
        }

        let field = fieldReader.read()
        await history.add(TranscriptRecord(text: text, appBundleID: field.appBundleID, appName: field.appName))
        recentTranscripts = await history.all

        let switchedApps = targetApp != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier != targetApp
        let outcome = await insertOrCopy(text, into: field, switchedApps: switchedApps)
        let releaseToPaste = ContinuousClock.now - releasedAt

        lastTiming = """
            \(Self.seconds(result.audioDuration)) s audio → \(Self.seconds(result.processingDuration)) s to transcribe → \
            \(outcome) \(Self.seconds(releaseToPaste)) s after release
            """
        pasteLog.notice("""
            \(outcome, privacy: .public) \(text.count, privacy: .public) characters into \
            \(field.appBundleID ?? "?", privacy: .public) (\(field.role ?? "no role", privacy: .public)\
            \(field.subrole.map { "/" + $0 } ?? "", privacy: .public), \(String(describing: field.kind), privacy: .public)). \
            Release to \(outcome, privacy: .public): \(Self.milliseconds(releaseToPaste), privacy: .public) ms \
            (transcribe \(Self.milliseconds(result.processingDuration), privacy: .public) ms \
            for \(Self.milliseconds(result.audioDuration), privacy: .public) ms of audio)
            """)
    }

    /// Pastes `text` into the focused field, or copies it when pasting isn't safe, and
    /// says which in the pill. Returns "pasted" or "copied".
    private func insertOrCopy(_ text: String, into field: FocusedFieldInfo, switchedApps: Bool) async -> String {
        switch field.kind {
        case .secure:
            copyToClipboard(text)
            showNotice(Notice(text: "Password field: not pasted. Copied instead", systemImage: "lock", isWarning: true))
            return "copied"
        case .notText:
            copyToClipboard(text)
            showNotice(Notice(text: "No text field. Copied: press ⌘V to paste", systemImage: "doc.on.clipboard"))
            return "copied"
        case .text, .unknown:
            break
        }
        if switchedApps {
            copyToClipboard(text)
            showNotice(Notice(text: "You switched apps. Copied: press ⌘V to paste", systemImage: "doc.on.clipboard"))
            return "copied"
        }

        let spaced = TextCleaner.needsLeadingSpace(after: field.characterBeforeInsertionPoint) ? " " + text : text
        // Two transcripts can finish close together; paste them one after the other.
        while inserter.isInserting {
            try? await Task.sleep(for: .milliseconds(20))
        }
        do {
            _ = try await inserter.insert(spaced)
            return "pasted"
        } catch {
            copyToClipboard(text)
            showNotice(Notice(text: "Couldn't paste (\(error.localizedDescription)). Copied instead", systemImage: "exclamationmark.triangle", isWarning: true))
            pasteLog.error("Paste failed: \(error.localizedDescription, privacy: .public)")
            return "copied"
        }
    }

    // MARK: - Menu actions

    /// Pastes the newest transcript into the app in front.
    func pasteLastTranscript() {
        Task {
            // Let the menu finish closing so ⌘V reaches the app underneath.
            try? await Task.sleep(for: .milliseconds(250))
            guard let record = await history.latest else { return }
            let outcome = await insertOrCopy(record.text, into: fieldReader.read(), switchedApps: false)
            pasteLog.notice("Paste Last: \(outcome, privacy: .public) \(record.text.count, privacy: .public) characters")
        }
    }

    func copyLastTranscript() {
        Task {
            guard let record = await history.latest else { return }
            copy(record)
        }
    }

    func copy(_ record: TranscriptRecord) {
        copyToClipboard(record.text)
        showNotice(Notice(text: "Copied", systemImage: "doc.on.clipboard"))
    }

    func clearHistory() {
        Task {
            await history.removeAll()
            recentTranscripts = []
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Pill

    /// What the status pill shows; nil hides it.
    var pillContent: PillContent? {
        switch state {
        case .recording: .listening(handsFree: isHandsFree)
        case .transcribing, .inserting: .transcribing
        case .idle: notice.map(PillContent.notice)
        }
    }

    private func showNotice(_ newNotice: Notice) {
        notice = newNotice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(newNotice.isWarning ? 4 : 2.5))
            guard !Task.isCancelled, let self, self.notice?.id == newNotice.id else { return }
            self.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    /// The trigger's key symbol for short hints, e.g. "⌃".
    var triggerSymbol: String {
        if enabledTriggers.contains(.leftControl) || enabledTriggers.contains(.rightControl) { return "⌃" }
        if enabledTriggers.contains(.fn) { return "🌐" }
        if enabledTriggers.contains(.rightOption) { return "⌥" }
        return "⌘"
    }

    private static func seconds(_ duration: Duration) -> String {
        (duration / .seconds(1)).formatted(.number.precision(.fractionLength(2)))
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
            dictationCount += 1
            let recording = await finishRecording(keep: true, releasedAt: mach_absolute_time())
            endSession()
            if let recording { handOff(recording, heldFor: .seconds(seconds), id: dictationCount, releasedAt: releaseInstant) }
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
