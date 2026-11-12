import CoreGraphics

/// The parts of a keyboard (or mouse-button) `CGEvent` the matcher needs. A plain value,
/// so the matching logic can be tested without creating real events.
public struct KeyInput: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown
        case keyUp
        case flagsChanged
        /// Any mouse button went down. Only used to spot Ctrl-click; `keyCode` is unused.
        case mouseDown
    }

    public var kind: Kind
    public var keyCode: CGKeyCode
    /// Raw `CGEventFlags`, including the device-dependent low bits.
    public var flags: UInt64
    public var isAutorepeat: Bool

    public init(kind: Kind, keyCode: CGKeyCode, flags: UInt64 = 0, isAutorepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.isAutorepeat = isAutorepeat
    }
}

/// Turns raw key events into `HotkeyEvent`s and decides which events to swallow.
///
/// Gestures:
/// - Hold a trigger → `.pushToTalkPressed`; release it → `.pushToTalkReleased`.
/// - Trigger + Space → `.handsFreeToggled`; recording continues after the trigger is
///   released, and the next trigger press ends it with `.pushToTalkReleased`.
/// - Esc during a session → `.cancel` (Esc is only swallowed while a session is active).
///   While `escapeCancels` is set (the app is still transcribing), Esc also cancels.
/// - Any other key or a mouse click while the trigger is held means it's being used as
///   a modifier (⌃C, Ctrl-click, Fn+Delete…) → `.cancel`, and the event passes through.
///
/// Runs inside the event-tap callback, so every call is O(1) and allocation-light.
public struct ShortcutMatcher: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// A trigger is held and recording.
        case holding
        /// Locked with trigger + Space; recording until the next trigger press.
        case handsFree
    }

    public struct Decision: Sendable, Equatable {
        public var swallow: Bool
        public var events: [HotkeyEvent]

        public init(swallow: Bool, events: [HotkeyEvent] = []) {
            self.swallow = swallow
            self.events = events
        }

        public static let pass = Decision(swallow: false)
    }

    public private(set) var triggers: Set<HotkeyTrigger>
    public private(set) var phase: Phase = .idle
    /// The trigger that is physically held, as far as the events tell us. Tracked apart
    /// from `phase` so the release after a cancel or a hands-free stop is ignored.
    public private(set) var heldTrigger: HotkeyTrigger?
    /// Keys whose key-down was swallowed; their autorepeats and key-up are swallowed too,
    /// so apps never see half a keystroke.
    private var swallowedKeys: Set<CGKeyCode> = []
    /// Set by the app after the trigger is released, while it's still working on the
    /// dictation: the next Esc sends `.cancel` (and is swallowed) even though no key is
    /// held. Clears itself after one Esc, so a second Esc reaches the app as usual.
    public var escapeCancels = false

    public init(triggers: Set<HotkeyTrigger>) {
        self.triggers = triggers
    }

    public mutating func handle(_ input: KeyInput) -> Decision {
        switch input.kind {
        case .flagsChanged: handleFlagsChanged(input)
        case .keyDown: handleKeyDown(input)
        case .keyUp: handleKeyUp(input)
        case .mouseDown: handleMouseDown()
        }
    }

    /// Replaces the enabled triggers. Ends any session whose trigger was removed.
    public mutating func setTriggers(_ newTriggers: Set<HotkeyTrigger>) -> [HotkeyEvent] {
        triggers = newTriggers
        if let held = heldTrigger, !newTriggers.contains(held) {
            return reset()
        }
        return []
    }

    /// Forgets all state, e.g. when the tap stops. Cancels a session in progress.
    public mutating func reset() -> [HotkeyEvent] {
        let wasActive = phase != .idle
        phase = .idle
        heldTrigger = nil
        swallowedKeys.removeAll()
        return wasActive ? [.cancel] : []
    }

    /// Called after the tap was disabled, when key-ups may have been missed. Ends a
    /// hold whose trigger is no longer down according to `currentFlags`.
    public mutating func resync(currentFlags: UInt64) -> [HotkeyEvent] {
        guard let held = heldTrigger, held.isDefinitelyReleased(inFlags: currentFlags) else { return [] }
        heldTrigger = nil
        swallowedKeys.removeAll()
        guard phase == .holding else { return [] }
        phase = .idle
        return [.pushToTalkReleased]
    }

    // MARK: - Event handling

    private mutating func handleFlagsChanged(_ input: KeyInput) -> Decision {
        guard let trigger = triggers.first(where: { $0.keyCode == input.keyCode }) else { return .pass }
        let swallow = trigger.swallowsEvents

        if trigger.isPressed(inFlags: input.flags) {
            // A second trigger while one is held is just a modifier; ignore it.
            guard heldTrigger == nil else { return Decision(swallow: swallow) }
            heldTrigger = trigger
            switch phase {
            case .idle:
                phase = .holding
                return Decision(swallow: swallow, events: [.pushToTalkPressed])
            case .handsFree:
                phase = .idle
                return Decision(swallow: swallow, events: [.pushToTalkReleased])
            case .holding:
                return Decision(swallow: swallow)
            }
        } else {
            guard heldTrigger == trigger else { return Decision(swallow: swallow) }
            heldTrigger = nil
            guard phase == .holding else { return Decision(swallow: swallow) }
            phase = .idle
            return Decision(swallow: swallow, events: [.pushToTalkReleased])
        }
    }

    private mutating func handleKeyDown(_ input: KeyInput) -> Decision {
        let code = input.keyCode
        if input.isAutorepeat, swallowedKeys.contains(code) {
            return Decision(swallow: true)
        }
        // A fresh press of a key still in the set means we missed its key-up.
        swallowedKeys.remove(code)

        if code == KeyCode.globe, triggers.contains(.fn) {
            return swallowKey(code)
        }
        if code == KeyCode.escape, phase != .idle || escapeCancels {
            phase = .idle
            escapeCancels = false
            return swallowKey(code, events: [.cancel])
        }
        if code == KeyCode.space, phase == .holding {
            phase = .handsFree
            return swallowKey(code, events: [.handsFreeToggled])
        }
        if phase == .holding {
            // The trigger is acting as a modifier for this key.
            phase = .idle
            return Decision(swallow: false, events: [.cancel])
        }
        return .pass
    }

    /// Ctrl-click is right-click on a Mac, so a click during a hold is never dictation.
    /// Clicks during hands-free are fine (e.g. to focus a text field).
    private mutating func handleMouseDown() -> Decision {
        guard phase == .holding else { return .pass }
        phase = .idle
        return Decision(swallow: false, events: [.cancel])
    }

    private mutating func handleKeyUp(_ input: KeyInput) -> Decision {
        swallowedKeys.remove(input.keyCode) != nil ? Decision(swallow: true) : .pass
    }

    private mutating func swallowKey(_ code: CGKeyCode, events: [HotkeyEvent] = []) -> Decision {
        swallowedKeys.insert(code)
        return Decision(swallow: true, events: events)
    }
}
