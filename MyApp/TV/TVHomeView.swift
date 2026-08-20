#if os(tvOS)
import SwiftUI

struct TVHomeView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var watchStore: WatchStore
    @StateObject private var viewModel = HomeViewModel()
    @State private var selectedChannel: Channel?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if viewModel.isLoading && viewModel.liveNow.isEmpty && viewModel.upcoming.isEmpty {
                    ProgressView().tint(Theme.accent).scaleEffect(2)
                } else if let msg = viewModel.errorMessage, viewModel.liveNow.isEmpty, viewModel.upcoming.isEmpty {
                    TVEmptyState(systemImage: "wifi.exclamationmark", title: "Couldn't load games", subtitle: msg)
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: Match.self) { TVMatchDetailView(match: $0) }
        }
        .tint(Theme.accent)
        .task(id: loadKey) {
            await viewModel.load(
                leagues: prefs.followedLeagues,
                favorites: prefs.favoriteTeams,
                notificationsEnabled: false,
                notificationLeadTime: prefs.matchReminderLeadTime,
                morningDigestEnabled: false
            )
            viewModel.startAutoRefresh()
        }
        .onDisappear { viewModel.stopAutoRefresh() }
        .fullScreenCover(item: $selectedChannel) { TVPlayerView(channel: $0) }
    }

    private var loadKey: String {
        [prefs.followedLeagues.map(\.id).sorted().joined(separator: ","),
         prefs.favoriteTeams.map(\.id).sorted().joined(separator: ",")].joined(separator: "|")
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 52) {
                greetingSection
                heroSection
                sportsDaySummaryCard
                liveNowShelf
                startingSoonShelf
                yourTeamsShelf
                upcomingShelf
                continueWatchingShelf
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingText)
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Here's what's happening in sports today")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    // MARK: - Hero

    @ViewBuilder private var heroSection: some View {
        let match = viewModel.primeMatch ?? viewModel.liveNow.first ?? viewModel.favoriteTeamUpcoming.first ?? viewModel.upcoming.first
        if let match {
            GeometryReader { proxy in
                NavigationLink(value: match) {
                    TVHeroCard(match: match, width: proxy.size.width, height: 440)
                }
                .buttonStyle(.card)
            }
            .frame(height: 440)
        }
    }

    // MARK: - Sports Day Summary

    @ViewBuilder private var sportsDaySummaryCard: some View {
        let todayMatches = viewModel.favoriteTeamMatchesToday
        if !todayMatches.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("YOUR SPORTS DAY")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .tracking(0.5)

                ForEach(todayMatches.prefix(4)) { match in
                    NavigationLink(value: match) {
                        TVScheduleRow(match: match)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if !prefs.favoriteTeams.isEmpty, let next = viewModel.favoriteTeamUpcoming.first {
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No followed teams play today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Next: \(next.shortName) · \(next.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    // MARK: - Shelves

    @ViewBuilder private var liveNowShelf: some View {
        if !viewModel.liveNow.isEmpty {
            TVShelfRow(title: "Live Now", systemImage: "dot.radiowaves.left.and.right", tint: Theme.live) {
                ForEach(viewModel.liveNow.prefix(12)) { match in
                    NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                }
            }
        }
    }

    @ViewBuilder private var startingSoonShelf: some View {
        if !viewModel.startingSoon.isEmpty {
            TVShelfRow(title: "Starting Soon", systemImage: "clock.badge.fill", tint: Theme.starting) {
                ForEach(viewModel.startingSoon.prefix(10)) { match in
                    NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                }
            }
        }
    }

    @ViewBuilder private var yourTeamsShelf: some View {
        let matches = viewModel.favoriteTeamMatchesToday.isEmpty
            ? viewModel.favoriteTeamLiveMatches
            : viewModel.favoriteTeamMatchesToday
        if !matches.isEmpty {
            TVShelfRow(title: "Your Teams", systemImage: "star.fill", tint: Theme.accent) {
                ForEach(matches.prefix(8)) { match in
                    NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                }
            }
        }
    }

    @ViewBuilder private var upcomingShelf: some View {
        let matches = viewModel.favoriteTeamUpcoming.isEmpty
            ? Array(viewModel.upcoming.prefix(12))
            : Array(viewModel.favoriteTeamUpcoming.prefix(12))
        if !matches.isEmpty {
            TVShelfRow(title: "Upcoming Games", systemImage: "calendar", tint: Color(hex: 0x3DBE6B)) {
                ForEach(matches) { match in
                    NavigationLink(value: match) { TVMatchCard(match: match) }.buttonStyle(.card)
                }
            }
        }
    }

    @ViewBuilder private var continueWatchingShelf: some View {
        if !watchStore.history.isEmpty {
            TVShelfRow(title: "Continue Watching", systemImage: "play.circle.fill") {
                ForEach(watchStore.history.prefix(8)) { entry in
                    if let channel = entry.saved.channel {
                        Button { selectedChannel = channel } label: {
                            TVChannelCard(channel: channel, isFavorite: watchStore.isFavorite(channel))
                        }
                        .buttonStyle(.card)
                    }
                }
            }
        }
    }
}

// MARK: - TV Schedule Row

private struct TVScheduleRow: View {
    let match: Match

    var body: some View {
        HStack(spacing: 14) {
            stateIndicator

            HStack(spacing: 10) {
                TVTeamLogo(url: match.away.logoURL, size: 32)
                Text(match.away.shortName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if match.state != .pre {
                Text("\(match.away.score ?? "–") – \(match.home.score ?? "–")")
                    .font(.system(size: 18, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(match.state == .live ? Theme.live : Theme.textPrimary)
            } else {
                Text(match.statusDetail)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text(match.home.shortName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                TVTeamLogo(url: match.home.logoURL, size: 32)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(match.state == .live ? Theme.live.opacity(0.4) : Theme.hairline)
        )
    }

    @ViewBuilder private var stateIndicator: some View {
        switch match.state {
        case .live:
            TVLiveBadge()
        case .final:
            Text("FT")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44)
        case .pre:
            Image(systemName: match.league.group.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44)
        }
    }
}
#endif
