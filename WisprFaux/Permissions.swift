import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation

/// The macOS privacy permissions Wispr Faux needs (BUILD_PLAN.md §3, onboarding).
enum Permission: CaseIterable, Identifiable {
    case microphone
    case accessibility
    case inputMonitoring

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: "Records your voice, only while you hold the dictation key."
        case .accessibility: "Lets Wispr Faux see the dictation key in any app and paste the text where you're typing."
        case .inputMonitoring: "Lets Wispr Faux listen for the dictation key while other apps are in front."
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: "mic"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    /// The matching pane in System Settings → Privacy & Security.
    var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionStatus: Equatable {
    case granted
    /// Never asked, or (for Accessibility and Input Monitoring, which can't be told apart)
    /// asked and not yet switched on.
    case notGranted
    /// The user said no to the microphone prompt; only System Settings can change it now.
    case denied
}

/// What the Fn/Globe key does on its own: System Settings → Keyboard → "Press 🌐 key to".
/// Anything but "Do Nothing" fires alongside dictation (BUILD_PLAN.md §5, gotcha 4).
enum GlobeKeyAction: Equatable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// Never changed by the user; macOS picks emoji or input source on its own.
    case systemDefault
    case unknown(Int)

    var title: String {
        switch self {
        case .doNothing: "Do Nothing"
        case .changeInputSource: "Change Input Source"
        case .showEmojiAndSymbols: "Show Emoji & Symbols"
        case .startDictation: "Start Dictation"
        case .systemDefault: "macOS default"
        case .unknown(let value): "Unrecognized setting (\(value))"
        }
    }

    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// Reads `AppleFnUsageType` from `com.apple.HIToolbox` (possible because the app is
    /// not sandboxed).
    static func current() -> GlobeKeyAction {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int else {
            return .systemDefault
        }
        return switch value {
        case 0: .doNothing
        case 1: .changeInputSource
        case 2: .showEmojiAndSymbols
        case 3: .startDictation
        default: .unknown(value)
        }
    }
}

/// Live permission state. `refresh()` is cheap and is polled by `DictationController`;
/// macOS sends no notification when the user flips a switch in System Settings.
@MainActor
@Observable
final class PermissionsManager {
    private(set) var microphone: PermissionStatus = .notGranted
    private(set) var accessibility: PermissionStatus = .notGranted
    private(set) var inputMonitoring: PermissionStatus = .notGranted
    private(set) var globeKey: GlobeKeyAction = .systemDefault

    init() {
        refresh(includeGlobeKey: true)
    }

    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone: microphone
        case .accessibility: accessibility
        case .inputMonitoring: inputMonitoring
        }
    }

    var allGranted: Bool {
        Permission.allCases.allSatisfy { status(of: $0) == .granted }
    }

    var missingCount: Int {
        Permission.allCases.count { status(of: $0) != .granted }
    }

    /// Re-reads every status. Only assigns values that changed, so SwiftUI doesn't
    /// redraw on every poll.
    func refresh(includeGlobeKey: Bool = false) {
        let mic: PermissionStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notGranted
        }
        let ax: PermissionStatus = AXIsProcessTrusted() ? .granted : .notGranted
        let listen: PermissionStatus = CGPreflightListenEventAccess() ? .granted : .notGranted

        if microphone != mic { microphone = mic }
        if accessibility != ax { accessibility = ax }
        if inputMonitoring != listen { inputMonitoring = listen }

        if includeGlobeKey {
            let globe = GlobeKeyAction.current()
            if globeKey != globe { globeKey = globe }
        }
    }

    /// Permissions whose system prompt was already shown this launch.
    @ObservationIgnored private var prompted: Set<Permission> = []

    /// The first time, shows the system prompt (which also adds Wispr Faux to the list in
    /// System Settings). After that macOS stays silent, so open System Settings instead.
    func request(_ permission: Permission) async {
        defer { refresh() }
        guard status(of: permission) == .notGranted, !prompted.contains(permission) else {
            openSystemSettings(for: permission)
            return
        }
        prompted.insert(permission)

        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .accessibility:
            // The key is spelled out: the global `kAXTrustedCheckOptionPrompt` isn't
            // concurrency-safe under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(GlobeKeyAction.keyboardSettingsURL)
    }
}
