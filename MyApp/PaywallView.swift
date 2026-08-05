import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

// MARK: - Full-screen paywall sheet

struct PaywallView: View {
    @EnvironmentObject private var entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID = EntitlementStore.monthlyID
    @State private var isRestoring = false
    @State private var showSuccess = false

    // MARK: Feature list

    private static let features: [(icon: String, title: String, description: String, tint: Color)] = [
        ("play.circle.fill",           "Game Center",       "Roster, live leaders and deep team stats",       Theme.accent),
        ("list.bullet.clipboard.fill", "Play by Play",      "Real-time feed of every key moment",             Color(hex: 0xFF6B35)),
        ("rectangle.grid.2x2.fill",    "Multiscreen",       "Watch up to 4 games side by side",               Color(hex: 0x34C759)),
        ("chart.line.uptrend.xyaxis",  "Full Standings",    "Conference & division tables with every column", Color(hex: 0x30B0C7)),
        ("cross.case.fill",            "Injury Reports",    "League-wide injury and availability updates",    Color(hex: 0xFF453A)),
        ("bell.badge.fill",            "Smart Alerts",      "Game reminders and close-game notifications",    Color(hex: 0xFFCC00)),
        ("sunrise.fill",               "Morning Briefing",  "Daily 8 AM digest of today's games",            Color(hex: 0xE67E22)),
    ]

    // MARK: Derived

    private var selectedProduct: Product? {
        switch selectedID {
        case EntitlementStore.monthlyID:  return entitlements.monthlyProduct
        case EntitlementStore.annualID:   return entitlements.annualProduct
        default:                          return entitlements.lifetimeProduct
        }
    }

    private var isLifetimeSelected: Bool { selectedID == EntitlementStore.lifetimeID }
    private var isMonthlySelected: Bool  { selectedID == EntitlementStore.monthlyID  }

    private var ctaLabel: String {
        if entitlements.isPurchasing { return "Processing…" }
        if isMonthlySelected { return "Start 7-Day Free Trial" }
        guard let product = selectedProduct else {
            return isLifetimeSelected ? "Unlock Forever — $24.99" : "Subscribe — $14.99 / year"
        }
        return isLifetimeSelected
            ? "Unlock Forever — \(product.displayPrice)"
            : "Subscribe — \(product.displayPrice) / year"
    }

    private var ctaGradient: LinearGradient {
        if isLifetimeSelected {
            return LinearGradient(colors: [Color(hex: 0xFFD700), Color(hex: 0xE8A020)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else if isMonthlySelected {
            return LinearGradient(colors: [Color(hex: 0x34C759), Color(hex: 0x1A9E40)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            return LinearGradient(colors: [Theme.accent, Color(hex: 0x1A6FE8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var ctaShadowColor: Color {
        if isLifetimeSelected { return Color(hex: 0xFFD700) }
        if isMonthlySelected  { return Color(hex: 0x34C759) }
        return Theme.accent
    }

    private var footerDisclosure: String {
        if isLifetimeSelected { return "One-time purchase. No ongoing charges." }
        if isMonthlySelected  { return "Free for 7 days, then auto-renews monthly. Cancel anytime in App Store settings." }
        return "Auto-renews annually. Cancel anytime in App Store settings."
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // Deep navy base
            Color(hex: 0x060D1B).ignoresSafeArea()

            // Subtle accent glow at the top
            RadialGradient(
                gradient: Gradient(colors: [Theme.accent.opacity(0.14), Color.clear]),
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 60,
                endRadius: 400
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 38, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 26) {
                        headerSection
                        featureListSection
                        planSelectorSection
                        ctaSection
                        footerSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 44)
                }
            }
        }
        .overlay {
            if showSuccess {
                PremiumSuccessOverlay()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)),
                        removal: .opacity
                    ))
            }
        }
        .onChange(of: entitlements.isPremium) { _, isPremium in
            if isPremium {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                    showSuccess = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    dismiss()
                }
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                BrandMark()
                Text("PREMIUM")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }

            Text("Every sport.\nEvery moment. Unlocked.")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            // Free trial callout
            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                    .font(.caption.weight(.semibold))
                Text("7-day free trial — no charge today")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color(hex: 0x34C759))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(hex: 0x34C759).opacity(0.12), in: Capsule())
        }
        .padding(.top, 8)
    }

