#if os(tvOS)
import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var bannerFantasyStore: BannerFantasyStore
    @StateObject private var liveViewModel = LiveViewModel()
    @StateObject private var epgRepository = EPGRepository()
    @StateObject private var streamStore = StreamAvailabilityStore()

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
        .environmentObject(streamStore)
        .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
        .task { epgRepository.setupWithChannels(playlistStore.allChannels) }
        .task(id: "\(liveViewModel.allLive.count)-\(liveViewModel.startingSoon.count)-\(playlistStore.allChannels.count)") {
            await streamStore.scan(
                matches: liveViewModel.allLive + liveViewModel.startingSoon,
                channels: playlistStore.allChannels,
                preferredLanguages: prefs.preferredStreamLanguages
            )
        }
        .onChange(of: playlistStore.channelsByPlaylist) {
            epgRepository.setupWithChannels(playlistStore.allChannels)
            Task {
                async let espnRefresh: Void = fantasyStore.refresh(
                    channels: playlistStore.allChannels,
                    preferredLanguages: prefs.preferredStreamLanguages,
                    force: true
                )
                async let eventContextRefresh: Void = bannerFantasyStore.refreshEventContexts(
                    channels: playlistStore.allChannels,
                    preferredLanguages: prefs.preferredStreamLanguages
                )
                _ = await (espnRefresh, eventContextRefresh)
            }
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
        .environmentObject(BannerFantasyStore.shared)
        .preferredColorScheme(.dark)
}
#endif
