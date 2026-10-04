import SwiftUI

/// The data pipeline both root views run: playlist channels → guide import → stream linking →
/// event-channel upkeep → fantasy context refresh. It lives in one place so iOS and tvOS can't
/// drift apart (tvOS once skipped the playlists' own XMLTV guides entirely).
struct AppOrchestration: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var bannerFantasyStore: BannerFantasyStore
    // Observed (not just referenced) so the task keys below re-evaluate when they change.
    @ObservedObject var liveViewModel: LiveViewModel
    @ObservedObject var epgRepository: EPGRepository
    @ObservedObject var streamStore: StreamAvailabilityStore
    @ObservedObject var eventChannelRefresh: EventChannelRefreshService

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await playlistStore.refreshAccountStatus() } }
            }
            .task { epgRepository.xtreamEPGFetcher = playlistStore.fetchXtreamEPG }
            .task { await liveViewModel.load(favoriteTeams: prefs.favoriteTeams) }
            // Guide import: whenever the channel list or a playlist's own guide URL changes.
            .task(id: guideSetupKey) {
                epgRepository.setupWithChannels(
                    playlistStore.allChannels,
                    customEPGURLs: playlistStore.playlists.compactMap(\.epgURL).compactMap(URL.init(string:))
                )
            }
            .task(id: streamScanKey) {
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
            .task { await keepEventChannelsCurrent() }
            .onChange(of: playlistStore.channelsRevision) {
                Task { await refreshFantasyContexts(force: true) }
            }
    }

    private var guideSetupKey: String {
        let guideURLs = playlistStore.playlists.compactMap(\.epgURL).joined(separator: ",")
        return "\(playlistStore.channelsRevision)|\(guideURLs)"
    }

    private var streamScanKey: String {
        "\(liveViewModel.allLive.count)-\(liveViewModel.startingSoon.count)-\(playlistStore.channelsRevision)-\(epgRepository.programmeRevision)"
    }

    /// Keeps event-slot channel names (which carry the fixture and change during the day)
    /// current while the app is active — see MatchLinker/PROMPTS.md, Prompt 5.
    private func keepEventChannelsCurrent() async {
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

    private func refreshFantasyContexts(force: Bool) async {
        await bannerFantasyStore.load()
        await PlaybackPriority.waitForBackgroundSlot()
        async let espnRefresh: Void = fantasyStore.refresh(
            channels: playlistStore.allChannels,
            preferredLanguages: prefs.preferredStreamLanguages,
            force: force
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

extension View {
    func appOrchestration(
        liveViewModel: LiveViewModel,
        epgRepository: EPGRepository,
        streamStore: StreamAvailabilityStore,
        eventChannelRefresh: EventChannelRefreshService
    ) -> some View {
        modifier(AppOrchestration(
            liveViewModel: liveViewModel,
            epgRepository: epgRepository,
            streamStore: streamStore,
            eventChannelRefresh: eventChannelRefresh
        ))
    }
}
