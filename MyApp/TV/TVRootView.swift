#if os(tvOS)
import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @StateObject private var liveViewModel = LiveViewModel()
    @StateObject private var epgRepository = EPGRepository()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                TVHomeView()
            }

            Tab("Following", systemImage: "star.circle.fill") {
                TVFollowingView()
            }

            Tab("Live", systemImage: "dot.radiowaves.left.and.right") {
                TVLiveSportsView()
            }

            Tab("Live TV", systemImage: "play.tv.fill") {
                TVLiveTVView()
            }

            Tab("Schedule", systemImage: "calendar") {
                TVScheduleView()
            }

            Tab("Stats", systemImage: "chart.bar.xaxis") {
                TVStatsView()
            }

            Tab("News", systemImage: "newspaper.fill") {
                TVNewsView()
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                TVSettingsView()
            }
        }
        .tint(Theme.accent)
        .environmentObject(liveViewModel)
        .environmentObject(epgRepository)
        .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
        .task { epgRepository.setupWithChannels(playlistStore.allChannels) }
        .onChange(of: playlistStore.channelsByPlaylist) {
            epgRepository.setupWithChannels(playlistStore.allChannels)
            Task { await fantasyStore.refresh(channels: playlistStore.allChannels, preferredLanguages: prefs.preferredStreamLanguages, force: true) }
        }
    }
}

#Preview {
    TVRootView()
        .environmentObject(PlaylistStore())
        .environmentObject(PreferencesStore())
        .environmentObject(WatchStore())
        .environmentObject(EntitlementStore())
        .environmentObject(PredictionsStore())
        .environmentObject(FantasyStore.shared)
        .preferredColorScheme(.dark)
}
#endif
