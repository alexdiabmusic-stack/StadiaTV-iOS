import SwiftUI

/// Settings tab — a dashboard of destinations, with focused settings pushed from here.
struct MoreView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingTeamEditor = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        quickCards
                        navigationGroups
                    }
                    .padding(20)
                    .frame(maxWidth: Theme.isPad ? 680 : .infinity)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingTeamEditor) {
                TeamEditorView()
            }
        }
        .tint(Theme.accent)
    }

    private var quickCards: some View {
        HStack(spacing: 12) {
            NavigationLink {
                PlaylistsSettingsView()
            } label: {
                QuickManagementCard(
                    title: "Playlists",
                    subtitle: playlistSummary,
                    systemImage: "list.and.film"
                )
            }
            .buttonStyle(.plain)

            Button {
                showingTeamEditor = true
            } label: {
                QuickManagementCard(
                    title: "Teams & Leagues",
                    subtitle: teamsSummary,
                    systemImage: "star.circle.fill"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var navigationGroups: some View {
        VStack(spacing: 18) {
            MoreNavigationGroup(title: "PREFERENCES") {
                NavigationLink { AppearancePlaybackSettingsView() } label: {
                    MoreNavigationRow(title: "Appearance & Playback", value: colorScheme == .dark ? "Dark" : "Light")
                }
                MoreNavigationRow(title: "Streaming Language", value: defaultStreamLanguageName)
                NavigationLink { NotificationsCalendarSettingsView() } label: {
                    MoreNavigationRow(title: "Notifications & Calendar", value: prefs.matchNotificationsEnabled ? "On" : "Off")
                }
            }

            MoreNavigationGroup(title: "DATA & PRIVACY") {
                NavigationLink { SavedArticlesSettingsView() } label: {
                    MoreNavigationRow(title: "Saved Articles", value: articleLibrary.savedArticles.isEmpty ? nil : "\(articleLibrary.savedArticles.count) saved")
                }
                NavigationLink { PrivacySyncSettingsView() } label: {
                    MoreNavigationRow(title: "Privacy & iCloud Sync", value: prefs.cloudSyncEnabled ? "On" : "Off")
                }
                NavigationLink { PrivacyPolicySettingsView() } label: {
                    MoreNavigationRow(title: "Privacy Policy")
                }
                NavigationLink { WatchHistorySettingsView() } label: {
                    MoreNavigationRow(title: "Watch History", value: watchStore.history.isEmpty ? nil : "\(watchStore.history.count) items")
                }
            }

            MoreNavigationGroup(title: "SUPPORT") {
                NavigationLink { HelpFeedbackSettingsView() } label: {
                    MoreNavigationRow(title: "Help & Feedback")
                }
                NavigationLink { AboutStadiaTVSettingsView() } label: {
                    MoreNavigationRow(title: "About StadiaTV")
                }
            }
        }
    }

    private var playlistSummary: String {
        let count = playlists.playlists.count
        return "\(count) connected"
    }

    private var teamsSummary: String {
        let leagueCount = League.all.filter { prefs.isLeagueSelected($0) }.count
        let teamCount = prefs.favoriteTeams.count
        let leagueText = "\(leagueCount) league\(leagueCount == 1 ? "" : "s")"
        let teamText = "\(teamCount) team\(teamCount == 1 ? "" : "s")"
        return "\(leagueText) · \(teamText)"
    }

    private var defaultStreamLanguageName: String {
        let selected = prefs.preferredStreamLanguages.first ?? "en"
        return StreamLanguage.all.first { $0.code == selected }?.name ?? "English"
    }
}


private struct QuickManagementCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct MoreNavigationGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct MoreNavigationRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}
