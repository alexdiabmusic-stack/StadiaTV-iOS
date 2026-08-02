import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Shared premium components

/// A circular athlete headshot with a neutral fallback.
struct PlayerHeadshot: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(Theme.textSecondary.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .background(Theme.surfaceElevated)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline))
    }
}

/// A reusable async loading container for premium data screens.
private struct PremiumLoadState<Content: View>: View {
    let isLoading: Bool
    let isEmpty: Bool
    let emptyIcon: String
    let emptyText: String
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(Theme.accent)
            } else if isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: emptyIcon)
                        .font(.system(size: Theme.scaled(42)))
                        .foregroundStyle(Theme.textSecondary)
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .padding(32)
            } else {
                content()
            }
        }
    }
}

// MARK: - Standings

struct StandingsView: View {
    let league: League
    @State private var groups: [StandingsGroup] = []
    @State private var isLoading = true
    @State private var showDivisions = false
    private let service = ESPNService()

    private var hasDivisionData: Bool {
        groups.contains { $0.name.localizedCaseInsensitiveContains("division") }
    }

    private var displayedGroups: [StandingsGroup] {
        guard hasDivisionData else { return groups }
        return groups.filter { group in
            let isDivision = group.name.localizedCaseInsensitiveContains("division")
            return showDivisions ? isDivision : !isDivision
        }
    }

