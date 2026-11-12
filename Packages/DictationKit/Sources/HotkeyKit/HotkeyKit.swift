import CoreGraphics

/// Virtual keycodes used by the hotkey and insertion layers (BUILD_PLAN.md, Appendix).
public enum KeyCode {
    /// Fn / Globe. Arrives as `.flagsChanged`; pressed when `.maskSecondaryFn` is set.
    public static let function: CGKeyCode = 63
    /// Some Globe-key keyboards also send a key down/up with this code. It has no other
    /// meaning, so it's swallowed whenever Fn is a trigger.
    public static let globe: CGKeyCode = 179
    public static let leftControl: CGKeyCode = 59
    public static let rightCommand: CGKeyCode = 54
    public static let rightOption: CGKeyCode = 61
    public static let rightControl: CGKeyCode = 62
    public static let returnKey: CGKeyCode = 36
    public static let tab: CGKeyCode = 48
    public static let space: CGKeyCode = 49
    public static let escape: CGKeyCode = 53
    /// `kVK_ANSI_V` — fallback when the current layout can't be queried for "v".
    public static let ansiV: CGKeyCode = 9
}

/// Written into `eventSourceUserData` on every event Wispr Faux synthesizes, so the
/// event tap can recognise and ignore our own keystrokes (BUILD_PLAN.md §5, gotcha 8).
public let syntheticEventTag: Int64 = 0x4449_4354 // "DICT"

/// What the hotkey layer reports to the dictation controller.
public enum HotkeyEvent: Sendable, Equatable {
    /// A trigger key went down: start recording.
    case pushToTalkPressed
    /// Stop recording and transcribe. Sent when the held trigger is released, or when a
    /// trigger is pressed again to end a hands-free session.
    case pushToTalkReleased
    /// Trigger + Space: keep recording after the trigger is released.
    case handsFreeToggled
    /// Discard the recording. Sent for Esc, and when the trigger turns out to be used as
    /// a modifier (e.g. ⌃C, Ctrl-click, Fn+Delete), so a chord never produces a dictation.
    case cancel
}
