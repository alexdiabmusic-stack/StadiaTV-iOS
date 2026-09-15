import SwiftUI

// MARK: - Root Settings Hub

struct MoreView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @State private var showingTeamEditor = false
    @State private var showingResetConfirmation = false
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        statusCard
                            .padding(.horizontal, 18)
                            .padding(.bottom, 20)

                        quickGrid
                            .padding(.horizontal, 18)
                            .padding(.bottom, 28)

                        sections
                            .padding(.horizontal, 18)

                        versionFooter
                            .padding(.top, 36)
                            .padding(.bottom, 120)
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: Theme.isPad ? 680 : .infinity)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingTeamEditor) { TeamEditorView() }
            .confirmationDialog("Reset Personalization", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button("Redo Setup", role: .destructive) { prefs.resetOnboarding() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll be taken through setup again. Playlists, followed teams, and data are not deleted.")
            }
            .confirmationDialog("Delete Local Data", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete All Local Data", role: .destructive) {
                    watchStore.clearHistory()
                    articleLibrary.clearAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear your watch history, saved articles, hidden articles, and muted sources. This cannot be undone.")
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        NavigationLink {
            BannerSystemStatusView()
        } label: {
            BannerStatusCard(
                playlistCount: playlists.playlists.count,
                teamCount: prefs.favoriteTeams.count,
                leagueCount: followedLeagueCount,
                epgLastUpdated: epgRepository.lastUpdated,
                epgRefreshState: epgRepository.refreshState
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Grid

    private var quickGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            NavigationLink { PlaylistsSettingsView() } label: {
                QuickActionCard(icon: "list.and.film", title: "Playlists", subtitle: playlistSummary)
            }
            .buttonStyle(CardPressStyle())

            Button { showingTeamEditor = true } label: {
                QuickActionCard(icon: "star.circle.fill", title: "Following", subtitle: followingSummary)
            }
            .buttonStyle(CardPressStyle())

            NavigationLink { PlayerPlaybackSettingsView() } label: {
                QuickActionCard(icon: "play.rectangle", title: "Playback", subtitle: playbackSummary)
            }
            .buttonStyle(CardPressStyle())

            NavigationLink { LiveTVGuideSettingsView() } label: {
                QuickActionCard(icon: "tv", title: "Guide", subtitle: guideSummary)
            }
            .buttonStyle(CardPressStyle())
        }
    }

    // MARK: - Sections

    private var sections: some View {
        VStack(spacing: 26) {
            watchingSection
            sportsSection
            personalizationSection
            librarySection
            privacySection
            supportSection
        }
    }

    private var watchingSection: some View {
        SettingsSection(title: "WATCHING") {
            NavigationLink { PlayerPlaybackSettingsView() } label: {
                SettingsNavRow(
                    icon: "play.rectangle",
                    title: "Player & Playback",
                    subtitle: "Stream language · Score overlays"
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { LiveTVGuideSettingsView() } label: {
                SettingsNavRow(
                    icon: "tv",
                    title: "Live TV & Guide",
                    subtitle: guideSubtitle,
                    pill: guidePill
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var sportsSection: some View {
        SettingsSection(title: "SPORTS") {
            Button { showingTeamEditor = true } label: {
                SettingsNavRow(
                    icon: "star.circle.fill",
                    title: "Teams & Leagues",
                    subtitle: followingSummary
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { NotificationsCalendarSettingsView() } label: {
                SettingsNavRow(
                    icon: "bell",
                    title: "Notifications & Calendar",
                    subtitle: "Game alerts · Calendar sync",
                    pill: notificationsPill
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { FantasySettingsView() } label: {
                SettingsNavRow(
                    icon: "trophy",
                    title: "Fantasy",
                    subtitle: fantasySummary,
                    pill: fantasyPill
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var personalizationSection: some View {
        SettingsSection(title: "PERSONALIZATION") {
            NavigationLink { AppearanceSettingsView() } label: {
                SettingsNavRow(
                    icon: "circle.lefthalf.filled",
                    title: "Appearance",
                    pill: SettingsPillContent(prefs.appearance.label, semantic: .blue)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var librarySection: some View {
        SettingsSection(title: "LIBRARY & DATA") {
            NavigationLink { PrivacySyncSettingsView() } label: {
                SettingsNavRow(icon: "icloud", title: "iCloud Sync", pill: icloudPill)
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { SavedArticlesSettingsView() } label: {
                SettingsNavRow(icon: "bookmark", title: "Saved Articles", pill: savedArticlesPill)
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { WatchHistorySettingsView() } label: {
                SettingsNavRow(icon: "clock.arrow.circlepath", title: "Watch History", pill: watchHistoryPill)
            }
            .buttonStyle(.plain)
        }
    }

    private var privacySection: some View {
        SettingsSection(title: "PRIVACY & PERMISSIONS") {
            NavigationLink { PrivacyPolicySettingsView() } label: {
                SettingsNavRow(icon: "lock", title: "Privacy Policy")
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            Button { showingResetConfirmation = true } label: {
                SettingsNavRow(
                    icon: "arrow.counterclockwise",
                    title: "Reset Personalization",
                    subtitle: "Redo setup flow",
                    iconColor: Theme.starting
                )
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            Button { showingDeleteConfirmation = true } label: {
                SettingsNavRow(
                    icon: "trash",
                    title: "Delete Local Data",
                    iconColor: Theme.starting
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var supportSection: some View {
        SettingsSection(title: "SUPPORT") {
            #if DEBUG
            NavigationLink { SportsProviderDiagnosticsView() } label: {
                SettingsNavRow(icon: "waveform", title: "Sports Data Diagnostics")
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.hairline)
            #endif
            NavigationLink { HelpFeedbackSettingsView() } label: {
                SettingsNavRow(icon: "questionmark.circle", title: "Help & Feedback")
            }
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline)

            NavigationLink { AboutBannerTVSettingsView() } label: {
                SettingsNavRow(icon: "info.circle", title: "About Banner TV")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Version Footer

    private var versionFooter: some View {
        Text(versionString)
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }

    // MARK: - Computed Values

    private var followedLeagueCount: Int {
        League.all.filter { prefs.isLeagueSelected($0) }.count
    }

    private var playlistSummary: String {
        let n = playlists.playlists.count
        return n == 0 ? "No playlists" : "\(n) connected"
    }

    private var followingSummary: String {
        let l = followedLeagueCount
        let t = prefs.favoriteTeams.count
        if l == 0 && t == 0 { return "Nothing followed yet" }
        var parts: [String] = []
        if l > 0 { parts.append("\(l) league\(l == 1 ? "" : "s")") }
        if t > 0 { parts.append("\(t) team\(t == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var playbackSummary: String {
        let code = prefs.preferredStreamLanguages.first ?? "en"
        return StreamLanguage.all.first { $0.code == code }?.name ?? "English"
    }

    private var guideSummary: String {
        guard let updated = epgRepository.lastUpdated else { return "Not yet updated" }
        return "Updated " + relativeTime(from: updated)
    }

    private var guideSubtitle: String {
        let m = prefs.guideTimeScaleMinutes
        let h = max(1, m / 60)
        return "\(h)-hour view"
    }

    private var fantasySummary: String {
        guard let conn = fantasyStore.currentConnection else { return "Not connected" }
        return conn.displayName ?? conn.username ?? conn.provider.displayName
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Banner TV \(v) (Build \(b))"
    }

    // MARK: - Pills

    private var guidePill: SettingsPillContent? {
        switch epgRepository.refreshState {
        case .refreshing:
            return SettingsPillContent("UPDATING", semantic: .blue)
        case .failed(_):
            return SettingsPillContent("FAILED", semantic: .red)
        case .idle:
            guard let updated = epgRepository.lastUpdated else { return nil }
            return Date().timeIntervalSince(updated) > 14 * 3600
                ? SettingsPillContent("STALE", semantic: .orange)
                : SettingsPillContent("UPDATED", semantic: .green)
        }
    }

    private var notificationsPill: SettingsPillContent {
        prefs.matchNotificationsEnabled
            ? SettingsPillContent("ON", semantic: .blue)
            : SettingsPillContent("OFF", semantic: .grey)
    }

    private var fantasyPill: SettingsPillContent {
        fantasyStore.currentConnection != nil
            ? SettingsPillContent("CONNECTED", semantic: .green)
            : SettingsPillContent("OFF", semantic: .grey)
    }

    private var icloudPill: SettingsPillContent {
        prefs.cloudSyncEnabled
            ? SettingsPillContent("ON", semantic: .green)
            : SettingsPillContent("OFF", semantic: .grey)
    }

    private var savedArticlesPill: SettingsPillContent? {
        let n = articleLibrary.savedArticles.count
        return n > 0 ? SettingsPillContent("\(n)", semantic: .blue) : nil
    }

    private var watchHistoryPill: SettingsPillContent? {
        let n = watchStore.history.count
        return n > 0 ? SettingsPillContent("\(n)", semantic: .blue) : nil
    }

    // MARK: - Helpers

    private func relativeTime(from date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return h < 24 ? "\(h)h ago" : "\(h / 24)d ago"
    }
}

// MARK: - Banner Status Card

private struct BannerStatusCard: View {
    let playlistCount: Int
    let teamCount: Int
    let leagueCount: Int
    let epgLastUpdated: Date?
    let epgRefreshState: EPGRefreshState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)

            // Atmospheric glows — very subtle, almost invisible on the dark background
            GeometryReader { geo in
                Ellipse()
                    .fill(Theme.accent.opacity(0.11))
                    .frame(width: geo.size.width * 0.55, height: geo.size.height * 1.6)
                    .blur(radius: 38)
                    .offset(x: -geo.size.width * 0.08, y: -geo.size.height * 0.35)

                Ellipse()
                    .fill(Theme.live.opacity(0.07))
                    .frame(width: geo.size.width * 0.44, height: geo.size.height * 1.4)
                    .blur(radius: 32)
                    .offset(x: geo.size.width * 0.68, y: -geo.size.height * 0.3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .allowsHitTesting(false)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("BANNER TV")
                        .font(.caption2.weight(.heavy))
                        .tracking(1.6)
                        .foregroundStyle(Theme.accent)

                    HStack(spacing: 7) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(statusLabel)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    Text(guideLine)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(18)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.hairline)
        )
    }

    private var dotColor: Color {
        switch epgRefreshState {
        case .failed(_): return Theme.live
        case .refreshing: return Theme.starting
        case .idle:
            if playlistCount == 0 { return Theme.textTertiary }
            guard let updated = epgLastUpdated else { return Theme.textTertiary }
            return Date().timeIntervalSince(updated) < 14 * 3600 ? Theme.upcoming : Theme.starting
        }
    }

    private var statusLabel: String {
        switch epgRefreshState {
        case .failed(_): return "Guide update failed"
        case .refreshing: return "Updating guide…"
        case .idle:
            return playlistCount == 0 ? "No playlists connected" : "Everything looks good"
        }
    }

    private var summaryLine: String {
        var parts = ["\(playlistCount) playlist\(playlistCount == 1 ? "" : "s")"]
        if teamCount > 0 { parts.append("\(teamCount) team\(teamCount == 1 ? "" : "s") followed") }
        return parts.joined(separator: " · ")
    }

    private var guideLine: String {
        switch epgRefreshState {
        case .refreshing: return "Guide updating…"
        case .failed(_): return "Guide update failed"
        case .idle:
            guard let date = epgLastUpdated else { return "Guide not yet updated" }
            let s = max(0, Int(Date().timeIntervalSince(date)))
            if s < 60 { return "Guide updated just now" }
            let m = s / 60
            if m < 60 { return "Guide updated \(m)m ago" }
            return "Guide updated \(m / 60)h ago"
        }
    }
}

// MARK: - Quick Action Card

private struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Card Press Style

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Settings Nav Row

struct SettingsNavRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var pill: SettingsPillContent? = nil
    var iconColor: Color = Theme.accent

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBox(systemName: icon, color: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let pill {
                SettingsPill(label: pill.label, semantic: pill.semantic)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .frame(minHeight: subtitle == nil ? 52 : 64)
    }
}

// MARK: - Settings Icon Box

struct SettingsIconBox: View {
    let systemName: String
    var color: Color = Theme.accent

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Settings Pill

struct SettingsPillContent {
    let label: String
    let semantic: SettingsPill.Semantic

    init(_ label: String, semantic: SettingsPill.Semantic) {
        self.label = label
        self.semantic = semantic
    }
}

struct SettingsPill: View {
    enum Semantic { case blue, green, orange, red, grey }

    let label: String
    var semantic: Semantic = .blue

    var tint: Color {
        switch semantic {
        case .blue:   return Theme.accent
        case .green:  return Theme.upcoming
        case .orange: return Theme.starting
        case .red:    return Theme.live
        case .grey:   return Theme.textTertiary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
    }
}
