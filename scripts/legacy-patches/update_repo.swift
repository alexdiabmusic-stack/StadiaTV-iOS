import Foundation

func patchFile(_ path: String, search: String, replace: String) {
    let content = try! String(contentsOfFile: path)
    let newContent = content.replacingOccurrences(of: search, with: replace)
    try! newContent.write(toFile: path, atomically: true, encoding: .utf8)
}

patchFile("MyApp/LiveChannelRepository.swift",
    search: "func refreshChannels(for playlist: Playlist) async throws -> [Channel] {\n        if refreshingProviders.contains(playlist.id) {\n            return (await cachedChannels(for: playlist)) ?? []\n        }",
    replace: "func refreshChannels(for playlist: Playlist) async throws -> (channels: [Channel], epgURL: String?) {\n        if refreshingProviders.contains(playlist.id) {\n            return ((await cachedChannels(for: playlist)) ?? [], nil)\n        }")

patchFile("MyApp/LiveChannelRepository.swift",
    search: "let adapterChannels = try await adapter.loadChannels()",
    replace: "let (epgURL, adapterChannels) = try await adapter.loadChannels()")

patchFile("MyApp/LiveChannelRepository.swift",
    search: "return liveChannels.map { $0.asChannel(playlistName: playlist.name) }",
    replace: "return (liveChannels.map { $0.asChannel(playlistName: playlist.name) }, epgURL)")

// Now PlaylistStore.swift
patchFile("MyApp/PlaylistStore.swift",
    search: "let channels = try await repository.refreshChannels(for: playlist)\n            channelsByPlaylist[playlist.id] = channels",
    replace: "let result = try await repository.refreshChannels(for: playlist)\n            channelsByPlaylist[playlist.id] = result.channels\n\n            if let parsedEPGURL = result.epgURL, playlist.epgURL != parsedEPGURL {\n                var updated = playlist\n                updated.epgURL = parsedEPGURL\n                // Replace without triggering another refresh to avoid loop\n                if let index = playlists.firstIndex(where: { $0.id == updated.id }) {\n                    playlists[index] = updated.sanitizedForPersistence\n                    persist()\n                }\n            }")

