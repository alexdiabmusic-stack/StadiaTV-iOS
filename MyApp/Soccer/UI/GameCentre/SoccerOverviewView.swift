import SwiftUI

/// Overview tab (Steps 49–51, 71–72): a compact summary, not a duplicate of every
/// Stats-tab metric. Pregame shows lineup/officials status instead of empty stats.
struct SoccerOverviewView: View {
    let snapshot: SoccerGameCentreSnapshot

    private var match: SoccerMatch? { snapshot.match }
    private var isPregame: Bool { match.map { [.scheduled, .pregame].contains($0.status) } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if isPregame {
                Text("Match events and statistics will appear after kickoff.").font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                goalsAndCardsSummary
                keyStats
            }
            lineupsStatus
            matchInfo
            if let shootout = snapshot.penaltyShootout { SoccerPenaltyShootoutView(shootout: shootout, match: match) }
            standingsSection
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

    @ViewBuilder private var goalsAndCardsSummary: some View {
        let goals = snapshot.events.filter { [.goal, .ownGoal, .penaltyGoal].contains($0.type) }
        let cards = snapshot.events.filter { [.yellowCard, .secondYellow, .redCard].contains($0.type) }
        if !goals.isEmpty || !cards.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if !goals.isEmpty { summaryGroup(title: "GOALS", events: goals) }
                if !cards.isEmpty { summaryGroup(title: "CARDS", events: cards) }
            }
        }
    }

    private func summaryGroup(title: String, events: [SoccerMatchEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(Theme.textSecondary)
            ForEach(events) { event in
                HStack {
                    Text("\(event.minute ?? 0)'").frame(width: 32, alignment: .trailing).foregroundStyle(Theme.textSecondary)
                    SoccerPlayerLink(playerID: event.playerID, directory: snapshot.playerDirectory) { name in Text(name) }
                    Spacer()
                    Text(match?.side(for: event.teamID)?.team.abbreviation ?? "").foregroundStyle(Theme.textSecondary)
                }.font(.subheadline)
            }
        }
    }

    @ViewBuilder private var keyStats: some View {
        if let home = snapshot.homeStats, let away = snapshot.awayStats {
            VStack(alignment: .leading, spacing: 10) {
                Text("KEY STATS").font(.caption.bold()).foregroundStyle(Theme.textSecondary)
                statLine("xG", home.expectedGoals, away.expectedGoals, format: { String(format: "%.2f", $0) })
                statLine("Possession", home.possession, away.possession, format: { "\(Int($0.rounded()))%" })
                statLine("Shots", home.shots, away.shots, format: { String(Int($0)) })
                statLine("Shots on Target", home.shotsOnTarget, away.shotsOnTarget, format: { String(Int($0)) })
            }
        }
    }

    private func statLine(_ title: String, _ home: Double?, _ away: Double?, format: (Double) -> String) -> some View {
        Group {
            if let home, let away {
                HStack {
                    Text(format(home)).frame(width: 46, alignment: .leading).monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                    Text(format(away)).frame(width: 46, alignment: .trailing).monospacedDigit()
                }.font(.subheadline)
            }
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
