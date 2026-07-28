import SwiftUI

/// Fetches the full Match for a past Prediction and presents MatchDetailView in a sheet.
struct PickMatchDetailSheet: View {
    let prediction: Prediction

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var prefs: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    @EnvironmentObject private var predictions: PredictionsStore
    @Environment(\.dismiss) private var dismiss

    @State private var match: Match?
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        Group {
            if let match {
                NavigationStack {
                    MatchDetailView(match: match)
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            } else if isLoading {
                loadingView
            } else {
                errorView
            }
        }
        .tint(Theme.accent)
        .task {
            await loadMatch()
        }
    }

    // MARK: Loading / error

    private var loadingView: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(Theme.accent)
                Text("Loading match details…")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var errorView: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.textSecondary)
                Text("Couldn't load match details.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                Button("Dismiss") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    // MARK: Fetch

    private func loadMatch() async {
        guard let league = League.all.first(where: { $0.name == prediction.leagueName }) else {
            isLoading = false
            failed = true
            return
        }

        let service = ESPNService()

        // Fast path: fetch the specific date the match was scheduled
        let fetchDate = prediction.matchDate ?? prediction.placedAt
        if let matches = try? await service.scoreboard(for: league, on: fetchDate),
           let found = matches.first(where: { $0.id == prediction.id }) {
            match = found
            isLoading = false
            return
        }

        // Fallback: scan the last 30 days (catches timezone edge cases and old predictions
        // placed before matchDate was stored)
        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        if let matches = try? await service.scoreboards(for: league, starting: startDate, days: 31),
           let found = matches.first(where: { $0.id == prediction.id }) {
            match = found
            isLoading = false
            return
        }

        isLoading = false
        failed = true
    }
}
