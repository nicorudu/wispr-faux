import CoreGraphics
import HotkeyKit

/// Sends the keystroke that makes the focused app paste.
@MainActor
protocol PasteKeySender {
    /// Whether macOS lets this process post keyboard events to other apps (Accessibility).
    var canPost: Bool { get }
    /// Presses ⌘V and returns the keycode that was used for V.
    func sendPaste() async -> CGKeyCode
}

/// Posts synthetic key presses at the session tap, each tagged with `syntheticEventTag`
/// so Dictate's own event tap lets them through untouched (BUILD_PLAN.md §5, gotcha 8).
@MainActor
public struct KeyPoster: PasteKeySender {
    public init() {}

    public var canPost: Bool {
        CGPreflightPostEventAccess()
    }

    /// Presses ⌘V, with V looked up in the current keyboard layout.
    public func sendPaste() async -> CGKeyCode {
        let v = KeyboardLayout.keyCode(for: "v") ?? KeyCode.ansiV
        await press(v, flags: .maskCommand)
        return v
    }

    /// Key down, a short pause, key up. The key up is sent even if the task is cancelled,
    /// so a key is never left held down.
    public func press(_ keyCode: CGKeyCode, flags: CGEventFlags = []) async {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        }
        down.post(tap: .cgSessionEventTap)
        try? await Task.sleep(for: PasteTiming.keyDownToUp)
        up.post(tap: .cgSessionEventTap)
    }

    /// Modifier keys the user is physically holding. They can turn ⌘V into ⌥⌘V or ⇧⌘V
    /// ("paste and match style") in some apps, so the inserter logs them.
    public static var heldModifierNames: [String] {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let names: [(CGEventFlags, String)] = [
            (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘"),
        ]
        return names.filter { flags.contains($0.0) }.map(\.1)
    }
}
