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
                heroSection
                liveNowShelf
                yourTeamsShelf
                upcomingShelf
                continueWatchingShelf
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
        }
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
#endif
