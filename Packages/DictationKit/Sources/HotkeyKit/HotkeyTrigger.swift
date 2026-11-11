import CoreGraphics

/// A modifier key the user can hold to dictate. Fn is the default; the right-hand
/// modifiers are fallbacks for keyboards without an Fn key (BUILD_PLAN.md §1).
public enum HotkeyTrigger: String, Sendable, CaseIterable, Codable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    public var id: String { rawValue }

    public var keyCode: CGKeyCode {
        switch self {
        case .fn: KeyCode.function
        case .rightOption: KeyCode.rightOption
        case .rightCommand: KeyCode.rightCommand
        case .rightControl: KeyCode.rightControl
        }
    }

    public var displayName: String {
        switch self {
        case .fn: "Fn (🌐)"
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        }
    }

    /// Fn events are swallowed so the OS doesn't act on them as well. The other
    /// modifiers pass through untouched: apps still need to see them for normal typing.
    public var swallowsEvents: Bool { self == .fn }

    /// Whether this trigger is down, given the flags of a `.flagsChanged` event for its
    /// keycode. Right-hand modifiers are told apart from left ones by the
    /// device-dependent bits in the low word (`NX_DEVICER*KEYMASK`).
    func isPressed(inFlags flags: UInt64) -> Bool {
        flags & pressedMask != 0
    }

    /// Conservative check against a polled flag state (which may lack device-dependent
    /// bits): only true when even the generic modifier flag is clear.
    func isDefinitelyReleased(inFlags flags: UInt64) -> Bool {
        flags & genericMask == 0
    }

    private var pressedMask: UInt64 {
        switch self {
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x0000_0010 // NX_DEVICERCMDKEYMASK
        case .rightControl: 0x0000_2000 // NX_DEVICERCTLKEYMASK
        }
    }

    private var genericMask: UInt64 {
        switch self {
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl: CGEventFlags.maskControl.rawValue
        }
    }
}
