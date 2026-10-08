#if os(tvOS)
import SwiftUI

struct TVRootView: View {
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
        .appOrchestration(
            liveViewModel: liveViewModel,
            epgRepository: epgRepository,
            streamStore: streamStore,
            eventChannelRefresh: eventChannelRefresh
        )
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
