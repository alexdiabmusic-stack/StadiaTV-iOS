import SwiftUI

/// Phone-only management of the same library and preferences used by CarPlay.
struct PodcastListeningView: View {
    @EnvironmentObject private var store: PodcastStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PodcastListeningPreferences(store: store)
                CarPlayRolloutPreferences()
                Section("Up Next") {
                    if store.listeningLibrary.upcoming.isEmpty { Text("Your queue is empty") }
                    ForEach(store.listeningLibrary.upcoming) { episode in
                        Button { store.play(episode) } label: {
                            VStack(alignment: .leading) {
                                Text(episode.title)
                                Text(episode.podcastTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                store.listeningLibrary.removeFromQueue(id: episode.id)
                            }
                        }
                    }
                }
                Section("Downloads") {
                    if store.downloads.downloads.isEmpty { Text("Download episodes from their menu to listen offline.") }
                    ForEach(store.downloads.downloads) { download in
                        Button { store.play(download.episode) } label: {
                            VStack(alignment: .leading) {
                                Text(download.episode.title)
                                Text(download.byteCount, format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.downloads.remove(download.episode) }
                                .disabled(store.nowPlaying?.id == download.id && store.isPlaying)
                        }
                    }
                }
                Section("Recently Played") {
                    ForEach(store.listeningLibrary.history) { episode in
                        Button { store.play(episode) } label: {
                            VStack(alignment: .leading) {
                                Text(episode.title)
                                ProgressView(value: store.progressFraction(for: episode))
                            }
                        }
                    }
                }
                if let error = store.playbackError {
                    Section { Text(error).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Listening")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct PodcastListeningPreferences: View {
    @ObservedObject var store: PodcastStore

    var body: some View {
        Section("Playback") {
            Picker("Playback Speed", selection: Binding(get: { store.speed }, set: { store.setSpeed($0) })) {
                ForEach(PodcastSpeed.allCases) { speed in Text(speed.label).tag(speed) }
            }
            Toggle("Automatically play the next episode", isOn: Binding(
                get: { store.listeningLibrary.automaticallyAdvance },
                set: { store.listeningLibrary.automaticallyAdvance = $0 }))
            Toggle("Download over cellular", isOn: Binding(
                get: { store.downloads.allowsCellular }, set: { store.downloads.allowsCellular = $0 }))
            Picker("Download Storage", selection: Binding(
                get: { store.downloads.storageLimitMB }, set: { store.downloads.storageLimitMB = $0 })) {
                Text("512 MB").tag(512)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
                Text("5 GB").tag(5120)
            }
        }
    }
}
