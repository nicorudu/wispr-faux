import CoreGraphics

/// Virtual keycodes used by the hotkey and insertion layers (BUILD_PLAN.md, Appendix).
public enum KeyCode {
    /// Fn / Globe. Arrives as `.flagsChanged`; pressed when `.maskSecondaryFn` is set.
    public static let function: CGKeyCode = 63
    public static let returnKey: CGKeyCode = 36
    public static let tab: CGKeyCode = 48
    public static let space: CGKeyCode = 49
    public static let escape: CGKeyCode = 53
    /// `kVK_ANSI_V` — fallback when the current layout can't be queried for "v".
    public static let ansiV: CGKeyCode = 9
}

/// Written into `eventSourceUserData` on every event Dictate synthesizes, so the
/// event tap can recognise and ignore our own keystrokes (BUILD_PLAN.md §5, gotcha 8).
public let syntheticEventTag: Int64 = 0x4449_4354 // "DICT"

/// What the hotkey layer reports to the dictation controller.
public enum HotkeyEvent: Sendable, Equatable {
    case pushToTalkPressed
    case pushToTalkReleased
    case handsFreeToggled
    case cancel
}

/// Active `CGEventTap` (session tap, head insert, default/filtering options) running on
/// its own thread and run loop. Swallows matched shortcut events and re-enables itself
/// after `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.
///
/// Implemented in Step 2.
public final class EventTapMonitor {
    public init() {}
}
