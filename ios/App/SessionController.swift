import AVFoundation
import Observation
import os
import PostProcessKit

/// Runs dictation sessions for the keyboard.
///
/// A session starts in the app (iOS only lets an app turn the microphone on while it's in
/// front), then keeps running in the background with the microphone on. While it runs, the
/// keyboard's mic button drives it through `SessionChannel`:
///
///     start ─▶ recording ─stop─▶ transcribing ─▶ cleanup (optional, cloud) ─▶ result ─▶ ready
///
/// The keyboard types the result into the text field. A session ends after the idle time the
/// user picked, when they end it, or when iOS takes the microphone away (a call that doesn't
/// give it back, the app being closed from the app switcher).
@MainActor
@Observable
final class SessionController {
    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    enum SessionLength: Int, CaseIterable, Identifiable {
        case fifteenMinutes = 15
        case oneHour = 60
        case fourHours = 240
        case twelveHours = 720
        case untilEnded = 0

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .fifteenMinutes: "15 minutes"
            case .oneHour: "1 hour"
            case .fourHours: "4 hours"
            case .twelveHours: "12 hours"
            case .untilEnded: "Until I end it"
            }
        }
    }

    struct Language: Hashable {
        let code: String?
        let name: String
    }

    static let languages: [Language] = [
        Language(code: "en", name: "English"), Language(code: nil, name: "Detect automatically"),
        Language(code: "es", name: "Spanish"), Language(code: "fr", name: "French"),
        Language(code: "de", name: "German"), Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"), Language(code: "nl", name: "Dutch"),
        Language(code: "ja", name: "Japanese"), Language(code: "zh", name: "Chinese"),
        Language(code: "ko", name: "Korean"),
    ]

    // MARK: State shown in the app

    private(set) var isSessionActive = false
    private(set) var phase: SessionChannel.Phase = .off
    private(set) var modelStatus: ModelStatus = .notDownloaded
    private(set) var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    private(set) var keyboardSeen = SessionChannel.keyboardSeen
    /// Why the last session ended, when it wasn't the user's doing.
    private(set) var endedReason: String?
    private(set) var startError: String?
    private(set) var recent: [TranscriptRecord] = []
    private(set) var lastTiming: String?
    /// Shown after the keyboard opened the app to start a session.
    var showGoBackHint = false

    var sessionLength: SessionLength {
        didSet {
            UserDefaults.standard.set(sessionLength.rawValue, forKey: "session.length")
            if isSessionActive { scheduleIdleEnd() }
        }
    }

    var languageCode: String? {
        didSet { UserDefaults.standard.set(languageCode ?? "auto", forKey: "language") }
    }

    private(set) var model: WhisperModel

    let cleanup = PhoneCleanup()

    // MARK: Internals

    private let mic = SessionMicrophone()
    private var transcriber: PhoneTranscriber
    private let store = ModelStore.standard
    private let history = HistoryStore(
        capacity: 100,
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Wispr Faux/history.json")
    )
    @ObservationIgnored private var observers: [SessionChannel.Observer] = []
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: Int?
    @ObservationIgnored private var pressedAt: Date?
    @ObservationIgnored private var lastActivity = Date()
    private let log = Logger(subsystem: "WisprFauxPhone", category: "Session")

    init() {
        let defaults = UserDefaults.standard
        sessionLength = SessionLength(rawValue: defaults.object(forKey: "session.length") as? Int ?? 60) ?? .oneHour
        let savedLanguage = defaults.string(forKey: "language") ?? "en"
        languageCode = savedLanguage == "auto" ? nil : savedLanguage
        let model = defaults.string(forKey: "model").flatMap(WhisperModel.named) ?? .largeV3TurboCompressed
        self.model = model
        transcriber = PhoneTranscriber(model: model)

        observers = [
            SessionChannel.observe(.start) { [weak self] in self?.handleStart() },
            SessionChannel.observe(.stop) { [weak self] in self?.handleStop() },
            SessionChannel.observe(.cancel) { [weak self] in self?.handleCancel() },
        ]
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endSession(reason: "iOS reset its audio system") }
        }
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }

        // A session from an earlier launch is gone: the microphone stopped with that process.
        SessionChannel.endHeartbeat()
        SessionChannel.phase = .off
        refreshModelStatus()
        Task { recent = await history.all }
    }

    // MARK: App lifecycle

    /// Called whenever the app comes to the front.
    func becameActive() {
        microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
        keyboardSeen = SessionChannel.keyboardSeen
        if case .ready = modelStatus { return }
        loadModelIfDownloaded()
    }

    /// The keyboard opened the app with wisprfaux://session.
    func openedFromKeyboard() {
        startSession()
        if isSessionActive { showGoBackHint = true }
    }

    // MARK: Microphone permission

    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in self.microphoneAllowed = granted }
        }
    }

    // MARK: Model

    func refreshModelStatus() {
        switch modelStatus {
        case .downloading, .loading: return
        default: modelStatus = store.isDownloaded(model) ? .loading : .notDownloaded
        }
        loadModelIfDownloaded()
    }

    private func loadModelIfDownloaded() {
        guard store.isDownloaded(model) else {
            if case .downloading = modelStatus { return }
            modelStatus = .notDownloaded
            return
        }
        modelStatus = .loading
        let transcriber = transcriber
        Task {
            do {
                let time = try await transcriber.load()
                guard transcriber === self.transcriber else { return }
                modelStatus = .ready
                log.notice("Loaded \(transcriber.model.id, privacy: .public) in \(Int(time / .milliseconds(1)), privacy: .public) ms")
            } catch {
                guard transcriber === self.transcriber else { return }
                modelStatus = .failed(error.localizedDescription)
            }
        }
    }

    func downloadModel() {
        if case .downloading = modelStatus { return }
        modelStatus = .downloading(0)
        let model = model
        Task {
            do {
                try await store.download(model) { fraction in
                    Task { @MainActor in
                        if case .downloading = self.modelStatus, self.model == model { self.modelStatus = .downloading(fraction) }
                    }
                }
                guard self.model == model else { return }
                loadModelIfDownloaded()
            } catch {
                guard self.model == model else { return }
                modelStatus = .failed("Download failed: \(error.localizedDescription)")
            }
        }
    }

    func setModel(_ newModel: WhisperModel) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.id, forKey: "model")
        transcriber = PhoneTranscriber(model: newModel)
        modelStatus = .notDownloaded
        refreshModelStatus()
    }

    // MARK: Session

    func startSession() {
        endedReason = nil
        startError = nil
        guard !isSessionActive else {
            scheduleIdleEnd()
            return
        }
        guard microphoneAllowed else {
            requestMicrophone()
            startError = "Allow the microphone first."
            return
        }
        mic.onHeartbeat = { SessionChannel.beat() }
        mic.onLevel = { SessionChannel.level = $0 }
        do {
            try mic.start()
        } catch {
            startError = "Couldn't start the microphone: \(error.localizedDescription)"
            log.error("Session failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        isSessionActive = true
        SessionChannel.beat()
        setPhase(.ready)
        scheduleIdleEnd()
        loadModelIfDownloaded()
        log.notice("Session started (\(self.sessionLength.title, privacy: .public))")
    }

    func endSession(reason: String? = nil) {
        guard isSessionActive else { return }
        work?.cancel()
        idleTask?.cancel()
        mic.stop()
        isSessionActive = false
        activeRequest = nil
        pressedAt = nil
        endedReason = reason
        SessionChannel.endHeartbeat()
        SessionChannel.endsAt = nil
        setPhase(.off)
        log.notice("Session ended\(reason.map { ": " + $0 } ?? "", privacy: .public)")
    }

    private func setPhase(_ newPhase: SessionChannel.Phase) {
        phase = newPhase
        SessionChannel.phase = newPhase
        if newPhase != .recording { SessionChannel.level = 0 }
        SessionChannel.post(.changed)
    }

    /// Ends the session after the chosen idle time; any dictation pushes it back.
    private func scheduleIdleEnd() {
        lastActivity = Date()
        idleTask?.cancel()
        guard sessionLength != .untilEnded else {
            SessionChannel.endsAt = nil
            return
        }
        let ends = lastActivity.addingTimeInterval(TimeInterval(sessionLength.rawValue * 60))
        SessionChannel.endsAt = ends
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ends.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            self?.endSession(reason: nil)
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isSessionActive, let type else { return }
        switch type {
        case .began:
            log.notice("Audio interrupted")
            if phase == .recording {
                mic.cancelRecording()
                activeRequest = nil
                pressedAt = nil
                setPhase(.ready)
            }
        case .ended:
            do {
                try mic.restart()
                log.notice("Microphone back after the interruption")
            } catch {
                endSession(reason: "A call or another app took the microphone")
            }
        @unknown default:
            break
        }
    }

    /// Headphones plugged in or out: the engine stops and needs restarting.
    private func handleConfigurationChange() {
        guard isSessionActive, !mic.isRunning else { return }
        do {
            try mic.restart()
        } catch {
            endSession(reason: "The microphone changed")
        }
    }

    // MARK: Keyboard requests

    private func handleStart() {
        guard isSessionActive else { return }
        if phase == .recording { mic.cancelRecording() }
        activeRequest = SessionChannel.currentRequest
        pressedAt = Date()
        mic.beginRecording()
        setPhase(.recording)
        scheduleIdleEnd()
    }

    private func handleStop() {
        guard isSessionActive, let request = activeRequest, let pressedAt, phase == .recording else { return }
        self.pressedAt = nil
        let held = Date().timeIntervalSince(pressedAt)
        setPhase(.transcribing)
        work = Task { await finish(request: request, heldFor: held) }
    }

    private func handleCancel() {
        guard isSessionActive else { return }
        switch phase {
        case .recording:
            mic.cancelRecording()
        case .transcribing:
            work?.cancel()
        default:
            break
        }
        activeRequest = nil
        pressedAt = nil
        setPhase(.ready)
    }

    private func finish(request: Int, heldFor held: TimeInterval) async {
        let released = ContinuousClock.now
        let samples = await mic.endRecording()
        defer {
            if activeRequest == request {
                activeRequest = nil
                if isSessionActive { setPhase(.ready) }
            }
        }
        func notice(_ text: String) {
            SessionChannel.publishNotice(text, for: request)
            SessionChannel.post(.changed)
        }

        switch SpeechGate.verdict(heldFor: held, samples: samples) {
        case .tooShort:
            notice("")
            return
        case .tooQuiet:
            notice("Didn't hear anything")
            return
        case .speech:
            break
        }
        guard store.isDownloaded(model) else {
            notice("Open Wispr Faux and download the speech model")
            return
        }

        do {
            let result = try await transcriber.transcribe(samples, language: languageCode)
            guard !Task.isCancelled, activeRequest == request else { return }
            let text = TextCleaner().clean(result.text)
            let quiet = SpeechGate.loudestWindowDBFS(samples) < -40
            if text.isEmpty || TextCleaner.isNonSpeechMarker(text) || (quiet && TextCleaner.isLikelySilenceArtifact(text)) {
                notice("Didn't catch that")
                return
            }
            let outcome = await cleanup.clean(text)
            guard !Task.isCancelled, activeRequest == request else { return }
            let final = outcome?.text ?? text

            SessionChannel.publishResult(final, for: request)
            SessionChannel.post(.changed)

            let total = ContinuousClock.now - released
            lastTiming = String(
                format: "%.1f s of speech → %.2f s to transcribe%@ → %.2f s after release",
                Double(samples.count) / 16_000,
                result.processingDuration / .seconds(1),
                outcome.map { String(format: " → %.2f s cleanup (%@)", $0.duration / .seconds(1), PhoneCleanup.describe($0.kind)) } ?? "",
                total / .seconds(1)
            )
            log.notice("\(self.lastTiming ?? "", privacy: .public)")
            await history.add(TranscriptRecord(text: final, original: final == text ? nil : text))
            recent = await history.all
        } catch is CancellationError {
            return
        } catch {
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            notice("Transcription failed")
        }
    }

    func clearHistory() {
        Task {
            await history.removeAll()
            recent = []
        }
    }
}
