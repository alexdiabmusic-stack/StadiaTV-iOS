import SwiftUI

// MARK: - Team roster

struct TeamRosterView: View {
    let league: League
    let teamID: String
    let teamName: String

    @State private var groups: [RosterGroup] = []
    @State private var isLoading = true
    private let service = ESPNService()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if isLoading && groups.isEmpty {
                ProgressView().tint(Theme.accent)
            } else if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 42))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Roster isn't available for this team.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.athletes) { athlete in
                                    NavigationLink {
                                        PlayerDetailView(league: league, athlete: athlete)
                                    } label: {
                                        RosterAthleteRow(athlete: athlete)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                if groups.count > 1 {
                                    Text(group.title.uppercased())
                                        .font(.footnote.weight(.bold))
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .background(Theme.background)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(teamName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        groups = (try? await service.roster(for: league, teamID: teamID)) ?? []
        isLoading = false
    }
}

struct RosterAthleteRow: View {
    let athlete: RosterAthlete

    var body: some View {
        HStack(spacing: 12) {
            PlayerHeadshot(url: athlete.headshotURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(athlete.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let jersey = athlete.jersey, !jersey.isEmpty {
                        Text("#\(jersey)")
                    }
                    if let pos = athlete.position, !pos.isEmpty {
                        Text(pos)
                    }
                    if let height = athlete.displayHeight {
                        Text("· \(height)")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if athlete.isInjured {
                Image(systemName: "cross.case.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.live)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Player detail (bio + stats + news)

struct PlayerDetailView: View {
    let league: League
    let athlete: RosterAthlete

    @State private var overview: AthleteOverview?
    @State private var isLoading = true
    @Environment(\.openURL) private var openURL
    private let service = ESPNService()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    bioCard
                    if isLoading && overview == nil {
                        ProgressView().tint(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                    if let overview {
                        if !overview.headlineStats.isEmpty {
                            headlineStats(overview.headlineStats, label: overview.statlineLabel)
                        }
                        if !overview.stats.isEmpty {
                            statTable(overview.stats)
                        }
                        if !overview.news.isEmpty {
                            playerNews(overview.news)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(athlete.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            PlayerHeadshot(url: athlete.headshotURL, size: 76)
            VStack(alignment: .leading, spacing: 4) {
                Text(athlete.displayName)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    if let jersey = athlete.jersey, !jersey.isEmpty {
                        Text("#\(jersey)")
                    }
                    if let pos = athlete.positionName ?? athlete.position {
                        Text(pos)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                if athlete.isInjured {
                    Label("Injured", systemImage: "cross.case.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.live)
                }
            }
            Spacer()
        }
    }

    private var bioCard: some View {
        let items: [(String, String)] = [
            athlete.displayHeight.map { ("Height", $0) },
            athlete.displayWeight.map { ("Weight", $0) },
            athlete.age.map { ("Age", "\($0)") },
            athlete.experienceYears.map { ("Experience", $0 == 0 ? "Rookie" : "\($0) yr") },
            athlete.college.map { ("College", $0) },
            athlete.birthPlace.map { ("Birthplace", $0) }
        ].compactMap { $0 }

        return Group {
            if !items.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(items, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(item.1)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }

    private func headlineStats(_ stats: [StatValue], label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(stats) { stat in
                    VStack(spacing: 2) {
                        Text(stat.value)
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        Text(stat.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func statTable(_ stats: [StatValue]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SEASON STATISTICS")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    HStack {
                        Text(stat.displayName)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(stat.value)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if index < stats.count - 1 {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func playerNews(_ news: [ESPNArticle]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LATEST NEWS")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
            ForEach(news) { article in
                Button {
                    if let url = article.url { openURL(url) }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(article.headline)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                            if let published = article.published {
                                Text(published, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        isLoading = true
        overview = try? await service.athleteOverview(for: league, athleteID: athlete.id)
        isLoading = false
    }
}
