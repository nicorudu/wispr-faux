import CoreGraphics

/// A modifier key the user can hold to dictate. Control (either side) is the default
/// since it exists on every keyboard; Fn and the other right-hand modifiers are options.
public enum HotkeyTrigger: String, Sendable, CaseIterable, Codable, Identifiable {
    case leftControl
    case rightControl
    case fn
    case rightOption
    case rightCommand

    public var id: String { rawValue }

    /// Holding either Control key dictates.
    public static let defaultTriggers: Set<HotkeyTrigger> = [.leftControl, .rightControl]

    public var keyCode: CGKeyCode {
        switch self {
        case .leftControl: KeyCode.leftControl
        case .rightControl: KeyCode.rightControl
        case .fn: KeyCode.function
        case .rightOption: KeyCode.rightOption
        case .rightCommand: KeyCode.rightCommand
        }
    }

    public var displayName: String {
        switch self {
        case .leftControl: "Left Control (⌃)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn (🌐)"
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        }
    }

    /// Fn events are swallowed so the OS doesn't act on them as well. The other
    /// modifiers pass through untouched: apps still need to see them for normal typing.
    public var swallowsEvents: Bool { self == .fn }

    /// Whether this trigger is down, given the flags of a `.flagsChanged` event for its
    /// keycode. Left and right modifiers are told apart by the device-dependent bits in
    /// the low word (`NX_DEVICE*KEYMASK`).
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
        case .leftControl: 0x0000_0001 // NX_DEVICELCTLKEYMASK
        case .rightControl: 0x0000_2000 // NX_DEVICERCTLKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: 0x0000_0040 // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x0000_0010 // NX_DEVICERCMDKEYMASK
        }
    }

    private var genericMask: UInt64 {
        switch self {
        case .leftControl, .rightControl: CGEventFlags.maskControl.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        }
    }
}
