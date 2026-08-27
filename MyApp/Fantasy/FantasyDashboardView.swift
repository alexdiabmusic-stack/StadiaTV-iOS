import SwiftUI

struct FantasyDashboardView: View {
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var showingConnect = false
    @State private var showingESPNConnect = false
    @State private var playingChannel: Channel?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Fantasy")
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $playingChannel) { PlayerView(channel: $0) }
        .sheet(isPresented: $showingConnect) {
            SleeperConnectSheet(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
                .environmentObject(fantasyStore)
                .environmentObject(playlists)
                .environmentObject(prefs)
        }
        .sheet(isPresented: $showingESPNConnect) {
            ESPNFantasyHockeyConnectSheet(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
                .environmentObject(fantasyStore)
        }
        .task {
            await fantasyStore.refresh(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
        }
        .refreshable {
            await fantasyStore.refresh(channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages, force: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch fantasyStore.connectionState {
        case .disconnected:
            FantasyDisconnectedState(onConnectSleeper: { showingConnect = true }, onConnectESPN: { showingESPNConnect = true })
        case .connecting:
            FantasyLoadingState(title: "Connecting Fantasy", subtitle: "Resolving your account and leagues.")
        case .providerUnavailable:
            FantasyProviderErrorState(message: fantasyStore.lastError ?? "Fantasy could not load.", onConnectSleeper: { showingConnect = true }, onConnectESPN: { showingESPNConnect = true })
        case .connected, .offlineWithCachedData:
            connectedContent
        }
    }

    private var connectedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if fantasyStore.isStale {
                    FantasyInlineStatus(systemImage: "wifi.slash", title: "Offline data", subtitle: "Showing cached Fantasy information.", tint: Theme.starting)
                }

                leagueSelector

                switch fantasyStore.contentState {
                case .loading:
                    FantasyLoadingState(title: "Loading Fantasy", subtitle: "Refreshing your matchup and roster.")
                case .noLeagues:
                    FantasyInlineState(systemImage: "rectangle.stack.badge.person.crop", title: "No Fantasy leagues", subtitle: "This provider does not have an active league for the selected season.")
                case .preDraft:
                    FantasyInlineState(systemImage: "clock.badge", title: "League has not drafted", subtitle: "Your roster will appear here after the draft finishes.")
                case .seasonComplete:
                    FantasyInlineState(systemImage: "checkmark.seal", title: "Season complete", subtitle: "Final standings are available below.")
                    standingsSection
                case .offSeason:
                    FantasyInlineState(systemImage: "moon.stars", title: "Off-season", subtitle: "This league has no active matchup right now.")
                case .noCurrentMatchup:
                    matchupHero
                    FantasyInlineState(systemImage: "calendar.badge.exclamationmark", title: "No current matchup", subtitle: "This provider did not return an active matchup.")
                    rosterSection
                    standingsSection
                case .providerUnavailable(let message), .partialData(let message):
                    FantasyInlineStatus(systemImage: "exclamationmark.triangle", title: "Partial Fantasy data", subtitle: message, tint: Theme.starting)
                    dashboardSections
                default:
                    dashboardSections
                }

                Spacer(minLength: 80)
            }
            .padding(20)
            .frame(maxWidth: Theme.isPad ? 760 : .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var dashboardSections: some View {
        matchupHero
        if !fantasyStore.liveEventContexts.isEmpty {
            eventContextsSection(title: "MY PLAYERS LIVE", contexts: fantasyStore.liveEventContexts, prominent: true)
        }
        let today = fantasyStore.todayEventContexts.filter { !$0.isLive }
        if !today.isEmpty {
            eventContextsSection(title: "TODAY", contexts: today, prominent: false)
        } else if fantasyStore.contentState == .noFantasyPlayersToday {
            FantasyInlineState(systemImage: "calendar", title: "No players today", subtitle: "Your roster does not have a linked game today.")
        }
        rosterSection
        standingsSection
        unresolvedSection
    }

    private var leagueSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LEAGUE")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            if fantasyStore.leagues.count > 1 {
                Menu {
                    ForEach(fantasyStore.leagues) { league in
                        Button {
                            Task {
                                await fantasyStore.selectLeague(id: league.id, channels: playlists.allChannels, preferredLanguages: prefs.preferredStreamLanguages)
                            }
                        } label: {
                            if fantasyStore.selectedLeague?.id == league.id {
                                Label(league.name, systemImage: "checkmark")
                            } else {
                                Text(league.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trophy.fill")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fantasyStore.selectedLeague?.name ?? "Select League")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                            Text(leagueSubtitle)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            } else {
                FantasyInlineStatus(systemImage: "trophy.fill", title: fantasyStore.selectedLeague?.name ?? "Fantasy", subtitle: leagueSubtitle, tint: Theme.accent)
            }
        }
    }

    private var matchupHero: some View {
        FantasyMatchupHero(matchup: fantasyStore.matchup, roster: fantasyStore.userRoster, league: fantasyStore.selectedLeague)
    }

    private func eventContextsSection(title: String, contexts: [FantasyEventContext], prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: prominent ? "circle.fill" : "calendar")
                Text(title)
                Spacer()
                Text("\(contexts.reduce(0) { $0 + $1.playerGames.count })")
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(prominent ? Theme.live : Theme.textSecondary)

            LazyVStack(spacing: 10) {
                ForEach(contexts) { context in
                    FantasyEventContextCard(context: context) { channel in
                        playingChannel = channel
                    }
                }
            }
        }
    }

    private func playerGamesSection(title: String, games: [FantasyPlayerGame], prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: prominent ? "star.fill" : "calendar")
                Text(title)
                Spacer()
                Text("\(games.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(prominent ? Theme.live : Theme.textSecondary)

            LazyVStack(spacing: 10) {
                ForEach(games) { game in
                    FantasyPlayerGameRow(game: game) { channel in
                        playingChannel = channel
                    }
                }
            }
        }
    }

    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MY TEAM")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            if fantasyStore.players.isEmpty {
                FantasyInlineState(systemImage: "person.3", title: "Roster unavailable", subtitle: "This provider did not return roster players for this league.")
            } else {
                VStack(spacing: 0) {
                    ForEach(rosterRows) { row in
                        FantasyRosterRow(row: row)
                        if row.id != rosterRows.last?.id { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    private var standingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STANDINGS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Theme.textSecondary)
            if fantasyStore.standings.isEmpty {
                FantasyInlineState(systemImage: "list.number", title: "Standings unavailable", subtitle: "This provider did not return enough ranking data.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(fantasyStore.standings.prefix(6).enumerated()), id: \.element.id) { index, standing in
                        FantasyStandingRow(standing: standing, highlighted: standing.rosterID == fantasyStore.userRoster?.rosterID)
                        if index < min(fantasyStore.standings.count, 6) - 1 { Divider().overlay(Theme.hairline) }
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    @ViewBuilder
    private var unresolvedSection: some View {
        let count = fantasyStore.liveContext.unresolvedPlayerIDs.count
        if count > 0 {
            FantasyInlineStatus(systemImage: "person.crop.circle.badge.questionmark", title: "\(count) player\(count == 1 ? "" : "s") not fully linked", subtitle: "They remain in your roster, but Stadia will not guess their games or channels.", tint: Theme.starting)
        }
    }

    private var rosterRows: [FantasyRosterDisplayRow] {
        let slots = fantasyStore.userRoster?.slots ?? []
        let playersByID = Dictionary(uniqueKeysWithValues: fantasyStore.players.map { ($0.id, $0) })
        return slots.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.sortOrder < rhs.kind.sortOrder }
            return (playersByID[lhs.playerID]?.position ?? "") < (playersByID[rhs.playerID]?.position ?? "")
        }.compactMap { slot in
            guard let player = playersByID[slot.playerID] else { return nil }
            return FantasyRosterDisplayRow(id: slot.id, slot: slot, player: player)
        }
    }

    private var leagueSubtitle: String {
        guard let league = fantasyStore.selectedLeague else { return "Not selected" }
        let teams = league.totalRosters.map { "\($0) teams" } ?? "League"
        return "\(league.provider.displayName) · \(league.sport.displayName) · \(league.season) · \(teams) · \(league.status.displayName)"
    }
}

struct SleeperConnectSheet: View {
    var channels: [Channel] = []
    var preferredLanguages: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var fantasyStore: FantasyStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @State private var username = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Sleeper")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Enter your Sleeper username. Stadia stores the stable Sleeper user ID after lookup.")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    TextField("Sleeper username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Theme.textPrimary)
                    if let error = fantasyStore.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.live)
                    }
                    Button {
                        Task {
                            let refreshChannels = channels.isEmpty ? playlists.allChannels : channels
                            let refreshLanguages = preferredLanguages.isEmpty ? prefs.preferredStreamLanguages : preferredLanguages
                            await fantasyStore.connectSleeper(usernameOrUserID: username, channels: refreshChannels, preferredLanguages: refreshLanguages)
                            if fantasyStore.currentConnection != nil { dismiss() }
                        }
                    } label: {
                        Label(connectButtonTitle, systemImage: "link")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fantasyStore.connectionState == .connecting)
                    Spacer()
                }
                .padding(20)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var connectButtonTitle: String {
        fantasyStore.connectionState == .connecting ? "Connecting" : "Connect Sleeper"
    }
}

private struct FantasyDisconnectedState: View {
    let onConnectSleeper: () -> Void
    let onConnectESPN: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "star.bubble.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 7) {
                Text("Connect your fantasy league")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Track your matchup, players and games directly from Stadia.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                if AppConfiguration.isESPNFantasyProviderEnabled {
                    Button(action: onConnectESPN) {
                        Label("Connect ESPN Fantasy", systemImage: "link")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                Button(action: onConnectSleeper) {
                    Label("Connect Sleeper", systemImage: "link")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FantasyLoadingState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }
}

private struct FantasyProviderErrorState: View {
    let message: String
    let onConnectSleeper: () -> Void
    let onConnectESPN: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.starting)
            Text("Fantasy could not load")
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if AppConfiguration.isESPNFantasyProviderEnabled {
                Button("Connect ESPN Fantasy", action: onConnectESPN)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            Button("Connect Sleeper", action: onConnectSleeper)
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FantasyInlineState: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        FantasyInlineStatus(systemImage: systemImage, title: title, subtitle: subtitle, tint: Theme.textSecondary)
    }
}

private struct FantasyInlineStatus: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct FantasyMatchupHero: View {
    let matchup: FantasyMatchup?
    let roster: FantasyRoster?
    let league: FantasyLeague?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(periodTitle)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    if let scoringPeriod = league?.currentScoringPeriodLabel {
                        Text(scoringPeriod)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(league?.name ?? "Fantasy Matchup")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Spacer()
                Text(matchup == nil ? "Pending" : "Matchup")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceElevated, in: Capsule())
            }

            HStack(alignment: .center, spacing: 12) {
                teamBlock(name: matchup?.userTeam.team?.displayName ?? roster?.team?.displayName ?? "My Team", record: roster?.record?.displayRecord, points: pointTotal(matchup?.userTeam.effectivePoints))
                Text("vs")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textTertiary)
                teamBlock(name: matchup?.opponentTeam?.team?.displayName ?? "Opponent", record: nil, points: pointTotal(matchup?.opponentTeam?.effectivePoints))
            }

            if let formatNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(Theme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatNote.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(formatNote.subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var periodTitle: String {
        let label = league?.matchupPeriodLabel ?? "Week"
        guard let period = matchup?.week else { return label.uppercased() }
        return "\(label) \(period)".uppercased()
    }

    private var formatNote: (title: String, subtitle: String)? {
        switch league?.scoringFormat {
        case .headToHeadCategories:
            return ("Category scoring", "Category breakdown appears when the provider supplies reliable category totals.")
        case .rotisserie:
            return ("Rotisserie league", "Season ranking is shown in standings instead of a head-to-head points score.")
        default:
            return nil
        }
    }

    private func pointTotal(_ points: Double?) -> Double? {
        switch league?.scoringFormat {
        case .headToHeadCategories, .rotisserie:
            return nil
        default:
            return points
        }
    }

    private func teamBlock(name: String, record: String?, points: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(points.map(Self.pointsText) ?? "--")
                .font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(points == nil ? Theme.textSecondary : Theme.textPrimary)
            if let record {
                Text(record)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated private static func pointsText(_ points: Double) -> String {
        points.formatted(.number.precision(.fractionLength(1)))
    }
}

private struct FantasyEventContextCard: View {
    let context: FantasyEventContext
    let onWatch: (Channel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.event.shortName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(context.event.statusDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.isLive ? Theme.live : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    Text("\(context.playerGames.count) Fantasy")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.accent)
                    if context.starterCount > 0 {
                        Text("\(context.starterCount) starting")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(context.playerGames.prefix(4)) { game in
                    HStack(spacing: 8) {
                        Text(slotLabel(for: game))
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(game.isFantasyStarter ? Theme.accent : Theme.textSecondary)
                            .frame(width: 48, alignment: .leading)
                        Text(game.fantasyPlayer.fullName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let points = game.fantasyPoints {
                            Text(points.formatted(.number.precision(.fractionLength(1))))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if context.playerGames.count > 4 {
                    Text("+\(context.playerGames.count - 4) more")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let channel = context.matchedChannel?.channel {
                Button { onWatch(channel) } label: {
                    Label(context.isLive ? "Watch" : "Watch at \(context.event.date.formatted(date: .omitted, time: .shortened))", systemImage: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(context.isLive ? Theme.live : Theme.accent)
                .accessibilityLabel("Watch \(context.event.shortName) for \(context.playerGames.count) Fantasy players")
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(context.isLive ? Theme.live.opacity(0.35) : Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private func slotLabel(for game: FantasyPlayerGame) -> String {
        if let position = game.lineupPosition, !position.isEmpty { return position }
        if let slot = game.rosterSlotKind { return slot.shortLabel }
        return game.fantasyPlayer.position ?? "--"
    }

    private var accessibilitySummary: String {
        let status = context.isLive ? "live" : context.isUpcoming ? "upcoming" : "scheduled"
        return "\(context.event.shortName), \(status), \(context.playerGames.count) Fantasy players, \(context.starterCount) starting."
    }
}

private struct FantasyPlayerGameRow: View {
    let game: FantasyPlayerGame
    let onWatch: (Channel) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(game.fantasyPlayer.fullName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Text(game.fantasyPlayer.position ?? "")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if let event = game.event {
                    Text(event.statusDetail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(game.gameState == .live ? Theme.live : Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(game.fantasyPoints.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                    .font(.headline.weight(.black).monospacedDigit())
                    .foregroundStyle(game.fantasyPoints == nil ? Theme.textSecondary : Theme.textPrimary)
                if let channel = game.matchedChannel?.channel {
                    Button { onWatch(channel) } label: {
                        Label("Watch", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(game.gameState == .live ? Theme.live : Theme.accent)
                    .accessibilityLabel("Watch \(game.fantasyPlayer.fullName)'s game")
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(game.gameState == .live ? Theme.live.opacity(0.35) : Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let points = game.fantasyPoints.map { "\($0.formatted(.number.precision(.fractionLength(1)))) fantasy points" } ?? "fantasy points unavailable"
        let watch = game.watchAvailable ? "Watch available" : "No channel available"
        return "\(game.fantasyPlayer.fullName), \(subtitle), \(game.gameState.rawValue), \(points), \(watch)."
    }

    private var subtitle: String {
        let team = game.fantasyPlayer.teamAbbreviation ?? "FA"
        if let opponent = game.opponent?.abbreviation {
            return "\(team) vs \(opponent)"
        }
        if game.event == nil { return "No linked game" }
        return team
    }
}

private struct FantasyRosterDisplayRow: Identifiable {
    let id: String
    let slot: FantasyRosterSlot
    let player: FantasyPlayer
}

private struct FantasyRosterRow: View {
    let row: FantasyRosterDisplayRow

    var body: some View {
        HStack(spacing: 12) {
            Text(row.slot.kind.shortLabel)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(row.slot.kind.tint)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.player.fullName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text([row.player.teamAbbreviation, row.player.position].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let injury = row.player.injuryStatus, !injury.isEmpty {
                Text(injury.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.starting)
            }
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.slot.kind.shortLabel), \(row.player.fullName), \([row.player.teamAbbreviation, row.player.position].compactMap { $0 }.joined(separator: ", "))")
    }
}

private struct FantasyStandingRow: View {
    let standing: FantasyStanding
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(standing.rank.map(String.init) ?? "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(highlighted ? Theme.accent : Theme.textSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(standing.team?.displayName ?? "Roster \(standing.rosterID)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(standing.record.displayRecord)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(standing.record.pointsFor.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(highlighted ? Theme.accent.opacity(0.10) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rank \(standing.rank.map(String.init) ?? "unknown"), \(standing.team?.displayName ?? "Roster \(standing.rosterID)"), record \(standing.record.displayRecord), points for \(standing.record.pointsFor.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "unavailable")")
    }
}

private extension FantasyLeagueStatus {
    var displayName: String {
        switch self {
        case .preDraft: return "Pre-draft"
        case .drafting: return "Drafting"
        case .inSeason: return "In season"
        case .complete: return "Complete"
        case .offSeason: return "Off-season"
        case .unknown: return "Unknown"
        }
    }
}

private extension FantasyRosterSlotKind {
    var sortOrder: Int {
        switch self {
        case .starter: return 0
        case .bench: return 1
        case .reserve: return 2
        }
    }

    var shortLabel: String {
        switch self {
        case .starter: return "START"
        case .bench: return "BENCH"
        case .reserve: return "IR"
        }
    }

    var tint: Color {
        switch self {
        case .starter: return Theme.accent
        case .bench: return Theme.textSecondary
        case .reserve: return Theme.starting
        }
    }
}

#if DEBUG
struct FantasyDashboardStateHarness: View {
    enum StateCase: String, CaseIterable, Identifiable {
        case disconnected = "Disconnected"
        case connected = "Connected"
        case noLeagues = "No Leagues"
        case offline = "Offline"
        case partialMapping = "Partial Mapping"
        case livePlayers = "Live Players"

        var id: String { rawValue }
    }

    @State private var selectedCase: StateCase = .connected

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Fantasy state", selection: $selectedCase) {
                        ForEach(StateCase.allCases) { stateCase in
                            Text(stateCase.rawValue).tag(stateCase)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch selectedCase {
                    case .disconnected:
                        FantasyDisconnectedState(onConnectSleeper: {}, onConnectESPN: {})
                    case .connected:
                        connectedContent(isOffline: false, isPartial: false, isLive: false)
                    case .noLeagues:
                        FantasyInlineState(systemImage: "rectangle.stack.badge.person.crop", title: "No Fantasy leagues", subtitle: "This provider does not have an active league for the selected season.")
                    case .offline:
                        connectedContent(isOffline: true, isPartial: false, isLive: false)
                    case .partialMapping:
                        connectedContent(isOffline: false, isPartial: true, isLive: false)
                    case .livePlayers:
                        connectedContent(isOffline: false, isPartial: false, isLive: true)
                    }
                }
                .padding(20)
            }
        }
    }

    private func connectedContent(isOffline: Bool, isPartial: Bool, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if isOffline {
                FantasyInlineStatus(systemImage: "wifi.slash", title: "Offline data", subtitle: "Showing cached Fantasy information.", tint: Theme.starting)
            }
            FantasyInlineStatus(systemImage: "trophy.fill", title: sampleLeague.name, subtitle: "2026 · 12 teams · In season", tint: Theme.accent)
            FantasyMatchupHero(matchup: sampleMatchup, roster: sampleRoster, league: sampleLeague)
            if isPartial {
                FantasyInlineStatus(systemImage: "person.crop.circle.badge.questionmark", title: "2 players not fully linked", subtitle: "They remain in your roster, but Stadia will not guess their games or channels.", tint: Theme.starting)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(isLive ? "PLAYERS LIVE" : "TODAY")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(isLive ? Theme.live : Theme.textSecondary)
                ForEach(isLive ? sampleLiveGames : sampleTodayGames) { game in
                    FantasyPlayerGameRow(game: game) { _ in }
                }
            }
            VStack(spacing: 0) {
                ForEach(sampleRosterRows) { row in
                    FantasyRosterRow(row: row)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var sampleLeague: FantasyLeague {
        FantasyLeague(id: "league-preview", provider: .sleeper, sport: .nfl, name: "Extremely Long Dynasty League Name Preview", season: "2026", status: .inSeason, totalRosters: 12, avatarID: nil, rosterPositions: ["QB", "RB", "WR", "TE", "FLEX"], scoringSettings: FantasyScoringSettings(values: [:]), providerMetadata: [:])
    }

    private var sampleTeam: FantasyTeam {
        FantasyTeam(id: "team-preview", leagueID: sampleLeague.id, providerUserID: "user-preview", rosterID: 1, displayName: "Stadia Starters", username: "stadia", avatarID: nil, isOwner: true)
    }

    private var sampleOpponent: FantasyTeam {
        FantasyTeam(id: "team-opponent", leagueID: sampleLeague.id, providerUserID: "opponent-preview", rosterID: 2, displayName: "Sunday Lineup", username: "sunday", avatarID: nil, isOwner: false)
    }

    private var sampleRoster: FantasyRoster {
        FantasyRoster(id: "roster-preview", leagueID: sampleLeague.id, rosterID: 1, ownerUserID: "user-preview", team: sampleTeam, slots: [
            FantasyRosterSlot(id: "slot-qb", playerID: "p-qb", kind: .starter, lineupPosition: "QB", fantasyPoints: nil, projectedPoints: nil),
            FantasyRosterSlot(id: "slot-rb", playerID: "p-rb", kind: .starter, lineupPosition: "RB", fantasyPoints: nil, projectedPoints: nil),
            FantasyRosterSlot(id: "slot-wr", playerID: "p-wr", kind: .bench, lineupPosition: "WR", fantasyPoints: nil, projectedPoints: nil)
        ], record: FantasyRecord(wins: 7, losses: 4, ties: 0, pointsFor: 1244.6, pointsAgainst: 1188.2), waiverPosition: nil, waiverBudgetUsed: nil, totalMoves: nil)
    }

    private var sampleMatchup: FantasyMatchup {
        FantasyMatchup(id: "matchup-preview", leagueID: sampleLeague.id, week: 8, matchupID: 3, userTeam: FantasyMatchupTeam(id: "matchup-user", rosterID: 1, team: sampleTeam, starters: ["p-qb", "p-rb"], players: ["p-qb", "p-rb", "p-wr"], points: 84.2, customPoints: nil), opponentTeam: FantasyMatchupTeam(id: "matchup-opponent", rosterID: 2, team: sampleOpponent, starters: [], players: [], points: 79.8, customPoints: nil))
    }

    private var samplePlayers: [FantasyPlayer] {
        [
            FantasyPlayer(id: "p-qb", provider: .sleeper, sport: .nfl, firstName: "Avery", lastName: "Quarterback", fullName: "Avery Quarterback", teamAbbreviation: "BUF", position: "QB", fantasyPositions: ["QB"], status: "Active", injuryStatus: nil, jerseyNumber: "12", externalIDs: FantasyPlayerExternalIDs(espnID: nil, sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil)),
            FantasyPlayer(id: "p-rb", provider: .sleeper, sport: .nfl, firstName: "Morgan", lastName: "Runner", fullName: "Morgan Runner With A Very Long Display Name", teamAbbreviation: "KC", position: "RB", fantasyPositions: ["RB"], status: "Active", injuryStatus: nil, jerseyNumber: "28", externalIDs: FantasyPlayerExternalIDs(espnID: nil, sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil)),
            FantasyPlayer(id: "p-wr", provider: .sleeper, sport: .nfl, firstName: "Jordan", lastName: "Wideout", fullName: "Jordan Wideout", teamAbbreviation: "DAL", position: "WR", fantasyPositions: ["WR"], status: "Questionable", injuryStatus: "Q", jerseyNumber: "88", externalIDs: FantasyPlayerExternalIDs(espnID: nil, sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil))
        ]
    }

    private var sampleRosterRows: [FantasyRosterDisplayRow] {
        zip(sampleRoster.slots, samplePlayers).map { slot, player in
            FantasyRosterDisplayRow(id: slot.id, slot: slot, player: player)
        }
    }

    private var sampleLiveGames: [FantasyPlayerGame] {
        samplePlayers.prefix(2).map { player in
            FantasyPlayerGame(id: "\(player.id)-live", fantasyPlayer: player, stadiaPlayer: nil, event: nil, opponent: nil, gameState: .live, fantasyPoints: player.id == "p-qb" ? 18.4 : nil, projectedPoints: nil, matchedChannel: nil)
        }
    }

    private var sampleTodayGames: [FantasyPlayerGame] {
        samplePlayers.map { player in
            FantasyPlayerGame(id: "\(player.id)-today", fantasyPlayer: player, stadiaPlayer: nil, event: nil, opponent: nil, gameState: .upcoming, fantasyPoints: nil, projectedPoints: nil, matchedChannel: nil)
        }
    }
}

#Preview("Fantasy State Harness") {
    FantasyDashboardStateHarness()
        .preferredColorScheme(.dark)
}
#endif
