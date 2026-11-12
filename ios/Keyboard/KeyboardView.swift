import SwiftUI

struct KeyboardView: View {
    static let height: CGFloat = 268

    let model: KeyboardModel

    private static let letterRows = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]
    private static let numberRows = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    private static let symbolRows = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]

    var body: some View {
        VStack(spacing: 0) {
            MicBar(model: model)
                .frame(height: 54)
            keys
                .padding(.horizontal, 3)
                .padding(.bottom, 4)
        }
        .frame(height: Self.height)
    }

    private var rows: [[String]] {
        switch model.page {
        case .letters: Self.letterRows
        case .numbers: Self.numberRows
        case .symbols: Self.symbolRows
        }
    }

    private var keys: some View {
        VStack(spacing: 10) {
            row(rows[0])
            row(rows[1])
                .padding(.horizontal, model.page == .letters ? 18 : 0)
            HStack(spacing: 6) {
                switch model.page {
                case .letters:
                    SpecialKey(systemImage: model.shift == .off ? "shift" : (model.shift == .locked ? "capslock.fill" : "shift.fill"), width: 44) {
                        model.shiftTapped()
                    }
                case .numbers:
                    SpecialKey(title: "#+=", width: 44) { model.page = .symbols }
                case .symbols:
                    SpecialKey(title: "123", width: 44) { model.page = .numbers }
                }
                Spacer(minLength: 4)
                row(rows[2])
                Spacer(minLength: 4)
                RepeatingKey(systemImage: "delete.left", width: 44) { model.deleteBackward() }
            }
            HStack(spacing: 6) {
                SpecialKey(title: model.page == .letters ? "123" : "ABC", width: 50) {
                    model.page = model.page == .letters ? .numbers : .letters
                }
                if model.showsGlobe {
                    SpecialKey(systemImage: "globe", width: 44) { model.nextKeyboard() }
                }
                CharacterKey(label: "space", font: .system(size: 16)) { model.space() }
                SpecialKey(title: model.returnKeyTitle, width: 88) { model.returnKey() }
            }
        }
    }

    private func row(_ keys: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                let label = model.page == .letters && model.shift != .off ? key.uppercased() : key
                CharacterKey(label: label) { model.type(key) }
            }
        }
    }
}

// MARK: - Mic bar

/// The strip above the keys: hold the mic to talk, tap it to keep listening hands-free.
private struct MicBar: View {
    let model: KeyboardModel
    @State private var isPressing = false

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            micButton
            Button {
                model.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .opacity(showsCancel ? 1 : 0)
            .disabled(!showsCancel)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    private var showsCancel: Bool {
        model.phase == .recording || model.isWaiting
    }

    private var statusDot: some View {
        Circle()
            .fill(model.phase == .off ? Color.secondary.opacity(0.4) : (model.phase == .recording ? Color.red : Color.green))
            .frame(width: 8, height: 8)
    }

    private var statusText: String {
        if let notice = model.notice { return notice }
        if !model.hasFullAccess { return "Allow Full Access to dictate" }
        if model.isWaiting || model.phase == .transcribing { return "Transcribing…" }
        if model.isLocked { return "Listening. Tap to stop" }
        switch model.phase {
        case .recording: return "Listening…"
        case .ready: return "Hold to talk"
        case .transcribing: return "Transcribing…"
        case .off: return "Tap to start a session"
        }
    }

    private var micButton: some View {
        let recording = model.phase == .recording || model.isLocked
        return ZStack {
            Capsule()
                .fill(recording ? Color.red : Color.accentColor)
                .frame(width: 92, height: 40)
            if recording {
                LevelBars(level: model.level)
            } else if model.isWaiting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .scaleEffect(isPressing ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressing)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    isPressing = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    model.micPressed()
                }
                .onEnded { _ in
                    isPressing = false
                    model.micReleased()
                }
        )
        .accessibilityLabel("Dictate")
        .accessibilityHint("Hold to talk; tap to keep listening until the next tap")
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let shape: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: max(4, 24 * shape[i] * CGFloat(level)))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }
}

// MARK: - Keys

private enum KeyStyle {
    static let character = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
    static let special = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) })
    static let height: CGFloat = 42
}

private struct CharacterKey: View {
    let label: String
    var font: Font = .system(size: 22)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: KeyStyle.height, maxHeight: KeyStyle.height)
                .background(KeyStyle.character, in: RoundedRectangle(cornerRadius: 5))
                .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
        }
        .buttonStyle(KeyPressStyle())
    }
}

private struct SpecialKey: View {
    var title: String? = nil
    var systemImage: String? = nil
    let width: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18))
                } else {
                    Text(title ?? "").font(.system(size: 15))
                }
            }
            .foregroundStyle(.primary)
            .frame(width: width, height: KeyStyle.height)
            .background(KeyStyle.special, in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
        }
        .buttonStyle(KeyPressStyle())
    }
}

/// Delete: once on press, then repeating while held.
private struct RepeatingKey: View {
    let systemImage: String
    let width: CGFloat
    let action: () -> Void
    @State private var timer: Timer?
    @State private var isPressing = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18))
            .foregroundStyle(.primary)
            .frame(width: width, height: KeyStyle.height)
            .background(isPressing ? KeyStyle.character : KeyStyle.special, in: RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressing else { return }
                        isPressing = true
                        action()
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in action() }
                        }
                    }
                    .onEnded { _ in
                        isPressing = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
    }
}

private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.12 : 0)
    }
}
