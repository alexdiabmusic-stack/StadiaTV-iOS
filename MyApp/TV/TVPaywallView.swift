#if os(tvOS)
import SwiftUI
import StoreKit

struct TVPaywallView: View {
    @EnvironmentObject private var entitlements: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 48) {
                Spacer()
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("StadiaTV Premium")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Unlock standings, leaders, injury reports, and multiscreen.")
                        .font(.title2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 700)
                }
                // Feature highlights
                HStack(spacing: 24) {
                    featureTile(icon: "list.number", title: "Standings")
                    featureTile(icon: "chart.bar.fill", title: "Leaders")
                    featureTile(icon: "cross.case.fill", title: "Injuries")
                    featureTile(icon: "rectangle.split.2x1.fill", title: "Multiscreen")
                }
                // Products
                if entitlements.products.isEmpty {
                    ProgressView().tint(Theme.accent)
                } else {
                    HStack(spacing: 24) {
                        if let annual = entitlements.annualProduct {
                            productButton(product: annual, badge: "Best Value")
                        }
                        if let lifetime = entitlements.lifetimeProduct {
                            productButton(product: lifetime, badge: nil)
                        }
                    }
                }
                // Error
                if let error = entitlements.purchaseError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
                // Restore & Close
                HStack(spacing: 32) {
                    Button("Restore Purchases") {
                        Task { await entitlements.restore() }
                    }
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.card)

                    Button("Not Now") { dismiss() }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .buttonStyle(.card)
                }
                Spacer()
            }
            .padding(.horizontal, 80)
        }
        .onExitCommand { dismiss() }
        .task { await entitlements.loadAll() }
        .onChange(of: entitlements.isPremium) { _, isPremium in
            if isPremium { dismiss() }
        }
    }

    private func featureTile(icon: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func productButton(product: Product, badge: String?) -> some View {
        Button {
            Task { await entitlements.purchase(product) }
        } label: {
            VStack(spacing: 10) {
                if let badge {
                    Text(badge.uppercased())
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                }
                Text(product.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(product.displayPrice)
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.accent)
                if let desc = product.description.split(separator: ".").first {
                    Text(String(desc))
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if entitlements.isPurchasing {
                    ProgressView().tint(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1.5))
        }
        .buttonStyle(.card)
        .disabled(entitlements.isPurchasing)
    }
}
#endif
