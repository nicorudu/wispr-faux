import HotkeyKit
import SwiftUI

/// Onboarding: grant the three permissions, fix the Globe key setting, and try the
/// hotkey. Every status updates live while the window is open.
struct SetupView: View {
    let controller: DictationController
    let close: @MainActor () -> Void

    private var permissions: PermissionsManager { controller.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Dictate")
                    .font(.title2.bold())
                Text("Hold a key, speak, let go: your words appear wherever you're typing. Dictate needs three permissions for that.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SetupSection {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, permissions: permissions)
                    if permission != Permission.allCases.last {
                        Divider()
                    }
                }
            }

            if controller.enabledTriggers.contains(.fn) {
                SetupSection {
                    GlobeKeyRow(permissions: permissions)
                }
            }

            SetupSection {
                HotkeyTestRow(controller: controller)
            }

            HStack {
                if permissions.allGranted {
                    Label("All permissions granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text(permissions.missingCount == 1 ? "1 permission left" : "\(permissions.missingCount) permissions left")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

// MARK: - Rows

private struct PermissionRow: View {
    let permission: Permission
    let permissions: PermissionsManager

    private var status: PermissionStatus { permissions.status(of: permission) }

    var body: some View {
        SetupRow(systemImage: permission.systemImage, title: permission.title, detail: permission.explanation) {
            switch status {
            case .granted:
                StatusBadge(text: "Allowed", systemImage: "checkmark.circle.fill", color: .green)
            case .notGranted, .denied:
                VStack(alignment: .trailing, spacing: 4) {
                    Button(status == .denied ? "Open Settings…" : "Allow…") {
                        Task { await permissions.request(permission) }
                    }
                    .buttonStyle(.borderedProminent)
                    if status == .notGranted, permission != .microphone {
                        Button("Open System Settings") {
                            permissions.openSystemSettings(for: permission)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }
}

private struct GlobeKeyRow: View {
    let permissions: PermissionsManager

    var body: some View {
        let action = permissions.globeKey
        SetupRow(
            systemImage: "globe",
            title: "Globe key",
            detail: action == .doNothing
                ? "Pressing 🌐 on its own does nothing, so dictating won't open anything else."
                : "Set “Press 🌐 key to” to “Do Nothing”, and make sure macOS Dictation's shortcut doesn't use 🌐. Currently: \(action.title)."
        ) {
            if action == .doNothing {
                StatusBadge(text: "Ready", systemImage: "checkmark.circle.fill", color: .green)
            } else {
                Button("Keyboard Settings…", action: permissions.openKeyboardSettings)
            }
        }
    }
}

private struct HotkeyTestRow: View {
    let controller: DictationController

    var body: some View {
        SetupRow(systemImage: "hand.tap", title: "Try it", detail: detail) {
            switch controller.hotkeyStatus {
            case .running:
                HeldIndicator(isHeld: controller.state == .recording, isHandsFree: controller.isHandsFree)
            case .waitingForPermission:
                StatusBadge(text: "Waiting", systemImage: "hourglass", color: .secondary)
            case .failed:
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Relaunch Dictate", action: AppRelauncher.relaunch)
                        .buttonStyle(.borderedProminent)
                    Button("Try Again", action: controller.retryHotkey)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private var detail: String {
        switch controller.hotkeyStatus {
        case .waitingForPermission:
            return "The hotkey starts as soon as Accessibility is allowed."
        case .failed:
            return "macOS hasn't let Dictate watch the keyboard yet. After allowing Input Monitoring, macOS usually needs Dictate to relaunch."
        case .running:
            if controller.isSecureInputActive {
                return "Another app has secure keyboard input on (often a password field), which can hide the hotkey. Click away from it and try again."
            }
            if controller.isHandsFree {
                return "Hands-free: still listening. Press \(controller.triggerDescription) again to stop, or Esc to cancel."
            }
            if let held = controller.lastHoldDuration, controller.state == .idle {
                let seconds = (held / .seconds(1)).formatted(.number.precision(.fractionLength(2)))
                return "Got it: held for \(seconds) s. Hold \(controller.triggerDescription) + Space for hands-free."
            }
            return "Hold \(controller.triggerDescription). The dot lights up while it's held."
        }
    }
}

// MARK: - Building blocks

private struct SetupSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator)
        }
    }
}

private struct SetupRow<Accessory: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(12)
    }
}

private struct StatusBadge: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(color)
            .fixedSize()
    }
}

private struct HeldIndicator: View {
    let isHeld: Bool
    let isHandsFree: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isHeld ? Color.red : Color.secondary.opacity(0.3))
                .frame(width: 14, height: 14)
                .animation(.easeOut(duration: 0.1), value: isHeld)
            Text(isHandsFree ? "Hands-free" : isHeld ? "Listening" : "Idle")
                .foregroundStyle(isHeld ? .primary : .secondary)
                .frame(width: 72, alignment: .leading)
        }
        .fixedSize()
    }
}
