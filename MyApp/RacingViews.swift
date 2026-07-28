import SwiftUI

/// Game-center style section for racing leagues: every entrant in the current
/// event, synced from ESPN and grouped by constructor/team.
struct RacersSection: View {
    let league: League
    @State private var racers: [Racer] = []
    @State private var isLoading = true

    private var teams: [(name: String, racers: [Racer])] {
        Dictionary(grouping: racers, by: \.teamName)
            .map { (name: $0.key, racers: $0.value.sorted { ($0.place ?? .max) < ($1.place ?? .max) }) }
            .sorted { ($0.racers.first?.place ?? .max) < ($1.racers.first?.place ?? .max) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                Text("Racers")
                Spacer()
                Text(league.shortName)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
            }
            .font(.headline.weight(.bold))
            .foregroundStyle(Theme.accent)

            if isLoading && racers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("Loading racers")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if racers.isEmpty {
                Text("Racer data isn't available for this event right now.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ForEach(teams, id: \.name) { team in
                    teamCard(team.name, racers: team.racers)
                }
            }
        }
        .task { await load() }
    }

    private func teamCard(_ name: String, racers: [Racer]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceElevated)

            ForEach(Array(racers.enumerated()), id: \.element.id) { index, racer in
                RacerRow(racer: racer)
                if index < racers.count - 1 {
                    Divider().overlay(Theme.hairline)
                }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func load() async {
        isLoading = true
        racers = (try? await ESPNService().racers(for: league)) ?? []
        isLoading = false
    }
}

private struct RacerRow: View {
    let racer: Racer

    var body: some View {
        HStack(spacing: 10) {
            Text(racer.place.map(String.init) ?? "-")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(racer.isWinner ? Theme.accent : Theme.textSecondary)
                .frame(width: 22, alignment: .trailing)

            AsyncImage(url: racer.flagURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
            .frame(width: 24, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(racer.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer()

            if racer.isWinner {
                Image(systemName: "trophy.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
