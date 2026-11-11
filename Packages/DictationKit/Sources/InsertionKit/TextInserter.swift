import HotkeyKit

/// Timings observed in the teardown (BUILD_PLAN.md, Appendix).
public enum PasteTiming {
    public static let keyDownToUp: Duration = .milliseconds(5)
    public static let afterPasteboardWrite: Duration = .milliseconds(10)
    public static let afterCommandV: Duration = .milliseconds(10)
    /// Restoring sooner risks the target app pasting the old clipboard.
    public static let beforeRestore: Duration = .milliseconds(500)
}

/// Inserts text into the focused app:
/// 1. back up every pasteboard item;
/// 2. clear and write the string (plus HTML when available);
/// 3. verify `changeCount` moved;
/// 4. post a layout-aware Cmd+V tagged with `syntheticEventTag`;
/// 5. restore the backup after `PasteTiming.beforeRestore`, unless the user copied
///    something in the meantime.
///
/// Implemented in Step 3.
public final class TextInserter {
    public init() {}

    /// Tag stamped on every synthetic key event so `EventTapMonitor` ignores it.
    public static let eventTag = syntheticEventTag
}
