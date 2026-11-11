import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Health counters for the event tap, shown in the Debug menu.
public struct TapStats: Sendable, Equatable {
    /// Times macOS disabled the tap and it was turned back on.
    public var reenableCount = 0
    public var lastReenableReason: String?
    /// Callbacks slower than `EventTapMonitor.slowCallbackThreshold`.
    public var slowCallbackCount = 0

    public init() {}
}

public enum EventTapError: Error, LocalizedError {
    case tapCreationFailed

    public var errorDescription: String? {
        "macOS refused to create the keyboard event tap. Dictate needs Accessibility and Input Monitoring access."
    }
}

/// Active `CGEventTap` (session tap, head insert, default options) on its own thread and
/// run loop, so a busy main thread can never stall the keyboard.
///
/// - Matched shortcut events are swallowed (BUILD_PLAN.md §1, "Hotkey").
/// - Events tagged with `syntheticEventTag` pass straight through (§5, gotcha 8).
/// - After `.tapDisabledByTimeout` / `.tapDisabledByUserInput` the tap is re-enabled at
///   once, and a watchdog timer re-enables it if a disable notice is ever missed (§5,
///   gotcha 2). Re-enabling also resyncs the held trigger, in case its key-up was lost.
///
/// `start()` and `stop()` must be called from the main actor; results arrive on `events`.
public final class EventTapMonitor: @unchecked Sendable {
    /// Callbacks slower than this are counted and logged (the teardown used 250 ms).
    public static let slowCallbackThreshold: Duration = .milliseconds(250)
    static let watchdogInterval: CFTimeInterval = 2

    /// Hotkey events, in order. A single long-lived stream across start/stop cycles.
    public let events: AsyncStream<HotkeyEvent>
    private let continuation: AsyncStream<HotkeyEvent>.Continuation

    private struct Shared: Sendable {
        var matcher: ShortcutMatcher
        var stats = TapStats()
        /// Debug only: block the next callback this long to provoke a tap timeout.
        var pendingStall: TimeInterval?
    }

    /// State shared between the tap thread and the main actor.
    private let shared: OSAllocatedUnfairLock<Shared>
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Dictate", category: "EventTap")

    /// The running tap. Only touched by `start()` / `stop()` on the main actor.
    private var session: TapSession?

