#if DEBUG
import SwiftUI

struct SportsProviderDiagnosticsView: View {
    @State private var selectedLeague = League.all.first { $0.path == "hockey/nhl" } ?? League.all[0]
    @State private var selectedCapability: SportsDataCapability = .liveScores
    @State private var diagnostics: [SportsProviderDiagnostics] = []
    @State private var metadata: [SportsDataProviderMetadata] = []
    @State private var health: [SportsDataProviderID: SportsProviderHealthSnapshot] = [:]
    @State private var overrides: [String: SportsProviderRouteOverride] = [:]

    private let repository = SportsRepository.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                routeInspector
                providerHealth
                recentDiagnostics
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Sports Providers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Clear Cache") {
                    Task {
                        await repository.clearCache()
                        await reload()
                    }
                }
                Button("Reset Routes") {
                    Task {
                        await repository.clearRouteOverrides()
                        await reload()
                    }
                }
            }
        }
        .task { await reload() }
    }

    private var routeInspector: some View {
        diagnosticsSection(title: "Route") {
            Picker("League", selection: $selectedLeague) {
                ForEach(League.all) { league in
                    Text(league.shortName).tag(league)
                }
            }
            Picker("Capability", selection: $selectedCapability) {
                ForEach(SportsDataCapability.allCases, id: \.self) { capability in
                    Text(capability.displayName).tag(capability)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(repository.routeProviderIDs(for: selectedLeague, capability: selectedCapability), id: \.self) { providerID in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(providerID.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(routeDetail(for: providerID))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: binding(for: providerID))
                            .labelsHidden()
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var providerHealth: some View {
        diagnosticsSection(title: "Providers") {
            ForEach(metadata) { provider in
                let snapshot = health[provider.id] ?? .healthySnapshot
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(provider.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(snapshot.state.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(snapshot.state == .healthy ? .green : Theme.textSecondary)
                    }
                    Text("\(provider.supportLevel.rawValue) · \(provider.authenticationType.rawValue) · \(provider.capabilities.count) capabilities")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if let latency = snapshot.averageLatency {
                        Text("Average latency: \(Self.milliseconds(latency)) ms")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let error = snapshot.lastErrorDescription {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var recentDiagnostics: some View {
        diagnosticsSection(title: "Recent Requests") {
            if diagnostics.isEmpty {
                Text("No provider requests recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("\(item.league.shortName) · \(item.capability.displayName)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(item.cacheHit ? "Cache Hit" : "Network")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.cacheHit ? .green : Theme.textSecondary)
                        }
                        Text("Primary: \(item.primaryProvider?.displayName ?? "None") · Current: \(item.currentProvider?.displayName ?? "None")")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text("Latency: \(item.latency.map { "\(Self.milliseconds($0)) ms" } ?? "n/a") · Age: \(item.cacheAge.map { "\(Int($0))s" } ?? "n/a")")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                        if !item.fallbacksAttempted.isEmpty {
                            Text("Fallbacks: \(item.fallbacksAttempted.map(\.displayName).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if !item.failureDescriptions.isEmpty {
                            Text(item.failureDescriptions.joined(separator: "\n"))
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func diagnosticsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func binding(for providerID: SportsDataProviderID) -> Binding<Bool> {
        Binding(
            get: { overrides[overrideKey(providerID)]?.isEnabled ?? true },
            set: { enabled in
                Task {
                    await repository.setProvider(providerID, enabled: enabled, league: selectedLeague, capability: selectedCapability)
                    await reload()
                }
            }
        )
    }

    private func routeDetail(for providerID: SportsDataProviderID) -> String {
        let provider = metadata.first { $0.id == providerID }
        let state = health[providerID]?.state.rawValue.capitalized ?? "Healthy"
        let override = overrides[overrideKey(providerID)].map { $0.isEnabled ? "forced on" : "forced off" } ?? "default"
        return [provider?.supportLevel.rawValue, state, override].compactMap { $0 }.joined(separator: " · ")
    }

    private func overrideKey(_ providerID: SportsDataProviderID) -> String {
        "\(selectedLeague.stadiaKey)|\(selectedCapability.rawValue)|\(providerID.rawValue)"
    }

    @MainActor
    private func reload() async {
        metadata = repository.providerMetadata()
        diagnostics = await SportsDiagnosticsStore.shared.all().sorted { $0.league.shortName < $1.league.shortName }
        overrides = Dictionary(uniqueKeysWithValues: await repository.routeOverrides().map { ($0.id, $0) })
        var snapshots: [SportsDataProviderID: SportsProviderHealthSnapshot] = [:]
        for provider in metadata {
            snapshots[provider.id] = await repository.providerHealthSnapshot(for: provider.id)
        }
        health = snapshots
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        Int((interval * 1000).rounded())
    }
}

private extension SportsDataCapability {
    var displayName: String {
        rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }
}

private extension SportsDataProviderID {
    var displayName: String {
        switch self {
        case .nhl: return "NHL"
        case .mlb: return "MLB"
        case .nba: return "NBA"
        case .nfl: return "NFL"
        case .cbsSports: return "CBS"
        case .yahooSports: return "Yahoo"
        case .foxSports: return "FOX"
        case .appleSports: return "Apple Sports"
        case .espn: return "ESPN"
        }
    }
}
#endif
