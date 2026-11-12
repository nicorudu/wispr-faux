import AppKit
import Observation
import SwiftUI

/// What the pill shows. nil hides it.
enum PillContent: Equatable {
    case listening(handsFree: Bool)
    case transcribing
    case notice(Notice)
}

/// A short message in the pill, e.g. "No text field. Copied: press ⌘V to paste".
struct Notice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var systemImage: String
    var isWarning = false
}

/// The floating capsule at the bottom of the screen (BUILD_PLAN.md §5, gotcha 5): a
/// borderless, non-activating panel that can never become key, so ⌘V always lands in the
/// app the user is typing in. Ignores the mouse; shows on every Space, over full-screen apps.
@MainActor
final class StatusPillController {
    private let controller: DictationController
    private let panel: StatusPanel
    private let hostingView: NSHostingView<StatusPillView>
    private var isShown = false

    init(controller: DictationController) {
        self.controller = controller
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0

        hostingView = NSHostingView(rootView: StatusPillView(controller: controller))
        hostingView.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hostingView
    }

    /// Follows `controller.pillContent` for as long as the app runs.
    func start() {
        observe()
    }

    private func observe() {
        let content = withObservationTracking {
            controller.pillContent
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        apply(content)
    }

    private func apply(_ content: PillContent?) {
        guard content != nil else {
            guard isShown else { return }
            isShown = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            })
            return
        }
        // Size to the new content, then center at the bottom of the active screen.
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrame(
                NSRect(x: area.midX - size.width / 2, y: area.minY + 28, width: size.width, height: size.height),
                display: true
            )
        }
        guard !isShown else { return }
        isShown = true
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }
}

/// Never key, never main: clicks and keystrokes stay with the user's app.
private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct StatusPillView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 8) {
            switch controller.pillContent {
            case .listening(let handsFree):
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                LevelBars(level: controller.inputLevel)
                Text(handsFree ? "Hands-free · press \(controller.triggerSymbol) to stop" : "Listening")
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                if controller.transcription.status == .loading {
                    // After a restart or macOS update, preparing the model can take minutes.
                    Text("Loading speech model, one moment")
                } else {
                    Text("Transcribing")
                }
                Text("esc to cancel")
                    .foregroundStyle(.white.opacity(0.5))
            case .notice(let notice):
                Image(systemName: notice.systemImage)
                    .foregroundStyle(notice.isWarning ? .orange : .white)
                Text(notice.text)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .padding(6) // Room for the shadow.
    }
}

/// Five bars that follow the microphone level.
private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.55, 0.85, 1, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: 3 + 13 * CGFloat(min(1, max(0, level))) * weights[index])
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: level)
    }
}
