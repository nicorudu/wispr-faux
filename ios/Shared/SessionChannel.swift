import Foundation

/// How the keyboard and the app talk to each other.
///
/// iOS doesn't let a keyboard use the microphone, and a keyboard has far too little memory for
/// Whisper. So the app runs a *session* in the background, with the microphone on, and the
/// keyboard drives it:
///
/// - **Signals** go through Darwin notifications (no payload, instant, cross-process):
///   keyboard → app: `start`, `stop`, `cancel`; app → keyboard: `changed`.
/// - **State** lives in the App Group's shared UserDefaults: whether a session is alive (a
///   heartbeat the app writes about once a second while the microphone runs), what it's doing,
///   the microphone level, and each finished transcript with the request it answers.
///
/// Both sides also poll the state while they wait, so a missed notification only costs a
/// fraction of a second.
enum SessionChannel {
    enum Signal: String, CaseIterable {
        case start, stop, cancel, changed

        var name: String { "wisprfaux.session.\(rawValue)" }
    }

    enum Phase: String {
        /// A session is running and waiting for the mic button.
        case ready
        case recording
        case transcribing
        /// No session: the keyboard opens the app to start one.
        case off
    }

    /// The App Group both targets belong to, from Info.plist (set in project.yml).
    static let appGroup: String = Bundle.main.object(forInfoDictionaryKey: "WFAppGroup") as? String ?? "group.com.example.wisprfaux"

    /// Nil when the App Group isn't available: in the keyboard, that means Full Access is off.
    static let defaults = UserDefaults(suiteName: appGroup)

    /// The app opens with this to start a session.
    static let startSessionURL = URL(string: "wisprfaux://session")!

    private enum Key {
        static let heartbeat = "session.heartbeat"
        static let phase = "session.phase"
        static let level = "session.level"
        static let request = "request.id"
        static let resultRequest = "result.request"
        static let resultText = "result.text"
        static let notice = "session.notice"
        static let endsAt = "session.endsAt"
        static let keyboardSeen = "keyboard.seen"
    }

    // MARK: Session liveness

    /// The app is alive and its microphone is running when the heartbeat is fresh.
    static var isSessionAlive: Bool {
        guard let beat = defaults?.double(forKey: Key.heartbeat), beat > 0 else { return false }
        return Date().timeIntervalSince1970 - beat < 3
    }

    static func beat() {
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.heartbeat)
    }

    static func endHeartbeat() {
        defaults?.set(0.0, forKey: Key.heartbeat)
    }

    static var phase: Phase {
        get {
            guard isSessionAlive else { return .off }
            return defaults?.string(forKey: Key.phase).flatMap(Phase.init(rawValue:)) ?? .ready
        }
        set { defaults?.set(newValue.rawValue, forKey: Key.phase) }
    }

    /// Microphone level while recording, 0…1.
    static var level: Float {
        get { defaults?.float(forKey: Key.level) ?? 0 }
        set { defaults?.set(newValue, forKey: Key.level) }
    }

    /// When an idle session will end on its own, if it will.
    static var endsAt: Date? {
        get {
            guard let t = defaults?.double(forKey: Key.endsAt), t > 0 else { return nil }
            return Date(timeIntervalSince1970: t)
        }
        set { defaults?.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.endsAt) }
    }

    // MARK: Requests and results

    /// Each press of the mic button gets a new request number; the app answers with it.
    static var currentRequest: Int {
        get { defaults?.integer(forKey: Key.request) ?? 0 }
        set { defaults?.set(newValue, forKey: Key.request) }
    }

    static func publishResult(_ text: String, for request: Int) {
        defaults?.set(text, forKey: Key.resultText)
        defaults?.set(request, forKey: Key.resultRequest)
    }

    /// The transcript for `request`, once the app has written it.
    static func result(for request: Int) -> String? {
        guard let defaults, defaults.integer(forKey: Key.resultRequest) == request else { return nil }
        return defaults.string(forKey: Key.resultText)
    }

    /// A short message for the keyboard, e.g. "Didn't hear anything", tied to a request.
    static func publishNotice(_ text: String, for request: Int) {
        defaults?.set(["request": request, "text": text], forKey: Key.notice)
    }

    static func notice(for request: Int) -> String? {
        guard let value = defaults?.dictionary(forKey: Key.notice),
              value["request"] as? Int == request else { return nil }
        return value["text"] as? String
    }

    // MARK: Setup

    /// The keyboard records that it ran with Full Access, so the app's setup list can tick it off.
    static func markKeyboardSeen() {
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.keyboardSeen)
    }

    static var keyboardSeen: Bool {
        (defaults?.double(forKey: Key.keyboardSeen) ?? 0) > 0
    }

    // MARK: Darwin notifications

    static func post(_ signal: Signal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(signal.name as CFString),
            nil, nil, true
        )
    }

    /// Calls `handler` on the main queue whenever `signal` is posted by the other side.
    /// Keep the returned observer alive for as long as you want the calls.
    static func observe(_ signal: Signal, handler: @escaping () -> Void) -> Observer {
        Observer(name: signal.name, handler: handler)
    }

    final class Observer {
        private let name: String
        private let handler: () -> Void

        fileprivate init(name: String, handler: @escaping () -> Void) {
            self.name = name
            self.handler = handler
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let me = Unmanaged<Observer>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { me.handler() }
                },
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        deinit {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString),
                nil
            )
        }
    }
}
