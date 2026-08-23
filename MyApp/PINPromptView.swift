import SwiftUI

// MARK: - PIN Prompt View

/// A full-screen PIN entry overlay for parental controls.
/// Validates against the SHA-256 hash stored in ParentalControlStore.
///
/// Callers should present this as a .fullScreenCover when a restricted channel is tapped.
/// On correct entry, calls onUnlock. Offers an optional 30-minute temporary unlock.
struct PINPromptView: View {
    let title: String
    var message: String = "Enter your parental controls PIN."
    let onUnlock: () -> Void
    var onCancel: (() -> Void)?

    @EnvironmentObject private var parentalControl: ParentalControlStore
    @Environment(\.dismiss) private var dismiss

    @State private var digits: [Int] = []
    @State private var shakeX: CGFloat = 0
    @State private var failCount = 0
    @State private var grantTemporary = false

    private let pinLength = 4

    var body: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Icon + title
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // PIN dots
                HStack(spacing: 18) {
                    ForEach(0..<pinLength, id: \.self) { i in
                        Circle()
                            .fill(i < digits.count ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 13, height: 13)
                    }
                }
                .offset(x: shakeX)

                if failCount > 0 {
                    Text(failCount == 1
                         ? "Incorrect PIN. Try again."
                         : "Incorrect PIN (\(failCount) attempt\(failCount == 1 ? "" : "s")).")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                        .transition(.opacity)
                }

                // Temporary unlock toggle
                Toggle(isOn: $grantTemporary) {
                    Text("Unlock for 30 minutes")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .tint(Theme.accent)
                .padding(.horizontal, 44)

                numPad

                Spacer()
            }
            .padding(.horizontal, 20)

            // Cancel button (top-right)
            if onCancel != nil {
                VStack {
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            onCancel?()
                            dismiss()
                        }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(20)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Numpad

    private var numPad: some View {
        VStack(spacing: 10) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { digit in
                        numKey(digit: digit)
                    }
                }
            }
            // Bottom row: empty | 0 | backspace
            HStack(spacing: 12) {
                Color.clear.frame(width: 74, height: 50)
                numKey(digit: 0)
                Button {
                    if !digits.isEmpty { digits.removeLast() }
                } label: {
                    Image(systemName: "delete.backward")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 74, height: 50)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func numKey(digit: Int) -> some View {
        Button { appendDigit(digit) } label: {
            Text("\(digit)")
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 74, height: 50)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Logic

    private func appendDigit(_ digit: Int) {
        guard digits.count < pinLength else { return }
        digits.append(digit)
        if digits.count == pinLength { validate() }
    }

    private func validate() {
        let pin = digits.map(String.init).joined()
        if parentalControl.verifyPIN(pin) {
            if grantTemporary { parentalControl.grantTemporaryUnlock() }
            dismiss()
            onUnlock()
        } else {
            failCount += 1
            animateShake()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                digits.removeAll()
            }
        }
    }

    private func animateShake() {
        let steps: [(Double, CGFloat)] = [(0.05, 10), (0.1, -9), (0.15, 7), (0.2, -5), (0.25, 3), (0.3, 0)]
        for (delay, x) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeInOut(duration: 0.04)) { shakeX = x }
            }
        }
    }
}

// MARK: - Parental Gate Modifier

/// View modifier that intercepts a channel-play action and shows a PIN prompt
/// when the channel is restricted. If the channel is unrestricted, the action
/// fires immediately without any UI.
struct ParentalGateModifier: ViewModifier {
    @EnvironmentObject private var parentalControl: ParentalControlStore
    @State private var showingPIN = false

    let channel: Channel?
    let onAllowed: () -> Void

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                guard let ch = channel else { onAllowed(); return }
                if parentalControl.isRestricted(ch) {
                    showingPIN = true
                } else {
                    onAllowed()
                }
            }
            .fullScreenCover(isPresented: $showingPIN) {
                if let ch = channel {
                    PINPromptView(
                        title: "Parental Controls",
                        message: "\"\(ch.name)\" is restricted.",
                        onUnlock: { onAllowed() },
                        onCancel: {}
                    )
                    .environmentObject(parentalControl)
                }
            }
    }
}

extension View {
    /// Wraps a tap action with a parental PIN gate when the channel is restricted.
    func parentalGate(channel: Channel?, onAllowed: @escaping () -> Void) -> some View {
        modifier(ParentalGateModifier(channel: channel, onAllowed: onAllowed))
    }
}
