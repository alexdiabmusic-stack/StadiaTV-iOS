import SwiftUI
import UIKit

@main
struct MyApp: App {
    @StateObject private var playlistStore = PlaylistStore()
    @StateObject private var preferences = PreferencesStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if preferences.hasCompletedOnboarding {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(playlistStore)
            .environmentObject(preferences)
            .preferredColorScheme(.dark)
            .task { await playlistStore.refreshAll() }
        }
    }
}

struct RootView: View {
    init() {
        // Dark tab bar to match the StadiaTV palette.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.background)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView {
            MatchesView()
                .tabItem { Label("Matches", systemImage: "sportscourt.fill") }

            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "list.and.film") }
        }
        .tint(Theme.accent)
    }
}

#Preview {
    RootView()
        .environmentObject(PlaylistStore())
        .environmentObject(PreferencesStore())
        .preferredColorScheme(.dark)
}
