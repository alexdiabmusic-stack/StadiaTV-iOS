import SwiftUI

/// Overview tab: goals/cards timeline and key stats now go through the shared Game
/// Detail kit (`SoccerGamePresentation`), matching NHL/Basketball's Overview. Pregame
/// shows lineup/officials status instead of empty stats.
struct SoccerOverviewView: View {
    let snapshot: SoccerGameCentreSnapshot
    let league: League
    var onViewAllEvents: (() -> Void)? = nil
    var onViewAllStats: (() -> Void)? = nil

    private var match: SoccerMatch? { snapshot.match }
    private var isPregame: Bool { match.map { [.scheduled, .pregame].contains($0.status) } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if isPregame || match == nil {
                Text("Match events and statistics will appear after kickoff.")
                    .font(Theme.Typography.callout).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.Spacing.md)
            } else if let match {
                let timeline = SoccerGamePresentation.timeline(events: snapshot.events, match: match, directory: snapshot.playerDirectory)
                GameDetailSection(title: "Match Events", actionTitle: onViewAllEvents == nil ? nil : "Full timeline", action: onViewAllEvents) {
                    EventTimeline(events: timeline, league: league, emptyText: "No goals or cards yet.")
                }

                let keyStats = SoccerGamePresentation.keyStats(home: snapshot.homeStats, away: snapshot.awayStats,
                    awayName: match.away.team.name, homeName: match.home.team.name)
                if !keyStats.isEmpty {
                    GameDetailSection(title: "Team Stats", actionTitle: onViewAllStats == nil ? nil : "View all stats", action: onViewAllStats) {
                        TeamStatsComparison(stats: keyStats, awayAbbreviation: match.away.team.abbreviation, homeAbbreviation: match.home.team.abbreviation)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                lineupsStatus
                matchInfo
                if let shootout = snapshot.penaltyShootout { SoccerPenaltyShootoutView(shootout: shootout, match: match) }
                standingsSection
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
    }

    /// Conference leagues (MLS) show the relevant conference table(s) instead of a
    /// single flat one; single-table leagues (EPL) keep showing `liveStandings`.
    @ViewBuilder private var standingsSection: some View {
        if !snapshot.conferenceStandings.isEmpty {
            ForEach(Array(snapshot.conferenceStandings.enumerated()), id: \.offset) { _, table in SoccerLiveTableView(table: table) }
        } else if let live = snapshot.liveStandings {
            SoccerLiveTableView(table: live)
        }
    }

    @ViewBuilder private var lineupsStatus: some View {
        if snapshot.homeLineup == nil && snapshot.awayLineup == nil {
            Text("Lineups have not been announced yet.").font(.caption).foregroundStyle(Theme.textSecondary)
        } else if let home = snapshot.homeLineup, let away = snapshot.awayLineup {
            HStack {
                Text("\(home.team.shortName) \(home.formation?.raw ?? "")").font(.caption)
                Spacer()
                Text("\(away.team.shortName) \(away.formation?.raw ?? "")").font(.caption)
            }.foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder private var matchInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MATCH INFO").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
            if let matchWeek = match?.matchWeek { infoRow("Matchweek", "\(matchWeek)") }
            if let ground = match?.ground { infoRow("Venue", ground) }
            if let attendance = match?.attendance { infoRow("Attendance", attendance.formatted()) }
            if let kickoff = match?.kickoff { infoRow("Kickoff", kickoff.formatted(date: .abbreviated, time: .shortened)) }
            if let referee = snapshot.officials.first(where: { $0.role.localizedCaseInsensitiveCompare("Referee") == .orderedSame }) { infoRow("Referee", referee.name) }
            if let varOfficial = snapshot.officials.first(where: { $0.role.localizedCaseInsensitiveContains("var") }) { infoRow("VAR", varOfficial.name) }
            if let homeManager = snapshot.homeLineup?.managerName { infoRow("\(match?.home.team.shortName ?? "Home") Manager", homeManager) }
            if let awayManager = snapshot.awayLineup?.managerName { infoRow("\(match?.away.team.shortName ?? "Away") Manager", awayManager) }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(Theme.textSecondary); Spacer(); Text(value) }.font(.caption)
    }
}
