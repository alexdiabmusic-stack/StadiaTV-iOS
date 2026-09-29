import SwiftUI

// Shared building blocks for the Theme design tokens. Prefer these over
// hand-rolled backgrounds, radii and paddings in new or migrated screens.

// MARK: - Card

/// Surface + hairline border + large radius.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Chip

struct Chip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: 32)
            .background(isSelected ? Theme.accent : Theme.surfaceElevated,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Live badge

struct LiveBadge: View {
    var title: String = "LIVE"

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            PulsingLiveDot()
            Text(title)
        }
        .font(Theme.Typography.overline)
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Theme.live, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}

private struct PulsingLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 6, height: 6)
            .opacity(pulsing ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
            }
    }
}

// MARK: - Button styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(Theme.actionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Icon-only button with a 44×44 hit area regardless of glyph size.
struct IconButtonStyle: ButtonStyle {
    var background: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .frame(minWidth: 44, minHeight: 44)
            .background(background, in: Circle())
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accessibleAccent)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Channel logo

/// Channel logo in a rounded tile, with a monogram when there's no logo or it fails to load.
struct ChannelLogo: View {
    let url: URL?
    let name: String
    var size: CGFloat = 56

    var body: some View {
        CachedImage(url: url) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                Text(monogram)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityHidden(true)
    }

    private var monogram: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Skeleton row

/// Placeholder row shown while channels load.
struct SkeletonRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm / 2).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: Theme.Radius.sm / 2).frame(width: 110, height: 10)
            }
            Spacer()
        }
        .foregroundStyle(Theme.surfaceElevated)
        .opacity(dimmed ? 0.5 : 1)
        .frame(height: 72)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dimmed = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Design gallery

#if DEBUG
/// Every token and component on one screen, for checking light and dark appearance.
struct DesignGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SectionHeader(title: "Typography")
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Display").font(Theme.Typography.display)
                    Text("Title").font(Theme.Typography.title)
                    Text("Headline").font(Theme.Typography.headline)
                    Text("Body").font(Theme.Typography.body)
                    Text("Callout").font(Theme.Typography.callout)
                    Text("Caption").font(Theme.Typography.caption)
                    Text("Overline").overlineStyle()
                    Text("2 – 1  ·  12:45").font(Theme.Typography.headlineDigits)
                }
                .foregroundStyle(Theme.textPrimary)

                SectionHeader(title: "Colours")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: Theme.Spacing.xs) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                        VStack(spacing: Theme.Spacing.xxs) {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(swatch.1).frame(height: 40)
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.hairline))
                            Text(swatch.0).font(Theme.Typography.overline).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                SectionHeader(title: "Spacing & radius", actionTitle: "Action") {}
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach([Theme.Radius.sm, Theme.Radius.md, Theme.Radius.lg, Theme.Radius.xl], id: \.self) { radius in
                        RoundedRectangle(cornerRadius: radius).fill(Theme.surfaceElevated).frame(width: 56, height: 56)
                    }
                }

                SectionHeader(title: "Components")
                Card {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack { Chip(title: "Selected", isSelected: true) {}; Chip(title: "Chip", systemImage: "star", isSelected: false) {} }
                        LiveBadge()
                        HStack(spacing: Theme.Spacing.sm) {
                            ChannelLogo(url: nil, name: "Sky Sports")
                            Button { } label: { Image(systemName: "heart") }.buttonStyle(IconButtonStyle(background: Theme.surfaceElevated))
                        }
                        Button("Primary") {}.buttonStyle(PrimaryButtonStyle())
                        Button("Secondary") {}.buttonStyle(SecondaryButtonStyle())
                        SkeletonRow()
                    }
                }
                EmptyStateView(systemImage: "tv", title: "No channels", message: "Add a playlist to get started.", actionTitle: "Add Playlist") {}
                    .frame(height: 280)
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.background)
    }

    private var swatches: [(String, Color)] {
        [("bg", Theme.background), ("surface", Theme.surface), ("elevated", Theme.surfaceElevated),
         ("accent", Theme.accent), ("action", Theme.actionFill), ("live", Theme.live),
         ("starting", Theme.starting), ("upcoming", Theme.upcoming), ("text", Theme.textPrimary),
         ("text 2", Theme.textSecondary), ("text 3", Theme.textTertiary)]
    }
}

#Preview("Design gallery · dark") {
    DesignGallery().preferredColorScheme(.dark)
}

#Preview("Design gallery · light") {
    DesignGallery().preferredColorScheme(.light)
}
#endif