    public init(triggers: Set<HotkeyTrigger>) {
        (events, continuation) = AsyncStream.makeStream(of: HotkeyEvent.self)
        shared = OSAllocatedUnfairLock(initialState: Shared(matcher: ShortcutMatcher(triggers: triggers)))
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Lifecycle

    @MainActor
    public var isRunning: Bool { session != nil }

    /// Creates the tap and starts its thread. Throws when macOS refuses the tap, which
    /// means Accessibility (or Input Monitoring) hasn't been granted yet.
    @MainActor
    public func start() throws {
        guard session == nil else { return }

        let session = TapSession(monitor: self)
        // Mouse-button downs are only watched to cancel on Ctrl-click; never swallowed.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        // Retained for the tap thread's lifetime; released when its run loop exits.
        let refcon = Unmanaged.passRetained(session).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // active: the callback can swallow events
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            Unmanaged<TapSession>.fromOpaque(refcon).release()
            throw EventTapError.tapCreationFailed
        }
        session.tap = tap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [session] in
            session.run(ready: ready)
        }
        thread.name = "Dictate.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        self.session = session
        log.notice("Event tap started")
    }

    /// Removes the tap and ends its thread. A session in progress is cancelled.
    @MainActor
    public func stop() {
        guard let session else { return }
        self.session = nil
        CGEvent.tapEnable(tap: session.tap, enable: false)
        CFMachPortInvalidate(session.tap)
        CFRunLoopStop(session.runLoop)
        yield(shared.withLock { $0.matcher.reset() })
        log.notice("Event tap stopped")
    }

    // MARK: - Configuration and diagnostics

    public func setTriggers(_ triggers: Set<HotkeyTrigger>) {
        yield(shared.withLock { $0.matcher.setTriggers(triggers) })
    }

    public var stats: TapStats {
        shared.withLock { $0.stats }
    }

    /// Another app has Secure Event Input on (a password field, some terminals). While it
    /// is, the tap may not see keystrokes (BUILD_PLAN.md §5, gotcha 3).
    public static var isSecureEventInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Debug aid: the next key event blocks the tap for `seconds`, long enough for macOS
    /// to disable it. Used to check that the tap recovers.
    public func simulateStallOnNextEvent(seconds: TimeInterval = 2.5) {
        shared.withLock { $0.pendingStall = seconds }
        log.notice("Next key event will stall the tap for \(seconds, privacy: .public) s")
    }

    // MARK: - Tap thread

    /// Called on the tap thread for every event. Keep it O(1): macOS disables taps whose
    /// callbacks are slow.
    fileprivate func handle(type: CGEventType, event: CGEvent, session: TapSession) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout:
            reenable(session, reason: "timeout")
            return passThrough
        case .tapDisabledByUserInput:
            reenable(session, reason: "user input")
            return passThrough
        case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            break
        default:
            return passThrough
        }

        let started = ContinuousClock.now
        let isKeyboard = type == .keyDown || type == .keyUp || type == .flagsChanged
        if isKeyboard, let stall = shared.withLock({ state -> TimeInterval? in
            defer { state.pendingStall = nil }
            return state.pendingStall
        }) {
            log.notice("Stalling the tap callback for \(stall, privacy: .public) s (debug)")
            Thread.sleep(forTimeInterval: stall)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag {
            return passThrough
        }

        let input = KeyInput(event: event, type: type)
        let decision = shared.withLock { $0.matcher.handle(input) }
        yield(decision.events)

        let elapsed = ContinuousClock.now - started
        if elapsed > Self.slowCallbackThreshold {
            shared.withLock { $0.stats.slowCallbackCount += 1 }
            log.warning("Slow event tap callback: \(Self.milliseconds(elapsed), privacy: .public) ms")
        }

        return decision.swallow ? nil : passThrough
    }

    fileprivate func watchdogFired(_ session: TapSession) {
        // After `stop()` the port is invalid; the run loop is about to exit.
        if CFMachPortIsValid(session.tap), !CGEvent.tapIsEnabled(tap: session.tap) {
            reenable(session, reason: "watchdog")
        }
    }

    private func reenable(_ session: TapSession, reason: String) {
        CGEvent.tapEnable(tap: session.tap, enable: true)
        let flags = CGEventSource.flagsState(.hidSystemState).rawValue
        let missed = shared.withLock { state -> [HotkeyEvent] in
            state.stats.reenableCount += 1
            state.stats.lastReenableReason = reason
            return state.matcher.resync(currentFlags: flags)
        }
        yield(missed)
        log.notice("""
            Event tap was disabled (\(reason, privacy: .public)); re-enabled. \
            Flags now 0x\(String(flags, radix: 16), privacy: .public), \
            resync events: \(missed.count, privacy: .public)
            """)
    }

    private func yield(_ events: [HotkeyEvent]) {
        for event in events {
            continuation.yield(event)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }
}

/// One run of the tap: the mach port, its run loop, and the thread that services it.
/// The C callback receives a pointer to this object.
private final class TapSession: @unchecked Sendable {
    let monitor: EventTapMonitor
    /// Set once in `start()`, before the thread starts.
    var tap: CFMachPort!
    /// Set once on the tap thread, before `ready` is signalled.
    var runLoop: CFRunLoop!

    init(monitor: EventTapMonitor) {
        self.monitor = monitor
    }

    func run(ready: DispatchSemaphore) {
        runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)

        let interval = EventTapMonitor.watchdogInterval
        let watchdog = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + interval, interval, 0, 0
        ) { [unowned self] _ in
            monitor.watchdogFired(self)
        }
        CFRunLoopAddTimer(runLoop, watchdog, .commonModes)

        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()

        CFRunLoopRun()

        CFRunLoopTimerInvalidate(watchdog)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        // Balances `passRetained` in `EventTapMonitor.start()`.
        Unmanaged.passUnretained(self).release()
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let session = Unmanaged<TapSession>.fromOpaque(refcon).takeUnretainedValue()
    return session.monitor.handle(type: type, event: event, session: session)
}

extension KeyInput {
    init(event: CGEvent, type: CGEventType) {
        let kind: Kind = switch type {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: .mouseDown
        default: .flagsChanged
        }
        self.init(
            kind: kind,
            keyCode: CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }
}
