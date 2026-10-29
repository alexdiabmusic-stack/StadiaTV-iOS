import SwiftUI

// MARK: - Root Settings Hub

struct MoreView: View {
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var articleLibrary: ArticleLibraryStore
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var epgRepository: EPGRepository
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                            .padding(.horizontal, Theme.Spacing.screen)
                            .padding(.bottom, 20)

                        quickGrid
                            .padding(.horizontal, Theme.Spacing.screen)
                            .padding(.bottom, 28)

                        sections
                            .padding(.horizontal, Theme.Spacing.screen)

                        versionFooter
                            .padding(.top, 36)
                            .padding(.bottom, Theme.Spacing.section)
                    }
                    .padding(.top, 4)
                    .bannerReadableWidth(680)
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
            columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
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
            NavigationLink { ViewingExperienceSettingsView() } label: {
                SettingsNavRow(icon: "tv", title: "Viewing Experience", subtitle: String(localized: prefs.viewingExperience.title))
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.hairline)
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
            .padding(.horizontal, Theme.Spacing.screen)
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
        HStack(spacing: 12) {
            Image(systemName: dotColor == Theme.upcoming ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(dotColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(statusLabel)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(summaryLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text(guideLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.hairline))
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
            return playlistCount == 0 ? "No playlists connected" : "Ready to watch"
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
                .font(.title3.weight(.semibold))
                .accessibilityHidden(true)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Card Press Style

private struct CardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
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
                .accessibilityAddTraits(.isHeader)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                content
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }
}

// MARK: - Settings Nav Row

struct SettingsNavRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    var subtitle: String? = nil
    var pill: SettingsPillContent? = nil
    var iconColor: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBox(systemName: icon, color: iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if dynamicTypeSize.isAccessibilitySize, let pill {
                    SettingsPill(label: pill.label, semantic: pill.semantic)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            if !dynamicTypeSize.isAccessibilitySize, let pill {
                SettingsPill(label: pill.label, semantic: pill.semantic)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
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
            .accessibilityHidden(true)
            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
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
