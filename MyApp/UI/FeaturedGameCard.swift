import SwiftUI

/// A provider-backed feature with separate destinations for game information and TV.
struct FeaturedGameCard: View {
    let match: Match
    let confirmedStreams: Int
    let possibleStreams: Int
    let onWatch: () -> Void
    let onRemind: () -> Void
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(match.league.shortName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if BannerGameStatus(presentationOf: match) == .live {
                        LiveBadge()
                    } else {
                        Text(BannerGameStatus(presentationOf: match).displayTitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(match.state == .final ? Theme.textSecondary : Theme.upcoming)
                    }
                }
                NavigationLink(value: match) {
                    GameScoreRow(match: match,
                                 showsScore: match.state != .pre && !prefs.spoilerFreeMode,
                                 logoSize: 40, showsFullNames: true)
                }
                .buttonStyle(.plain)

                if match.state == .pre {
                    Text(match.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .font(Theme.Typography.callout.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                } else if !match.statusDetail.isEmpty {
                    Text(match.statusDetail)
                        .font(Theme.Typography.captionDigits)
                        .foregroundStyle(Theme.textSecondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.sm) { actions }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) { actions }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        NavigationLink(value: match) {
            Label("Game Centre", systemImage: "chevron.right")
                .font(Theme.Typography.caption)
                .frame(minHeight: 44)
        }
        .foregroundStyle(Theme.accessibleAccent)
        if match.state != .final {
            if confirmedStreams > 0 {
                Button(action: onWatch) {
                    Label("Watch", systemImage: "play.fill")
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, Theme.Spacing.md)
                        .frame(minHeight: 44)
                        .background(Theme.actionFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            } else if possibleStreams > 0 {
                Button("Possible broadcasts", action: onWatch)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.accessibleAccent)
                    .frame(minHeight: 44)
            } else {
                Text("No matched stream")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if BannerGameStatus(presentationOf: match) == .scheduled {
                Button(action: onRemind) { Image(systemName: "bell.badge") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Set reminder")
            }
        }
    }
}

/// Compact discovery row. A stable Match destination preserves existing Game Centre routing.
struct CompactGameRow: View {
    let match: Match
    let confirmedStreams: Int
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        NavigationLink(value: match) {
            Card(padding: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        Text(match.league.shortName)
                        Spacer()
                        if match.state == .live { LiveBadge() }
                        if confirmedStreams > 0 {
                            Image(systemName: "play.tv")
                                .foregroundStyle(Theme.accessibleAccent)
                                .accessibilityLabel("Matched broadcast")
                        }
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    if GameCentreArchetype(match: match).usesHeadToHeadParticipantUI {
                        CompactParticipantRow(side: match.leadingSide, showsScore: match.state != .pre && !prefs.spoilerFreeMode)
                        CompactParticipantRow(side: match.trailingSide, showsScore: match.state != .pre && !prefs.spoilerFreeMode)
                    } else {
                        Label(match.name, systemImage: match.league.group.systemImage)
                            .font(Theme.Typography.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if match.state == .pre {
                        Text(match.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(Theme.Typography.captionDigits)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text(match.statusDetail)
                            .font(Theme.Typography.captionDigits)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CompactParticipantRow: View {
    let side: TeamSide
    let showsScore: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            TeamLogo(url: side.logoURL, size: 24)
                .accessibilityHidden(true)
            Text(side.displayName)
                .font(Theme.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.xs)
            if showsScore, let score = side.score {
                Text(score).font(Theme.Typography.headlineDigits)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
