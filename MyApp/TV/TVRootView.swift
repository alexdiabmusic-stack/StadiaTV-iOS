#if os(tvOS)
import SwiftUI

struct TVRootView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var showingFavoriteNotificationPrompt = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                TVHomeView()
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
    }
}

#Preview {
    TVRootView()
        .environmentObject(PlaylistStore())
        .environmentObject(PreferencesStore())
        .environmentObject(WatchStore())
        .environmentObject(EntitlementStore())
        .environmentObject(PredictionsStore())
        .preferredColorScheme(.dark)
}
#endif
