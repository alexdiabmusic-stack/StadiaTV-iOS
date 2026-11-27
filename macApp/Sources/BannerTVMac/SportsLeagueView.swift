import BannerCore
import SwiftUI

/// One league: its games, its table, and its teams (to follow).
struct SportsLeagueView: View {
    let id: String
    @EnvironmentObject private var sports: SportsModel
    @State private var league: MacLeague?
    @State private var games: [MacSportsGame] = []
    @State private var table: MacStandingsTable?
    @State private var tableLoaded = false
    @State private var teams: [MacTeam] = []
    @State private var teamsLoaded = false
    @State private var tab = "Games"

    private var tabs: [String] {
        var list = ["Games"]
        if league?.hasTable == true { list.append("Table") }
        if league?.hasTeams == true { list.append("Teams") }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(league?.name ?? id).font(.jb(40, .bold))
                        Text(league?.sport ?? "").foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if let league {
                        Button { MacSports.shared.toggleLeague(leagueId: id); reload() } label: { Label(league.followed ? "Following" : "Follow", systemImage: league.followed ? "checkmark" : "plus") }
                            .buttonStyle(PillButtonStyle(kind: league.followed ? .secondary : .primary, height: 44))
                    }
                }
                if tabs.count > 1 {
                    HStack(spacing: 8) { ForEach(tabs, id: \.self) { name in Chip(title: name, selected: tab == name) { tab = name } } }
                }
                switch tab {
                case "Table": tableView
                case "Teams": teamsView
                default:
                    if games.isEmpty { EmptyNote(title: "No games listed", message: sports.status?.loading == true ? "Loading games…" : "This league has no games in the current window.") }
                    GameGrid(games: games)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.top, 84).padding(.bottom, 60)
        }
        .navigationTitle(league?.name ?? "League")
        .onAppear {
            sports.start(); reload()
            if let t = DebugHarness.leagueTab { tab = t }
        }
        .onChange(of: sports.tick) { _, _ in reload() }
        .onChange(of: tab) { _, value in
            if value == "Table", !tableLoaded { loadTable() }
            if value == "Teams", !teamsLoaded { loadTeams() }
        }
    }

    private func reload() {
        league = MacSports.shared.league(id: id)
        games = MacSports.shared.leagueGames(leagueId: id)
    }

    private func loadTable() {
        tableLoaded = true
        MacSports.shared.loadStandings(leagueId: id, force: false) { value in Task { @MainActor in table = value } }
    }

    private func loadTeams() {
        teamsLoaded = true
        MacSports.shared.loadTeams(leagueId: id) { value in Task { @MainActor in teams = value } }
    }

    // MARK: Table

    @ViewBuilder private var tableView: some View {
        if let table {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(table.groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        if table.groups.count > 1 { Text(group.name).font(.jb(17, .semibold)).padding(.bottom, 6) }
                        HStack(spacing: 0) {
                            Text("").frame(width: 34)
                            Text("").frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, label in
                                Text(label).frame(width: 46, alignment: .trailing)
                            }
                        }
                        .font(.jb(12, .semibold)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.vertical, 6)
                        ForEach(group.rows, id: \.teamId) { row in
                            HStack(spacing: 0) {
                                Text("\(row.pos)").frame(width: 34, alignment: .leading).foregroundStyle(Theme.textSecondary)
                                HStack(spacing: 8) {
                                    TeamLogo(url: row.logo, size: 20)
                                    Text(row.name).fontWeight(row.mine ? .bold : .regular).lineLimit(1)
                                    if let zone = row.zoneLabel, let color = row.zoneColor {
                                        Circle().fill(Color(hex: color)).frame(width: 7, height: 7).help(zone)
                                    }
                                }
                                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                                ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                    Text(value).monospacedDigit().frame(width: 46, alignment: .trailing)
                                }
                            }
                            .font(.jb(14)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(row.mine ? Theme.surfaceRaised : Color.clear)
                            Divider().opacity(0.25)
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let season = table.season { Text("Season \(season) · \(table.source)").font(.jb(12)).foregroundStyle(Theme.textSecondary) }
            }
        } else if tableLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }

    // MARK: Teams

    @ViewBuilder private var teamsView: some View {
        if teams.isEmpty {
            if teamsLoaded { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)], spacing: 12) {
                ForEach(teams, id: \.key) { team in
                    HStack(spacing: 10) {
                        TeamLogo(url: team.logo, size: 30)
                        Text(team.fullName.isEmpty ? team.name : team.fullName).lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            MacSports.shared.toggleTeam(leagueId: team.leagueId, teamId: team.id)
                            MacSports.shared.loadTeams(leagueId: id) { value in Task { @MainActor in teams = value } }
                        } label: { Image(systemName: team.followed ? "star.fill" : "star") }
                        .buttonStyle(.plain).foregroundStyle(team.followed ? Theme.accentStart : Theme.textSecondary)
                        .help(team.followed ? "Unfollow" : "Follow")
                    }
                    .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }
}
