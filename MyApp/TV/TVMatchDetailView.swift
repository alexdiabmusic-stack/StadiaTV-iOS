#if os(tvOS)
import SwiftUI

struct TVMatchDetailView: View {
    let match: Match
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var playingChannel: Channel?

    private var rankedSources: [RankedSource] {
        SourceMatcher.rank(
            match: match,
            channels: playlistStore.allChannels,
            preferredLanguages: prefs.preferredStreamLanguages
        )
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    matchHero
                    if !rankedSources.isEmpty {
                        TVShelfRow(title: "Stream Sources", systemImage: "play.tv.fill") {
                            ForEach(rankedSources) { source in
                                TVSourceTile(channel: source.channel, score: source.score) {
                                    playingChannel = source.channel
                                }
                            }
                        }
                    } else if !playlistStore.playlists.isEmpty {
                        noSourcesNote
                    }
                    if !match.broadcasts.isEmpty {
                        broadcastsSection
                    }
                    matchInfoSection
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 48)
            }
        }
        .navigationTitle(match.shortName)
        .fullScreenCover(item: $playingChannel) { channel in
            TVPlayerView(channel: channel)
        }
    }

    // MARK: - Hero scoreboard

    private var matchHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(
                    colors: [Theme.surface, Theme.surfaceElevated],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
            HStack(spacing: 0) {
                // Home
                teamColumn(side: match.home)
                // Center status
                VStack(spacing: 14) {
                    if match.state == .live { TVLiveBadge() }
                    Text(match.state == .pre ? "VS" : match.statusDetail)
                        .font(match.state == .pre ? .title.weight(.bold) : .headline.weight(.bold))
                        .foregroundStyle(match.state == .pre ? Theme.textSecondary : Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(match.league.shortName.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .tracking(1.5)
                }
                .frame(maxWidth: 180)
                // Away
                teamColumn(side: match.away)
            }
            .padding(.vertical, 40)
        }
    }

    private func teamColumn(side: TeamSide) -> some View {
        VStack(spacing: 12) {
            TVTeamLogo(url: side.logoURL, size: 90)
            Text(side.abbreviation)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let score = side.score {
                Text(score)
                    .font(.system(size: 56, weight: .black, design: .rounded))
                    .foregroundStyle(side.isWinner ? Theme.accent : Theme.textPrimary)
                    .monospacedDigit()
            }
            if let record = side.record {
                Text(record)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - No sources note

    private var noSourcesNote: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No matching streams found")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("The source matcher didn't find a channel that matches this match.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    // MARK: - Broadcasts

    private var broadcastsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Broadcasts", systemImage: "antenna.radiowaves.left.and.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                ForEach(match.broadcasts, id: \.self) { network in
                    Text(network)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline))
                }
            }
        }
    }

    // MARK: - Match info

    private var matchInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Match Info", systemImage: "info.circle.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                infoRow(label: "League", value: match.league.name)
                Divider().background(Theme.hairline)
                infoRow(label: "Status", value: match.statusDetail)
                if let venue = match.venue {
                    Divider().background(Theme.hairline)
                    infoRow(label: "Venue", value: venue)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
#endif
