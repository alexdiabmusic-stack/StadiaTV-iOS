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
    @StateObject private var eventChannelRefresh = EventChannelRefreshService()

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
        .environmentObject(eventChannelRefresh)
        .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
        .task { epgRepository.xtreamEPGFetcher = playlistStore.fetchXtreamEPG }
        .task { epgRepository.setupWithChannels(playlistStore.allChannels) }
        .task(id: "\(liveViewModel.allLive.count)-\(liveViewModel.startingSoon.count)-\(playlistStore.channelsRevision)-\(epgRepository.programmeRevision)") {
            await streamStore.scanDebounced(
                matches: liveViewModel.allLive + liveViewModel.startingSoon,
                channels: playlistStore.allChannels,
                epgRepository: epgRepository
            )
        }
        .task(id: playlistStore.channelsRevision) {
            for playlist in playlistStore.playlists {
                eventChannelRefresh.noteChannelsLoaded(
                    playlistID: playlist.id, channels: playlistStore.channelsByPlaylist[playlist.id] ?? []
                )
            }
        }
        // Keeps event-slot channel names current while the app is active — see
        // MatchLinker/PROMPTS.md, Prompt 5.
        .task {
            while !Task.isCancelled {
                let upcoming = liveViewModel.allLive + liveViewModel.startingSoon
                let hot = upcoming.contains { match in
                    abs(match.date.timeIntervalSinceNow) <= 30 * 60 && streamStore.confirmedCount(for: match.id) == 0
                }
                if await eventChannelRefresh.refreshIfDue(playlists: playlistStore, hot: hot) {
                    await streamStore.linkService.invalidate()
                    let horizon = Date().addingTimeInterval(12 * 3600)
                    await streamStore.scan(
                        matches: upcoming.filter { $0.date <= horizon },
                        channels: playlistStore.allChannels,
                        epgRepository: epgRepository
                    )
                }
                try? await Task.sleep(nanoseconds: UInt64(hot ? 60 : 600) * 1_000_000_000)
            }
        }
        .onChange(of: playlistStore.channelsRevision) {
            epgRepository.setupWithChannels(playlistStore.allChannels)
            Task {
                async let espnRefresh: Void = fantasyStore.refresh(
                    channels: playlistStore.allChannels,
                    preferredLanguages: prefs.preferredStreamLanguages,
                    force: true
                )
                async let eventContextRefresh: Void = bannerFantasyStore.refreshEventContexts(
                    channels: playlistStore.allChannels,
                    preferredLanguages: prefs.preferredStreamLanguages,
                    epgRepository: epgRepository,
                    streamStore: streamStore
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
