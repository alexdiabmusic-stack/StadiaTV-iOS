import SwiftUI

// MARK: - Onboarding step enum

enum OnboardingStep: Int, CaseIterable {
    case welcome   = 0
    case sports    = 1
    case favorites = 2
    case watch     = 3

    var progressLabel: String {
        switch self {
        case .welcome:   return ""
        case .sports:    return "1 of 3"
        case .favorites: return "2 of 3"
        case .watch:     return "3 of 3"
        }
    }

    var progressFraction: Double {
        switch self {
        case .welcome:   return 0
        case .sports:    return 1.0 / 3.0
        case .favorites: return 2.0 / 3.0
        case .watch:     return 1.0
        }
    }
}

// MARK: - Progress bar

struct OnboardingProgressBar: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1..<4) { index in
                Capsule()
                    .fill(index <= (step.rawValue) ? Theme.accent : Theme.surfaceElevated)
                    .frame(height: 3)
                    .animation(.easeInOut(duration: 0.2), value: step)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Step header

struct OnboardingStepHeader: View {
    let step: OnboardingStep
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.progressLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .textCase(.uppercase)
                .tracking(1)
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Bottom navigation bar

struct OnboardingBottomBar: View {
    let step: OnboardingStep
    let canContinue: Bool
    let continueLabel: String
    let onBack: () -> Void
    let onContinue: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var maxWidth: CGFloat { sizeClass == .regular ? 600 : .infinity }

    var body: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.hairline)
            HStack(spacing: 12) {
                if step != .sports {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .frame(height: 50)
                        .padding(.horizontal, 16)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Button(action: onContinue) {
                    Text(continueLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(canContinue ? Theme.accent : Theme.accent.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canContinue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

// MARK: - Sport icon helper

struct SportIcon: View {
    let systemImage: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size, weight: .medium))
    }
}
