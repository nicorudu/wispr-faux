import AppKit
import ApplicationServices

/// What has keyboard focus when Wispr Faux is about to paste.
public struct FocusedFieldInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A text field, text area or other element that takes text.
        case text
        /// A password field: never paste dictation into it.
        case secure
        /// Focus is on something that can't take text (a button, list, table…).
        case notText
        /// Accessibility couldn't tell. Common in Electron apps (Slack, VS Code), which
        /// hide their text fields from Accessibility; pasting is the right call there.
        case unknown
    }

    public var kind: Kind
    /// Accessibility role and subrole, e.g. "AXTextField" / "AXSecureTextField".
    /// Logged to tune the classification; never the field's contents.
    public var role: String?
    public var subrole: String?
    public var appBundleID: String?
    public var appName: String?
    /// The character just before the cursor (or the selection), when the field reports
    /// it. nil at the start of a field, or when Accessibility can't say.
    public var characterBeforeInsertionPoint: Character?

    public init(
        kind: Kind,
        role: String? = nil,
        subrole: String? = nil,
        appBundleID: String? = nil,
        appName: String? = nil,
        characterBeforeInsertionPoint: Character? = nil
    ) {
        self.kind = kind
        self.role = role
        self.subrole = subrole
        self.appBundleID = appBundleID
        self.appName = appName
        self.characterBeforeInsertionPoint = characterBeforeInsertionPoint
    }
}

/// Reads the system-wide focused element through Accessibility (`AXFocusedUIElement`,
/// its role, subrole and whether its value is settable). Needs Accessibility access,
/// which Wispr Faux already has for the hotkey.
public struct FocusedFieldReader: Sendable {
    /// How long to wait for an app that doesn't answer (a hung app would otherwise hold
    /// Accessibility calls for six seconds).
    public var timeout: Float

    public init(timeout: Float = 0.25) {
        self.timeout = timeout
    }

    public func read() -> FocusedFieldInfo {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, timeout)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return FocusedFieldInfo(kind: .unknown, appBundleID: frontmost?.bundleIdentifier, appName: frontmost?.localizedName)
        }
        let element = value as! AXUIElement // Checked by the type ID above.
        AXUIElementSetMessagingTimeout(element, timeout)

        let role = stringAttribute("AXRole", of: element)
        let subrole = stringAttribute("AXSubrole", of: element)
        var settable: DarwinBoolean = false
        let valueSettable = AXUIElementIsAttributeSettable(element, "AXValue" as CFString, &settable) == .success && settable.boolValue
        var range: CFTypeRef?
        let hasTextSelection = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &range) == .success

        var pid: pid_t = 0
        let app = AXUIElementGetPid(element, &pid) == .success ? NSRunningApplication(processIdentifier: pid) : frontmost
        let kind = Self.classify(role: role, subrole: subrole, valueSettable: valueSettable, hasTextSelection: hasTextSelection)
        return FocusedFieldInfo(
            kind: kind,
            role: role,
            subrole: subrole,
            appBundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            characterBeforeInsertionPoint: kind == .text ? characterBefore(selection: range, in: element) : nil
        )
    }

    /// Reads one character before the selection with `AXStringForRange`. Only that
    /// character is read, never the rest of the field.
    private func characterBefore(selection: CFTypeRef?, in element: AXUIElement) -> Character? {
        guard let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &value) == .success,
              let text = value as? String
        else { return nil }
        return text.last
    }

    /// Roles that take text whatever else they report.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Roles that never take typed text. Ambiguous containers (AXWebArea, AXGroup,
    /// AXWindow, AXScrollArea) are left out on purpose: in web and Electron apps they
    /// can be where the text actually goes.
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXScrollBar", "AXColorWell",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXColumn", "AXBrowser",
        "AXImage", "AXMenu", "AXMenuBar", "AXMenuBarItem", "AXMenuItem", "AXTabGroup",
        "AXToolbar", "AXLink", "AXStaticText",
    ]

    static func classify(role: String?, subrole: String?, valueSettable: Bool, hasTextSelection: Bool) -> FocusedFieldInfo.Kind {
        if subrole == "AXSecureTextField" || role == "AXSecureTextField" { return .secure }
        if let role, textRoles.contains(role) { return .text }
        if let role, nonTextRoles.contains(role) { return .notText }
        // Rich-text and web editors often use other roles but expose a text selection
        // or a settable value.
        if hasTextSelection || valueSettable { return .text }
        return .unknown
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
