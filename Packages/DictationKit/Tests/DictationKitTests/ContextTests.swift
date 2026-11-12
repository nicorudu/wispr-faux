import Testing
@testable import ContextKit

@Suite("FocusedFieldReader")
struct FocusedFieldReaderTests {
    private func kind(_ role: String?, _ subrole: String? = nil, settable: Bool = false, selection: Bool = false) -> FocusedFieldInfo.Kind {
        FocusedFieldReader.classify(role: role, subrole: subrole, valueSettable: settable, hasTextSelection: selection)
    }

    @Test func passwordFieldsAreSecure() {
        #expect(kind("AXTextField", "AXSecureTextField", settable: true, selection: true) == .secure)
    }

    @Test func textFields() {
        #expect(kind("AXTextField") == .text)
        #expect(kind("AXTextArea") == .text)
        #expect(kind("AXComboBox") == .text)
        #expect(kind("AXTextField", "AXSearchField") == .text)
    }

    /// contenteditable editors in browsers and rich-text views use other roles.
    @Test func otherRolesWithTextSelectionTakeText() {
        #expect(kind("AXWebArea", selection: true) == .text)
        #expect(kind("AXGroup", settable: true) == .text)
    }

    @Test func controlsAreNotText() {
        #expect(kind("AXButton") == .notText)
        #expect(kind("AXList") == .notText)
        #expect(kind("AXTable") == .notText)
        // A slider's value is settable, but it's not text.
        #expect(kind("AXSlider", settable: true) == .notText)
    }

    /// Electron apps often report a bare group, web area or window: paste anyway.
    @Test func ambiguousContainersAreUnknown() {
        #expect(kind("AXWebArea") == .unknown)
        #expect(kind("AXGroup") == .unknown)
        #expect(kind("AXWindow") == .unknown)
        #expect(kind(nil) == .unknown)
    }
}