    // MARK: Feature list

    private var featureListSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(feature.tint.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: feature.icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(feature.tint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    Spacer()

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(feature.tint.opacity(0.8))
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 16)

                if index < Self.features.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                }
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    // MARK: Plan selector

    private var planSelectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose your plan")
                .font(.footnote.weight(.heavy))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)

            // Monthly — featured full-width card
            monthlyPlanCard

            // Annual + Lifetime — side by side
            HStack(spacing: 12) {
                planCard(
                    id: EntitlementStore.annualID,
                    badge: "SAVE 25%",
                    badgeColor: Theme.accent,
                    label: "ANNUAL",
                    price: entitlements.annualProduct?.displayPrice ?? "$14.99",
                    period: "per year",
                    note: "~$1.25 / month · cancel anytime"
                )
                planCard(
                    id: EntitlementStore.lifetimeID,
                    badge: "BEST VALUE",
                    badgeColor: Color(hex: 0xFFCC00),
                    label: "LIFETIME",
                    price: entitlements.lifetimeProduct?.displayPrice ?? "$24.99",
                    period: "one-time",
                    note: "Pay once · yours forever"
                )
            }

            // Upsell strip — shown when monthly is selected
            if isMonthlySelected {
                upsellStrip
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var monthlyPlanCard: some View {
        let isSelected = isMonthlySelected
        let cardColor = Color(hex: 0x34C759)

        return Button {
            withAnimation(.spring(duration: 0.22)) { selectedID = EntitlementStore.monthlyID }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("MOST POPULAR")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(isSelected ? cardColor : .white.opacity(0.35))
                    Spacer()
                    Text("7 DAYS FREE")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(cardColor, in: Capsule())
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entitlements.monthlyProduct?.displayPrice ?? "$1.99")
                        .font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("/ month")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Text("Free for 7 days · then billed monthly · cancel anytime")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? cardColor.opacity(0.12) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? cardColor : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // Shown below plan cards when monthly is selected — nudges user toward annual or lifetime
    private var upsellStrip: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                Text("Want to save even more?")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack(spacing: 10) {
                // Annual upgrade
                Button {
                    withAnimation(.spring(duration: 0.22)) { selectedID = EntitlementStore.annualID }
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    VStack(spacing: 4) {
                        Text("SAVE 25%")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule())
                        Text("Annual")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                        Text(entitlements.annualProduct?.displayPrice ?? "$14.99")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("per year")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
                }
                .buttonStyle(.plain)

                // Lifetime upgrade
                Button {
                    withAnimation(.spring(duration: 0.22)) { selectedID = EntitlementStore.lifetimeID }
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                } label: {
                    VStack(spacing: 4) {
                        Text("ONE-TIME")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: 0xFFCC00), in: Capsule())
                        Text("Lifetime")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                        Text(entitlements.lifetimeProduct?.displayPrice ?? "$24.99")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("one-time")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(hex: 0xFFCC00).opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: 0xFFCC00).opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }

    private func planCard(id: String, badge: String?, badgeColor: Color, label: String, price: String, period: String, note: String) -> some View {
        let isSelected = selectedID == id
        let isLifetime = id == EntitlementStore.lifetimeID
        let accentForCard: Color = isLifetime ? Color(hex: 0xFFCC00) : Theme.accent

        return Button {
            withAnimation(.spring(duration: 0.22)) { selectedID = id }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .center, spacing: 4) {
                    Text(label)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(isSelected ? accentForCard : .white.opacity(0.35))
                        .padding(.bottom, 2)

                    Text(price)
                        .font(.system(size: 26, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)

                    Text(period)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))

                    Divider()
                        .overlay(Color.white.opacity(0.07))
                        .padding(.vertical, 5)

                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    isSelected ? accentForCard.opacity(0.12) : Color.white.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? accentForCard : Color.white.opacity(0.1), lineWidth: isSelected ? 1.5 : 1)
                )

                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(badgeColor, in: Capsule())
                        .padding(.trailing, 10)
                        .padding(.top, -1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: CTA button

    private var ctaSection: some View {
        Button {
            Task {
                if let product = selectedProduct {
                    await entitlements.purchase(product)
                }
            }
        } label: {
            ZStack {
                if entitlements.isPurchasing {
                    ProgressView().tint(.white)
                } else {
                    Text(ctaLabel)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(ctaGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: ctaShadowColor.opacity(0.45), radius: 18, y: 7)
        }
        .disabled(entitlements.isPurchasing)
    }

    // MARK: Footer

    private var footerSection: some View {
        VStack(spacing: 10) {
            Button {
                isRestoring = true
                Task {
                    await entitlements.restore()
                    isRestoring = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isRestoring {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    }
                    Text("Restore Purchases")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)

            Button {
                entitlements.redeemOfferCode()
            } label: {
                Text("Redeem Code")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            if let error = entitlements.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.live)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Text(footerDisclosure)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.28))
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - In-context gate overlay

/// Blurs a view and shows a lock card on top when the user isn't premium.
struct PremiumGateOverlay: View {
    let icon: String
    let title: String
    let description: String
    @Binding var showPaywall: Bool

    var body: some View {
        ZStack {
            // Semi-transparent blur backdrop
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                VStack(spacing: 5) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Button {
                    showPaywall = true
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                } label: {
                    Text("Unlock Premium")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .padding(24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Premium lock badge for section tiles

/// Small lock badge overlaid on navigation tiles in the overview grid.
struct PremiumLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Theme.accent, in: Circle())
            .offset(x: -6, y: 6)
    }
}

// MARK: - Post-purchase success celebration

struct PremiumSuccessOverlay: View {
    @State private var scale: CGFloat = 0.5
    @State private var checkOpacity: Double = 0
    @State private var ringScale: CGFloat = 0.6
    @State private var ringOpacity: Double = 0.6

    var body: some View {
        ZStack {
            Color(hex: 0x060D1B).ignoresSafeArea()

            RadialGradient(
                gradient: Gradient(colors: [Theme.accent.opacity(0.18), Color.clear]),
                center: .center,
                startRadius: 80,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    // Expanding ring
                    Circle()
                        .stroke(Theme.accent.opacity(ringOpacity), lineWidth: 2)
                        .frame(width: 130, height: 130)
                        .scaleEffect(ringScale)

                    // Filled circle
                    Circle()
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: 100, height: 100)

                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .black))
                        .foregroundStyle(Theme.accent)
                        .opacity(checkOpacity)
                        .scaleEffect(scale)
                }

                VStack(spacing: 8) {
                    Text("You're Premium")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Every feature unlocked. Enjoy the game.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                scale = 1.0
                checkOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 1.1)) {
                ringScale = 1.4
                ringOpacity = 0
            }
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
    }
}

// MARK: - Premium status card (used in Settings)

struct PremiumStatusCard: View {
    @EnvironmentObject private var entitlements: EntitlementStore
    @Binding var showPaywall: Bool

    var body: some View {
        if entitlements.isPremium {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium Member")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("All features unlocked")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                    Text("Manage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Theme.surface)
        } else {
            Button { showPaywall = true } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.accent.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade to Premium")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Game Center · Multiscreen · Play by Play")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 6)
            }
            .listRowBackground(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.08), Theme.surface],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - Full-section paywall intercept (used in StatsView tabs)

struct PremiumSectionGate: View {
    let icon: String
    let title: String
    let description: String
    @Binding var showPaywall: Bool

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 80, height: 80)
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button {
                    showPaywall = true
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                } label: {
                    Label("Unlock Premium", systemImage: "lock.open.fill")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 5)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
