import SwiftUI

/// A shared matchup layout that grows vertically for accessibility text sizes.
struct GameScoreRow: View {
    let match: Match
    var showsScore = true
    var logoSize: CGFloat = 44
    var showsFullNames = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !GameCentreArchetype(match: match).usesHeadToHeadParticipantUI {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label(match.name, systemImage: match.league.group.systemImage)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let venue = match.venue, !venue.isEmpty {
                        Text(venue)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    team(match.leadingSide)
                    score
                    team(match.trailingSide)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    team(match.leadingSide)
                        .frame(maxWidth: .infinity)
                    score
                        .frame(height: logoSize)
                        .layoutPriority(1)
                    team(match.trailingSide)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GameCentreArchetype(match: match).usesHeadToHeadParticipantUI
            ? "\(match.leadingSide.displayName) versus \(match.trailingSide.displayName)" : match.name)
        .accessibilityValue(GameCentreArchetype(match: match).usesHeadToHeadParticipantUI && showsScore
            ? "\(match.leadingSide.score ?? "–") to \(match.trailingSide.score ?? "–")" : match.statusDetail)
    }

    private var score: some View {
        Group {
            if showsScore {
                Text("\(match.leadingSide.score ?? "–") – \(match.trailingSide.score ?? "–")")
                    .font(Theme.Typography.score)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: match.leadingSide.score)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: match.trailingSide.score)
            } else {
                Text("VS")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize()
        .foregroundStyle(Theme.textPrimary)
    }

    private func team(_ side: TeamSide) -> some View {
        VStack(spacing: 6) {
            TeamLogo(url: side.logoURL, size: logoSize)
                .accessibilityHidden(true)
            Text(showsFullNames ? side.displayName : (side.abbreviation.isEmpty ? side.shortName : side.abbreviation))
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.displayName)
    }
}