    var body: some View {
        PremiumLoadState(isLoading: isLoading && groups.isEmpty,
                         isEmpty: groups.isEmpty,
                         emptyIcon: "list.number",
                         emptyText: "Standings aren't available for \(league.name) right now.",
                         retry: { Task { await load() } }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if hasDivisionData {
                        HStack(spacing: 8) {
                            ForEach(["Conference", "Division"], id: \.self) { label in
                                let isDivTab = label == "Division"
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) { showDivisions = isDivTab }
                                    #if os(iOS)
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    #endif
                                } label: {
                                    Text(label)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(showDivisions == isDivTab ? .white : Theme.textSecondary)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(showDivisions == isDivTab ? Theme.accent : Theme.surface, in: Capsule())
                                        .overlay(Capsule().strokeBorder(showDivisions == isDivTab ? Color.clear : Theme.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }
                    ForEach(displayedGroups) { group in
                        StandingsGroupCard(group: group, league: league)
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Standings")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.standings(for: league)) ?? []
        isLoading = false
    }
}

enum StandingsCol: Hashable {
    case wins, losses, ties, winPct, gamesBack, streak
    case leaguePoints, gamesPlayed, goalDiff

    var defaultHeader: String {
        switch self {
        case .wins: return "W"
        case .losses: return "L"
        case .ties: return "T"
        case .winPct: return "PCT"
        case .gamesBack: return "GB"
        case .streak: return "SKT"
        case .leaguePoints: return "PTS"
        case .gamesPlayed: return "GP"
        case .goalDiff: return "GD"
        }
    }

    func header(for league: League) -> String {
        if self == .ties {
            switch league.group {
            case .hockey: return "OTL"
            case .soccer: return "D"
            default: return "T"
            }
        }
        return defaultHeader
    }

    var width: CGFloat {
        switch self {
        case .wins, .losses, .gamesPlayed: return 26
        case .ties: return 30
        case .winPct: return 44
        case .gamesBack: return 32
        case .streak: return 32
        case .leaguePoints: return 36   // needs 3 digits, e.g. "112"
        case .goalDiff: return 32
        }
    }

    var isKey: Bool { self == .winPct || self == .leaguePoints }

    func value(from row: StandingRow) -> String {
        switch self {
        case .wins: return row.wins ?? "-"
        case .losses: return row.losses ?? "-"
        case .ties: return row.ties ?? "-"
        case .winPct: return row.winPercent ?? "-"
        case .gamesBack: return row.gamesBack ?? "-"
        case .streak: return row.streak ?? "-"
        case .leaguePoints: return row.leaguePoints ?? "-"
        case .gamesPlayed: return row.gamesPlayed ?? "-"
        case .goalDiff: return row.goalDiff ?? "-"
        }
    }

    func textColor(for row: StandingRow) -> Color {
        if self == .streak {
            let s = row.streak?.lowercased() ?? ""
            if s.hasPrefix("w") { return Color(hex: 0x37C871) }
            if s.hasPrefix("l") { return Theme.live }
        }
        return isKey ? Theme.textPrimary : Theme.textSecondary
    }

    static func columns(for league: League) -> [StandingsCol] {
        switch league.group {
        case .baseball:      return [.wins, .losses, .winPct, .gamesBack, .streak]
        case .football:      return [.wins, .losses, .ties, .winPct, .streak]
        case .basketball:    return [.wins, .losses, .winPct, .gamesBack, .streak]
        case .hockey:        return [.gamesPlayed, .wins, .losses, .ties, .leaguePoints, .streak]
        case .soccer:        return [.gamesPlayed, .wins, .ties, .losses, .goalDiff, .leaguePoints]
        case .golf, .racing, .tennis: return [.wins, .leaguePoints]
        }
    }
}

struct StandingsGroupCard: View {
    let group: StandingsGroup
    let league: League
    var highlightTeamID: String? = nil

    private var columns: [StandingsCol] { StandingsCol.columns(for: league) }

    private var sortedRows: [StandingRow] {
        group.rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name.uppercased())
                        .font(.footnote.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(group.rows.count) teams")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surfaceElevated)

            HStack(spacing: 4) {
                Text("#").frame(width: 24, alignment: .center)
                Text("Team").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns, id: \.self) { col in
                    Text(col.header(for: league))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: col.width, alignment: .trailing)
                }
            }
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface.opacity(0.55))

            ForEach(Array(sortedRows.enumerated()), id: \.element.id) { index, row in
                StandingRowView(rank: index + 1, row: row, columns: columns, league: league, highlightTeamID: highlightTeamID)
                if index < sortedRows.count - 1 {
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StandingRowView: View {
    let rank: Int
    let row: StandingRow
    let columns: [StandingsCol]
    let league: League
    var highlightTeamID: String? = nil

    private var isHighlighted: Bool { highlightTeamID != nil && highlightTeamID == row.teamID }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isHighlighted ? Theme.accent : rankColor)
                .frame(width: 24, alignment: .center)

            TeamLogo(url: row.logoURL, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.subheadline.weight(isHighlighted ? .bold : .semibold))
                    .foregroundStyle(isHighlighted ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)
                if !row.abbreviation.isEmpty {
                    Text(row.abbreviation)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isHighlighted ? Theme.accent.opacity(0.8) : Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(columns, id: \.self) { col in
                Text(col.value(from: row))
                    .font(.caption.weight(col.isKey ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(col.textColor(for: row))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: col.width, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHighlighted ? Theme.accent.opacity(0.08) : Color.clear)
        .overlay(alignment: .leading) {
            if isHighlighted {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3)
            }
        }
    }

    private var rankColor: Color {
        switch rank {
        case 1: return Theme.accent
        case 2, 3: return Theme.textPrimary
        default: return Theme.textSecondary
        }
    }
}

// MARK: - Leaders

struct LeadersView: View {
    let league: League
    @State private var boards: [LeaderBoard] = []
    @State private var isLoading = true
    private let service = ESPNService()

    var body: some View {
        PremiumLoadState(isLoading: isLoading && boards.isEmpty,
                         isEmpty: boards.isEmpty,
                         emptyIcon: "chart.bar.fill",
                         emptyText: "Statistical leaders aren't available for \(league.name).",
                         retry: { Task { await load() } }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(boards) { board in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(board.displayName.uppercased())
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Theme.accent)
                            VStack(spacing: 0) {
                                ForEach(Array(board.rows.enumerated()), id: \.element.id) { index, row in
                                    LeaderRowView(row: row)
                                    if index < board.rows.count - 1 {
                                        Divider().overlay(Theme.hairline)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Stat Leaders")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        boards = (try? await service.leaders(for: league)) ?? []
        isLoading = false
    }
}

private struct LeaderRowView: View {
    let row: LeaderRow

    var body: some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.subheadline.weight(.heavy).monospacedDigit())
                .foregroundStyle(row.rank == 1 ? Theme.accent : Theme.textSecondary)
                .frame(width: 22, alignment: .center)
            PlayerHeadshot(url: row.headshotURL, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let team = row.teamAbbreviation, !team.isEmpty {
                    Text(team)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Text(row.value)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Injuries

struct InjuriesView: View {
    let league: League
    @State private var injuries: [LeagueInjury] = []
    @State private var isLoading = true
    private let service = ESPNService()

    var body: some View {
        PremiumLoadState(isLoading: isLoading && injuries.isEmpty,
                         isEmpty: injuries.isEmpty,
                         emptyIcon: "cross.case.fill",
                         emptyText: "No injury report available for \(league.name).",
                         retry: { Task { await load() } }) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(injuries) { injury in
                        InjuryRowView(injury: injury)
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Injury Report")
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        injuries = (try? await service.injuries(for: league)) ?? []
        isLoading = false
    }
}

private struct InjuryRowView: View {
    let injury: LeagueInjury

    var body: some View {
        HStack(spacing: 12) {
            PlayerHeadshot(url: injury.headshotURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(injury.athleteName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    if let team = injury.teamAbbreviation, !team.isEmpty {
                        Text(team)
                    }
                    if let pos = injury.position, !pos.isEmpty {
                        Text("· \(pos)")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                if let detail = injury.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(injury.status.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(injury.isOut ? Theme.live : Color(hex: 0xE0A83D))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background((injury.isOut ? Theme.live : Color(hex: 0xE0A83D)).opacity(0.15), in: Capsule())
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}
