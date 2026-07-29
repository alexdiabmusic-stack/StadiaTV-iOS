import SwiftUI

struct SettingsView: View {
    var body: some View {
        MoreView()
    }
}

struct PlaylistsSettingsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAddPlaylist = false
    @State private var editingPlaylist: Playlist?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section("CONNECTED") {
                    if playlists.playlists.isEmpty {
                        Button {
                    editingPlaylist = nil
                    showingAddPlaylist = true
                } label: {
                            Label("Add M3U or Xtream Playlist", systemImage: "plus")
                                .foregroundStyle(Theme.accent)
                        }
                    } else {
                        ForEach(playlists.playlists) { playlist in
                            NavigationLink {
                                PlaylistDetailSettingsView(playlist: playlist)
                            } label: {
                                PlaylistConnectionRow(
                                    playlist: playlist,
                                    refresh: { Task { await playlists.refresh(playlist) } },
                                    edit: { edit(playlist) },
                                    makeDefault: { playlists.setDefault(playlist) },
                                    delete: { delete(playlist) }
                                )
                            }
                            .swipeActions {
                                Button(role: .destructive) { delete(playlist) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu { playlistActions(for: playlist) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .hidesScrollContentBackground()
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddPlaylist = true } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddPlaylist, onDismiss: { editingPlaylist = nil }) {
            AddPlaylistView(initialPlaylist: editingPlaylist) { playlist in
                if editingPlaylist == nil {
                    playlists.add(playlist)
                } else {
                    playlists.replace(playlist)
                }
            }
        }
        .refreshable { await playlists.refreshAll() }
    }

    @ViewBuilder private func playlistActions(for playlist: Playlist) -> some View {
        Button { Task { await playlists.refresh(playlist) } } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        Button { edit(playlist) } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button { playlists.setDefault(playlist) } label: {
            Label(playlists.isDefault(playlist) ? "Default Playlist" : "Make Default", systemImage: playlists.isDefault(playlist) ? "checkmark.circle.fill" : "checkmark.circle")
        }
        Button(role: .destructive) { delete(playlist) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func edit(_ playlist: Playlist) {
        editingPlaylist = playlist
        showingAddPlaylist = true
    }

    private func delete(_ playlist: Playlist) {
        guard let index = playlists.playlists.firstIndex(of: playlist) else { return }
        playlists.remove(at: IndexSet(integer: index))
    }
}

struct PlaylistDetailSettingsView: View {
    @EnvironmentObject private var playlists: PlaylistStore
    let playlist: Playlist
    @State private var revealAddress = false
    @State private var showingEditor = false

    private var currentPlaylist: Playlist {
        playlists.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentPlaylist.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.upcoming)
                    }
                    .padding(.vertical, 8)
                }

                Section("DETAILS") {
                    DetailValueRow(title: "Channel count", value: "\(playlists.channelCount(for: currentPlaylist))")
                    DetailValueRow(title: "Last refresh", value: playlists.isLoading(currentPlaylist) ? "Refreshing" : "Recently")
                    DetailValueRow(title: "Preferred playlist", value: playlists.isDefault(currentPlaylist) ? "On" : "Off")
                    if let address = playlistAddress {
                        Button { revealAddress.toggle() } label: {
                            DetailValueRow(title: "Server address", value: revealAddress ? address : "Hidden")
                        }
                    }
                }

                Section("ACTIONS") {
                    Button { Task { await playlists.refresh(currentPlaylist) } } label: {
                        Label("Refresh playlist", systemImage: "arrow.clockwise")
                    }
                    Button { showingEditor = true } label: {
                        Label("Edit credentials", systemImage: "key.fill")
                    }
                    Button { playlists.setDefault(currentPlaylist) } label: {
                        Label(playlists.isDefault(currentPlaylist) ? "Preferred playlist" : "Make preferred playlist", systemImage: playlists.isDefault(currentPlaylist) ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    Button(role: .destructive) { deleteCurrentPlaylist() } label: {
                        Label("Delete playlist", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .hidesScrollContentBackground()
        }
        .navigationTitle(currentPlaylist.name)
        .sheet(isPresented: $showingEditor) {
            AddPlaylistView(initialPlaylist: currentPlaylist) { playlists.replace($0) }
        }
    }

    private var playlistAddress: String? {
        switch currentPlaylist.kind {
        case .m3u: currentPlaylist.m3uURL
        case .xtream: currentPlaylist.host
        }
    }

    private func deleteCurrentPlaylist() {
        guard let index = playlists.playlists.firstIndex(of: currentPlaylist) else { return }
        playlists.remove(at: IndexSet(integer: index))
    }
}

struct AppearancePlaybackSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        SettingsPage(title: "Appearance & Playback") {
            SettingsPanel(title: "APPEARANCE") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Theme")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Picker("Theme", selection: Binding(get: { prefs.appearance }, set: { prefs.setAppearance($0) })) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
            }

            SettingsPanel(title: "PLAYBACK") {
                Menu {
                    ForEach(StreamLanguage.all) { language in
                        Button { prefs.setDefaultStreamLanguage(language) } label: {
                            if prefs.isStreamLanguageSelected(language) {
                                Label(language.name, systemImage: "checkmark")
                            } else {
                                Text(language.name)
                            }
                        }
                    }
                } label: {
                    SettingsDisclosureRow(title: "Streaming Language", value: defaultStreamLanguageName)
                }
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Preferred Player", value: "Built-in")
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Autoplay Next Channel", isOn: .constant(true))
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Picture in Picture", isOn: .constant(true))
            }

            SettingsPanel(title: "SCORES") {
                SettingsToggleRow(title: "Spoiler-Free Mode", isOn: Binding(get: { prefs.spoilerFreeMode }, set: { prefs.setSpoilerFreeMode($0) }))
                Text("When spoiler-free mode is enabled, completed-game scores and result headlines are hidden.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                Divider().overlay(Theme.hairline)
                SettingsToggleRow(title: "Live Score Overlay", isOn: Binding(get: { prefs.showLiveScoreBadge }, set: { prefs.setShowLiveScoreBadge($0) }))
            }
        }
    }

    private var defaultStreamLanguageName: String {
        let selected = prefs.preferredStreamLanguages.first ?? "en"
        return StreamLanguage.all.first { $0.code == selected }?.name ?? "English"
    }
}

struct NotificationsCalendarSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @State private var isExportingCalendar = false
    @State private var calendarExportMessage: String?
    @State private var showPaywall = false

    var body: some View {
        SettingsPage(title: "Notifications & Calendar") {
            SettingsPanel(title: "MASTER CONTROL") {
                HStack {
                    Text("Smart Alerts")
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if entitlements.isPremium {
                        Toggle("Smart Alerts", isOn: Binding(get: { prefs.matchNotificationsEnabled }, set: { _ in toggleNotifications() }))
                            .labelsHidden()
                            .tint(Theme.accent)
                    } else {
                        Button("Premium") { showPaywall = true }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(14)
            }

            SettingsPanel(title: "GAME ALERTS") {
                Group {
                    Menu {
                        ForEach(MatchReminderLeadTime.allCases) { leadTime in
                            Button { updateReminderLeadTime(leadTime) } label: {
                                if prefs.matchReminderLeadTime == leadTime {
                                    Label(leadTime.label, systemImage: "checkmark")
                                } else {
                                    Text(leadTime.label)
                                }
                            }
                        }
                    } label: {
                        SettingsDisclosureRow(title: "Game starting", value: reminderValue)
                    }
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Game begins", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Score changes", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Close game", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Overtime or extra innings", isOn: true)
                    Divider().overlay(Theme.hairline)
                    StaticSwitchRow(title: "Final result", isOn: false)
                }
                .opacity(prefs.matchNotificationsEnabled ? 1 : 0.42)
                .disabled(!prefs.matchNotificationsEnabled)
            }

            SettingsPanel(title: "DAILY") {
                SettingsToggleRow(title: "Morning Briefing", isOn: Binding(get: { prefs.morningDigestEnabled }, set: { prefs.setMorningDigestEnabled($0) }))
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Briefing Time", value: "8:00 AM")
            }
            .opacity(prefs.matchNotificationsEnabled ? 1 : 0.42)

            SettingsPanel(title: "CALENDAR") {
                Button { Task { await exportFollowedGamesToCalendar() } } label: {
                    SettingsDisclosureRow(title: "Calendar Sync", value: calendarValue)
                }
                .disabled(isExportingCalendar)
                if let calendarExportMessage {
                    Text(calendarExportMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var reminderValue: String {
        switch prefs.matchReminderLeadTime {
        case .sixty: "1 hr"
        case .thirty: "30 min"
        case .ten: "10 min"
        case .five: "5 min"
        }
    }

    private var calendarValue: String {
        isExportingCalendar ? "Setting Up" : "Not connected"
    }

    private func toggleNotifications() {
        if prefs.matchNotificationsEnabled {
            prefs.setMatchNotificationsEnabled(false)
            MatchNotificationService.shared.removeAllMatchNotifications()
        } else {
            Task {
                let granted = await MatchNotificationService.shared.requestAuthorization()
                prefs.setMatchNotificationsEnabled(granted)
                if granted { await syncFavoriteGameNotifications() }
            }
        }
    }

    private func updateReminderLeadTime(_ leadTime: MatchReminderLeadTime) {
        prefs.setMatchReminderLeadTime(leadTime)
        guard prefs.matchNotificationsEnabled else { return }
        Task { await syncFavoriteGameNotifications() }
    }

    private func syncFavoriteGameNotifications() async {
        let matches = await loadFollowedMatches()
        await MatchNotificationService.shared.syncNotifications(matches: matches, favorites: prefs.favoriteTeams, leadTime: prefs.matchReminderLeadTime)
    }

    private func exportFollowedGamesToCalendar() async {
        guard !isExportingCalendar else { return }
        isExportingCalendar = true
        defer { isExportingCalendar = false }
        let matches = await loadFollowedMatches()
        do {
            let saved = try await MatchCalendarService.shared.add(matches: matches)
            calendarExportMessage = saved == 1 ? "Added 1 upcoming game to Calendar." : "Added \(saved) upcoming games to Calendar."
        } catch {
            calendarExportMessage = error.localizedDescription
        }
    }

    private func loadFollowedMatches() async -> [Match] {
        let service = ESPNService()
        var matches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in prefs.followedLeagues {
                group.addTask {
                    (try? await service.scoreboards(for: league, starting: Date(), days: 7)) ?? []
                }
            }
            for await loaded in group { matches.append(contentsOf: loaded) }
        }
        return Dictionary(grouping: matches, by: \.id)
            .compactMap { $0.value.first }
            .sorted { $0.date < $1.date }
    }
}

struct SavedArticlesSettingsView: View {
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @State private var presentedArticle: ESPNArticle?

    var body: some View {
        SettingsPage(title: "Saved Articles") {
            if articleLibrary.savedArticles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text("No saved articles")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Use Save Article from a story menu to keep it here.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                VStack(spacing: 0) {
                    ForEach(articleLibrary.savedArticles) { saved in
                        let article = saved.article
                        Button { presentedArticle = article } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(article.league.shortName)
                                        .font(.caption.weight(.heavy))
                                        .foregroundStyle(Theme.accent)
                                    Text(article.headline)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(2)
                                    Text("Saved \(saved.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Saved Article", systemImage: "bookmark.slash", role: .destructive) {
                                articleLibrary.unsave(article)
                            }
                            if let url = article.url {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        if saved.id != articleLibrary.savedArticles.last?.id {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }

            if !articleLibrary.mutedSources.isEmpty {
                SettingsPanel(title: "MUTED SOURCES") {
                    ForEach(Array(articleLibrary.mutedSources).sorted(), id: \.self) { source in
                        HStack {
                            Text(source)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button("Unmute") { articleLibrary.unmuteSource(source) }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(14)
                    }
                }
            }
        }
        .sheet(item: $presentedArticle) { article in
            ArticleReaderView(article: article)
        }
    }
}

struct PrivacySyncSettingsView: View {
    @EnvironmentObject private var prefs: PreferencesStore

    var body: some View {
        SettingsPage(title: "Privacy & Sync") {
            SettingsPanel(title: "ICLOUD") {
                SettingsToggleRow(title: "iCloud Sync", isOn: Binding(get: { prefs.cloudSyncEnabled }, set: { prefs.setCloudSyncEnabled($0) }))
                Text(prefs.cloudSyncEnabled ? "Last synced 3 minutes ago" : "Not syncing")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            SettingsPanel(title: "SYNCED DATA") {
                InfoTextRow("Preferences")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Favourite channels")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Followed teams and leagues")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Watch history")
            }

            SettingsPanel(title: "DEVICE-ONLY DATA") {
                InfoTextRow("Playlist credentials")
                Divider().overlay(Theme.hairline)
                InfoTextRow("Authentication information")
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Theme.accent)
                Text("Playlist credentials remain encrypted in Keychain and are not uploaded to iCloud.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))

            SettingsPanel(title: "DATA CONTROLS") {
                SettingsDisclosureRow(title: "Clear Watch History")
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Reset Recommendations")
                Divider().overlay(Theme.hairline)
                SettingsDisclosureRow(title: "Delete Local Data")
            }

            SettingsPanel(title: "ADVANCED") {
                Button { prefs.resetOnboarding() } label: {
                    SettingsDisclosureRow(title: "Redo Setup")
                }
            }
        }
    }
}

struct PrivacyPolicySettingsView: View {
    var body: some View {
        SettingsPage(title: "Privacy Policy") {
            SettingsPanel(title: "STADIATV PRIVACY POLICY") {
                LegalDocumentText(Self.policyText)
            }
        }
    }

    private static let policyText = """
StadiaTV Privacy Policy

Effective date: July 27, 2026

StadiaTV is operated by Alexandre Diab ("StadiaTV," "we," "us," or "our").

This Privacy Policy explains how information is handled when you use the StadiaTV mobile application ("the App").

1. Overview

StadiaTV is a media player and sports information application. It allows users to view sports information and connect playlists or provider credentials that they are authorized to use.

StadiaTV does not provide, host, sell, or distribute television channels, playlists, subscriptions, broadcasts, or other media content.

We designed StadiaTV to minimize the collection of personal information. The App does not require users to create a StadiaTV account.

2. Information handled by the App

Playlist and provider information

When you connect an M3U playlist, Xtream-compatible account, or another supported source, you may provide information such as:

- Playlist URLs
- Provider server addresses
- Usernames
- Passwords or access credentials
- Channel and playlist information returned by your provider

This information is used only to connect the App to the source you selected.

Your playlist information and provider credentials are stored locally on your device. We do not receive or store this information on StadiaTV-operated servers.

When the App connects to your selected provider, the information required to establish that connection is transmitted directly to that provider. Your provider may receive ordinary network information, including your IP address, device request information, and requested content.

Sports preferences

The App may store information such as:

- Favourite sports
- Selected leagues
- Favourite teams
- Display preferences
- Recently viewed sections
- App settings

These preferences are stored locally on your device and are used to personalize your experience.

Sports and news information

The App obtains scores, schedules, standings, statistics, news, and related information from external data services.

When the App requests this information, the external provider may receive technical information normally included in an internet request, such as an IP address, request time, and basic device or application information.

The App uses the following external services:

- ESPN

The privacy practices of these services are governed by their own privacy policies.

Support communications

When you contact us for support, we may receive:

- Your email address
- Your name, if provided
- The content of your message
- Device or diagnostic information you voluntarily include
- Screenshots or attachments you voluntarily provide

We use this information only to respond to your request, troubleshoot problems, protect the App, and maintain support records.

Do not send playlist passwords, provider credentials, or other sensitive information through support email.

3. How information is used

Information handled through StadiaTV may be used to:

- Connect to playlists and providers selected by the user
- Display content from a connected source
- Personalize sports, league, and team information
- Provide scores, schedules, standings, statistics, and news
- Save app preferences
- Diagnose technical problems
- Respond to support requests
- Maintain the security and functionality of the App
- Comply with applicable legal obligations

We do not use personal information for targeted advertising.

4. Advertising, tracking, and sale of information

StadiaTV does not:

- Display third-party advertisements
- Track users across applications or websites
- Create advertising profiles
- Sell or rent personal information
- Share personal information with data brokers

This section must be updated before introducing advertising, tracking, attribution, or behavioural analytics technology.

5. Sharing of information

We do not share personal information except in the following circumstances:

User-selected providers

Information necessary to connect to an M3U, Xtream-compatible, or other source is sent to the provider selected by the user.

StadiaTV does not control these providers and is not responsible for their privacy or security practices.

Service providers

Information may be processed by services that help provide sports data, news, technical infrastructure, or customer support. These services may only process information for the purposes associated with their services and are expected to protect it appropriately.

Legal requirements

We may disclose information when reasonably necessary to:

- Comply with a law, regulation, court order, or valid legal request
- Protect the rights, safety, and security of users or others
- Investigate fraud, abuse, or security incidents
- Enforce applicable agreements

6. Storage and security

Playlist information, provider credentials, preferences, and settings are designed to remain on the user's device.

We use reasonable administrative and technical measures intended to protect information handled by the App. However, no electronic storage or internet transmission method can be guaranteed to be completely secure.

Users are responsible for protecting their devices and provider credentials. We recommend using a device passcode and avoiding playlists or providers that you do not trust.

7. Retention and deletion

Locally stored preferences remain on your device until you remove them, reset the App, or delete the App.

You may remove connected playlists and provider credentials through the App's playlist-management settings.

Support emails and related communications may be retained only for as long as reasonably necessary to respond to the request, maintain business records, resolve disputes, prevent abuse, and comply with legal obligations.

Because StadiaTV does not require a user account and does not store playlist credentials on its own servers, there is normally no StadiaTV account or associated server profile to delete.

To request access to or deletion of information you previously submitted through customer support, contact us using the email address below.

8. Your choices

You may:

- Choose whether to connect a playlist or provider
- Remove a connected playlist
- Remove saved provider credentials
- Change your favourite sports, leagues, and teams
- Reset locally stored preferences
- Stop using the App and delete it from your device
- Contact us regarding support information you previously submitted

Removing a connected source does not delete information separately held by that source's provider. You must contact the provider directly regarding information it controls.

9. Children's privacy

StadiaTV does not require users to provide their age and is not designed to intentionally collect personal information from children.

We do not knowingly collect personal information from children under 13. A parent or guardian who believes a child has submitted personal information through a support request may contact us to request its deletion.

10. International processing

External playlist providers, sports-data services, news services, email providers, or infrastructure providers may process information in countries other than your own.

Information processed in another country may be subject to that country's laws and lawful access requirements.

11. Third-party content and links

StadiaTV may display information or content obtained from third parties or allow users to connect to third-party services.

We do not control the privacy, security, availability, legality, or content practices of user-selected providers or external services. Users should review the terms and privacy policies of each service they use.

12. Changes to this policy

We may update this Privacy Policy when the App, applicable laws, or our information-handling practices change.

The updated policy will display a revised effective date. Where required, we will provide additional notice within the App or request consent before introducing a materially different use of personal information.

13. Contact us

Questions, privacy requests, or concerns may be sent to:

StadiaTV Privacy
Alexandre Diab
Email: alexdiabmusic@gmail.com
Country: Canada

Please use the subject line "StadiaTV Privacy Request."
"""
}

struct AboutStadiaTVSettingsView: View {
    var body: some View {
        SettingsPage(title: "About StadiaTV") {
            SettingsPanel(title: "ABOUT STADIATV") {
                LegalDocumentText(Self.aboutText)
            }
        }
    }

    private static let aboutText = """
StadiaTV brings sports, scores, schedules, news, and your own authorized playlists together in one fast, modern experience.

Stay connected to the sports you love by following your favourite teams and leagues, tracking live scores, exploring player statistics, and quickly accessing your own linked sources - all from one app.

Features

- Live Scores & Game Tracking
Follow games in real time with live scores, game status, schedules, and matchup information.

- Personalized Sports Feed
Choose the sports, leagues, and teams you care about to create a home screen tailored to you.

- Follow Your Favourite Teams
Receive quick access to upcoming games, live matchups, standings, and team updates.

- Player Profiles & Statistics
Explore player bios, season statistics, rosters, and team information across supported sports.

- Sports News
Stay informed with the latest headlines and updates from the sports you follow.

- Your Authorized Sources
Connect your own compatible playlists or provider credentials to access your authorized content within a single, organized interface.

- Multi-View Support
Watch multiple authorized sources simultaneously with an optimized split-screen experience.*

- Fast, Beautiful Interface
Built for speed with an intuitive design that makes navigating sports effortless.

Sports Supported

Football
Basketball
Baseball
Hockey
Soccer
Racing
Golf
And more

Whether you're checking scores throughout the day, keeping up with your favourite teams, or organizing your own authorized viewing sources, StadiaTV helps keep everything in one place.

Important: StadiaTV does not provide, host, or distribute television channels, sports broadcasts, or media content. Users are responsible for providing their own authorized playlists or provider credentials and must ensure they have the rights to access any content viewed through the app.

*Availability of features depends on connected sources and supported providers.
"""
}

struct HelpFeedbackSettingsView: View {
    var body: some View {
        SettingsPage(title: "Help & Feedback") {
            SettingsPanel(title: "GET HELP") {
                LegalDocumentText("""
If something is not working as expected, send a support message with a short description of the issue, the sport or source involved, and any steps that reproduce the problem.

For playlist or provider issues, include the provider type and the error you see, but do not send playlist passwords, provider credentials, or other sensitive information.

Support email: alexdiabmusic@gmail.com

Suggested subject: StadiaTV Support
""")
            }

            SettingsPanel(title: "FEEDBACK") {
                LegalDocumentText("""
Feature ideas, sports coverage requests, bug reports, and design feedback are welcome. Feedback helps prioritize improvements to scores, schedules, team following, player stats, news, and authorized source playback.
""")
            }
        }
    }
}

private struct LegalDocumentText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.textPrimary)
            .lineSpacing(5)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}

private struct PlaylistConnectionRow: View {
    @EnvironmentObject private var playlists: PlaylistStore
    let playlist: Playlist
    let refresh: () -> Void
    let edit: () -> Void
    let makeDefault: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(playlist.name)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("\(playlists.channelCount(for: playlist)) channels")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text(playlists.isLoading(playlist) ? "Refreshing" : "Connected")
                    .foregroundStyle(playlists.isLoading(playlist) ? Theme.starting : Theme.upcoming)
                Text("·")
                Text("Updated recently")
                Spacer()
                Menu {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                    Button(action: edit) { Label("Edit", systemImage: "pencil") }
                    Button(action: makeDefault) { Label("Make Default", systemImage: "checkmark.circle") }
                    Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(20)
            }
        }
        .navigationTitle(title)
    }
}

private struct SettingsPanel<Content: View>: View {
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

private struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct StaticSwitchRow: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(isOn ? "On" : "Off")
                .font(.subheadline)
                .foregroundStyle(isOn ? Theme.accent : Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct SettingsDisclosureRow: View {
    let title: String
    var value: String? = nil

    var body: some View {
        HStack(spacing: 10) {
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

private struct DetailValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct InfoTextRow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 14)
    }
}
