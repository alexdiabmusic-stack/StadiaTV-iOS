import SwiftUI

nonisolated enum ViewingExperience: String, Codable, CaseIterable, Identifiable {
    case sports, liveTV, complete
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self { case .sports: "Sports Mode"; case .liveTV: "Live TV Mode"; case .complete: "Complete Mode" }
    }
    var summary: LocalizedStringResource {
        switch self {
        case .sports: "Scores, teams, games and sports discovery."
        case .liveTV: "Live channels, television guide and entertainment."
        case .complete: "Movies, series, live television and sports, together."
        }
    }
    var icon: String { self == .sports ? "sportscourt" : "tv" }
}

nonisolated enum SportsIntegrationLevel: String, Codable, CaseIterable, Identifiable {
    case hidden, compact, full
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self { case .hidden: "Hidden"; case .compact: "Compact"; case .full: "Full" }
    }
}

struct ViewingExperienceSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @AppStorage("banner.complete.sportsVisibility.v1") private var visibility = "balanced"
    @AppStorage("banner.playback.autoplayEpisodes.v1") private var autoplay = false

    var body: some View {
        Form {
            Section("Complete Mode") {
                Toggle("Autoplay Next Episode", isOn: $autoplay)
                Picker("Sports Visibility", selection: $visibility) {
                    Text("Minimal").tag("minimal")
                    Text("Balanced").tag("balanced")
                    Text("Prominent").tag("prominent")
                }
                NavigationLink("Watchlist & History") { EntertainmentCollectionsView() }
            }
            Section("Viewing Experience") {
                ForEach(ViewingExperience.allCases) { experience in
                    Button {
                        preferences.setViewingExperience(experience)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Image(systemName: experience.icon).foregroundStyle(Theme.accent)
                                Text(experience.title).font(.headline).layoutPriority(1)
                                Spacer(minLength: 0)
                                if preferences.viewingExperience == experience {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                            Text(experience.summary).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preferences.viewingExperience == experience ? [.isSelected] : [])
                }
            }
            Section {
                Picker("Sports Integration", selection: Binding(
                    get: { preferences.sportsIntegration },
                    set: { preferences.setSportsIntegration($0) }
                )) {
                    ForEach(SportsIntegrationLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
            } header: { Text("Live TV preferences") } footer: {
                Text("Choose how much sports information appears in Live TV Mode. Your followed teams, playlists and favourites are preserved.")
            }
        }
        .navigationTitle("Viewing Experience")
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}
