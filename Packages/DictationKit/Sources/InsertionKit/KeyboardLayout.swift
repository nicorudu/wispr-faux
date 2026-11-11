import Carbon.HIToolbox
import CoreGraphics

/// Finds which physical key types a character in the user's keyboard layout, so a
/// synthetic ⌘V is still ⌘V on Dvorak, AZERTY and friends (BUILD_PLAN.md §5, gotcha 7).
///
/// Text Input Sources calls must stay on the main thread.
@MainActor
public enum KeyboardLayout {
    /// The keycode that types `character` together with ⌘ in the current layout. Falls
    /// back to the ASCII-capable layout macOS uses for shortcuts when the current one has
    /// no such key (e.g. Russian or Greek). `nil` if neither has it.
    public static func keyCode(for character: Character) -> CGKeyCode? {
        let candidates = [
            TISCopyCurrentKeyboardLayoutInputSource(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource(),
        ]
        for source in candidates.compactMap({ $0?.takeRetainedValue() }) {
            if let code = keyCode(for: character, in: source) {
                return code
            }
        }
        return nil
    }

    /// Same lookup in a specific installed layout, e.g. `com.apple.keylayout.Dvorak`.
    /// For tests and diagnostics.
    public static func keyCode(for character: Character, inputSourceID: String) -> CGKeyCode? {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard
            let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
            let source = list.first
        else { return nil }
        return keyCode(for: character, in: source)
    }

    private static func keyCode(for character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil // input methods (e.g. Japanese) have no 'uchr' data
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue()
        let target = String(character).lowercased()

        return withExtendedLifetime(layoutData) {
            let layout = UnsafeRawPointer(CFDataGetBytePtr(layoutData)!)
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            // ⌘ first: layouts like "Dvorak – QWERTY ⌘" switch to QWERTY while it's held,
            // and that is the key apps match the shortcut against.
            let commandState = UInt32(cmdKey >> 8) & 0xFF
            for modifiers in [commandState, 0] {
                for code in CGKeyCode(0)..<128 {
                    if translate(code, modifiers: modifiers, layout: layout)?.lowercased() == target {
                        return code
                    }
                }
            }
            return nil
        }
    }

    private static func translate(
        _ keyCode: CGKeyCode,
        modifiers: UInt32,
        layout: UnsafePointer<UCKeyboardLayout>
    ) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifiers,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
