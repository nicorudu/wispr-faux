/// What Dictate needs to know about the focused text field before inserting.
public struct FocusedFieldInfo: Sendable, Equatable {
    public var isEditable: Bool
    /// `AXSecureTextField` (password fields): never paste into these.
    public var isSecure: Bool
    public var appBundleID: String?

    public init(isEditable: Bool, isSecure: Bool, appBundleID: String?) {
        self.isEditable = isEditable
        self.isSecure = isSecure
        self.appBundleID = appBundleID
    }
}

/// Reads the system-wide focused element through the Accessibility API
/// (`AXFocusedUIElement`, role, settable `AXValue`).
///
/// Implemented in Step 6.
public final class FocusedFieldReader {
    public init() {}
}
