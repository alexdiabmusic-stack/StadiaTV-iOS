import SwiftUI

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
                        .font(.system(size: 42))
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
    private let service = ESPNService()

    var body: some View {
        PremiumLoadState(isLoading: isLoading && groups.isEmpty,
                         isEmpty: groups.isEmpty,
                         emptyIcon: "list.number",
                         emptyText: "Standings aren't available for \(league.name) right now.",
                         retry: { Task { await load() } }) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                                    StandingRowView(rank: index + 1, row: row)
                                    if index < group.rows.count - 1 {
                                        Divider().overlay(Theme.hairline)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                        } header: {
                            HStack {
                                Text(group.name.uppercased())
                                Spacer()
                                Text("W-L").font(.caption2)
                            }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, 6)
                            .background(Theme.background)
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .navigationTitle("Standings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.standings(for: league)) ?? []
        isLoading = false
    }
}

private struct StandingRowView: View {
    let rank: Int
    let row: StandingRow

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 20, alignment: .trailing)
            TeamLogo(url: row.logoURL, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let streak = row.streak, !streak.isEmpty {
                    Text("Streak \(streak)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(row.record)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if let pct = row.winPercent {
                    Text(pct)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                } else if let gb = row.gamesBack {
                    Text("GB \(gb)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .navigationBarTitleDisplayMode(.inline)
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
        .navigationBarTitleDisplayMode(.inline)
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
