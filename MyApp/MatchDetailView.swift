import SwiftUI

struct MatchDetailView: View {
    let match: Match
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAllChannels = false
    @State private var playingChannel: Channel?
    @State private var isPickingMultiscreen = false
    @State private var selectedMultiChannelIDs: Set<String> = []
    @State private var multiscreenSession: MultiscreenSession?

    private var rankedSources: [RankedSource] {
        SourceMatcher.rank(match: match, channels: playlists.allChannels)
    }

    private var displayedChannels: [Channel] {
        showingAllChannels ? playlists.allChannels : rankedSources.map(\.channel)
    }

    private var selectedMultiScreenChannels: [Channel] {
        displayedChannels.filter { selectedMultiChannelIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    scoreboard
                    sourcesSection
                }
                .padding(16)
                .padding(.bottom, isPickingMultiscreen ? 92 : 0)
            }

            if isPickingMultiscreen {
                multiscreenFooter
            }
        }
        .navigationTitle(match.league.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(item: $playingChannel) { channel in
            PlayerView(channel: channel)
        }
        .fullScreenCover(item: $multiscreenSession) { session in
            MultiScreenPlayerView(channels: session.channels)
        }
    }

    // MARK: Scoreboard header

    private var scoreboard: some View {
        VStack(spacing: 16) {
            statusLine
            HStack(alignment: .center) {
                teamColumn(match.away)
                VStack(spacing: 4) {
                    if match.state == .pre {
                        Text("VS").font(.headline).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("\(match.away.score ?? "-")  –  \(match.home.score ?? "-")")
                            .font(.title.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                teamColumn(match.home)
            }
            if let venue = match.venue {
                Label(venue, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !match.broadcasts.isEmpty {
                Label(match.broadcasts.joined(separator: ", "), systemImage: "tv")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if match.state == .live {
                Circle().fill(Theme.live).frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(.footnote.weight(.bold))
                .foregroundStyle(match.state == .live ? Theme.live : Theme.textSecondary)
        }
    }

    private var statusText: String {
        switch match.state {
        case .live: return "LIVE · \(match.statusDetail)"
        case .final: return "FINAL"
        case .pre:
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: match.date)
        }
    }

    private func teamColumn(_ team: TeamSide) -> some View {
        VStack(spacing: 8) {
            TeamLogo(url: team.logoURL, size: 56)
            Text(team.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let record = team.record, !record.isEmpty {
                Text(record).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcesHeader

            if playlists.allChannels.isEmpty {
                noPlaylistsHint
            } else if showingAllChannels {
                ForEach(playlists.allChannels) { channel in
                    SourceRow(name: channel.name, subtitle: channel.playlistName,
                              logoURL: channel.logoURL, score: nil,
                              isPicking: isPickingMultiscreen,
                              isSelected: selectedMultiChannelIDs.contains(channel.id)) {
                        handleSourceTap(channel)
                    }
                }
            } else if rankedSources.isEmpty {
                emptyMatches
            } else {
                ForEach(rankedSources) { source in
                    SourceRow(name: source.channel.name,
                              subtitle: source.channel.group ?? source.channel.playlistName,
                              logoURL: source.channel.logoURL,
                              score: source.score,
                              isPicking: isPickingMultiscreen,
                              isSelected: selectedMultiChannelIDs.contains(source.channel.id)) {
                        handleSourceTap(source.channel)
                    }
                }
            }
        }
    }

    private var sourcesHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showingAllChannels ? "All Channels" : "Matched Sources")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick one source or combine up to four screens.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if playlists.allChannels.count >= 2 {
                Button {
                    toggleMultiscreenPicking()
                } label: {
                    Image(systemName: isPickingMultiscreen ? "checkmark.rectangle.stack" : "rectangle.grid.2x2")
                        .font(.headline)
                        .foregroundStyle(isPickingMultiscreen ? .white : Theme.accent)
                        .frame(width: 38, height: 34)
                        .background(isPickingMultiscreen ? Theme.accent : Theme.surfaceElevated,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPickingMultiscreen ? "Finish multiscreen selection" : "Select multiscreen sources")
            }
            if !playlists.allChannels.isEmpty {
                Button(showingAllChannels ? "Matches" : "All") {
                    withAnimation {
                        showingAllChannels.toggle()
                        resetMultiscreenSelection()
                    }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var multiscreenFooter: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("\(selectedMultiScreenChannels.count)/4", systemImage: "rectangle.grid.2x2")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Select at least two sources")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation { resetMultiscreenSelection() }
                }
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    startMultiscreen()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .foregroundStyle(.white)
                .background(canStartMultiscreen ? Theme.accent : Theme.accent.opacity(0.36),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .disabled(!canStartMultiscreen)
            }
        }
        .padding(12)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var canStartMultiscreen: Bool {
        selectedMultiScreenChannels.count >= 2
    }

    private func toggleMultiscreenPicking() {
        withAnimation {
            if isPickingMultiscreen {
                resetMultiscreenSelection()
            } else {
                isPickingMultiscreen = true
                selectedMultiChannelIDs = Set(displayedChannels.prefix(2).map(\.id))
            }
        }
    }

    private func handleSourceTap(_ channel: Channel) {
        if isPickingMultiscreen {
            toggleSelected(channel)
        } else {
            playingChannel = channel
        }
    }

    private func toggleSelected(_ channel: Channel) {
        if selectedMultiChannelIDs.contains(channel.id) {
            selectedMultiChannelIDs.remove(channel.id)
        } else if selectedMultiChannelIDs.count < 4 {
            selectedMultiChannelIDs.insert(channel.id)
        }
    }

    private func startMultiscreen() {
        let channels = Array(selectedMultiScreenChannels.prefix(4))
        guard channels.count >= 2 else { return }
        multiscreenSession = MultiscreenSession(channels: channels)
        resetMultiscreenSelection()
    }

    private func resetMultiscreenSelection() {
        isPickingMultiscreen = false
        selectedMultiChannelIDs.removeAll()
    }

    private var noPlaylistsHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.and.film")
                .font(.title)
                .foregroundStyle(Theme.textSecondary)
            Text("Add an M3U or Xtream playlist in the Playlists tab to unlock streaming sources.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var emptyMatches: some View {
        VStack(spacing: 8) {
            Text("No channels matched this game automatically.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Browse all channels") { withAnimation { showingAllChannels = true } }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct MultiscreenSession: Identifiable {
    let id = UUID()
    let channels: [Channel]
}

// MARK: - Source row

private struct SourceRow: View {
    let name: String
    let subtitle: String
    let logoURL: URL?
    let score: Int?
    let isPicking: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "play.tv")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if let score, !isPicking {
                    MatchStrengthBadge(score: score)
                }
                trailingIcon
            }
            .padding(12)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingIcon: some View {
        if isPicking {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
        } else {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
        }
    }

    private var rowBackground: Color {
        isSelected ? Theme.accent.opacity(0.15) : Theme.surface
    }

    private var rowBorder: Color {
        isSelected ? Theme.accent : Theme.hairline
    }
}

/// Shows how confident the matcher is about a source.
private struct MatchStrengthBadge: View {
    let score: Int

    private var label: String {
        switch score {
        case 100...: return "Best"
        case 50..<100: return "Strong"
        case 25..<50: return "Likely"
        default: return "Possible"
        }
    }

    private var color: Color {
        switch score {
        case 100...: return Theme.accent
        case 50..<100: return Color(hex: 0x3DBE6B)
        default: return Theme.textSecondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
