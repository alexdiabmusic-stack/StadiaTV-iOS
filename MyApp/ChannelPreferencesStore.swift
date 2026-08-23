import Foundation
import SwiftUI
import Combine

/// Persists per-channel user preferences: rename, hide, EPG override, EPG offset.
/// These are user-owned overlays stored separately from provider data.
/// Provider refreshes never touch this store, so user customisations survive.
@MainActor
final class ChannelPreferencesStore: ObservableObject {

    @Published private(set) var preferences: [String: ChannelPreferences] = [:]

    private let defaultsKey = "stadiatv.channelprefs.v1"

    init() { load() }

    // MARK: - Read

    func preferences(for channelID: String) -> ChannelPreferences {
        preferences[channelID] ?? ChannelPreferences(channelID: channelID)
    }

    func isHidden(_ channelID: String) -> Bool {
        preferences[channelID]?.isHidden == true
    }

    func customName(for channelID: String) -> String? {
        preferences[channelID]?.customName
    }

    func epgOffset(for channelID: String) -> Int {
        preferences[channelID]?.epgOffset ?? 0
    }

    func manualEPGChannelID(for channelID: String) -> String? {
        preferences[channelID]?.manualEPGChannelID
    }

    func isFavorite(_ channelID: String) -> Bool {
        preferences[channelID]?.isFavorite == true
    }

    /// Ordered list of favorite channel IDs (ascending favoriteOrder).
    var favoriteChannelIDs: [String] {
        preferences.values
            .filter { $0.isFavorite }
            .sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }
            .map { $0.channelID }
    }

    var favoriteCount: Int {
        preferences.values.filter { $0.isFavorite }.count
    }

    // MARK: - Write

    func setHidden(_ hidden: Bool, for channelID: String) {
        var p = preferences(for: channelID)
        p.isHidden = hidden
        save(p)
    }

    func setCustomName(_ name: String?, for channelID: String) {
        var p = preferences(for: channelID)
        p.customName = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty()
        save(p)
    }

    func setEPGOffset(_ offset: Int, for channelID: String) {
        var p = preferences(for: channelID)
        p.epgOffset = offset
        save(p)
    }

    func setManualEPGChannelID(_ id: String?, for channelID: String) {
        var p = preferences(for: channelID)
        p.manualEPGChannelID = id?.nilIfEmpty()
        save(p)
    }

    func setFavorite(_ fav: Bool, for channelID: String) {
        var p = preferences(for: channelID)
        p.isFavorite = fav
        if fav && p.favoriteOrder == nil {
            p.favoriteOrder = (preferences.values.compactMap { $0.favoriteOrder }.max() ?? -1) + 1
        } else if !fav {
            p.favoriteOrder = nil
        }
        save(p)
    }

    func toggleFavorite(channelID: String) {
        setFavorite(!isFavorite(channelID), for: channelID)
    }

    /// One-time migration from the legacy WatchStore favorites list.
    /// No-op if ChannelPreferencesStore already contains at least one favourite.
    func migrateLegacyFavorites(_ savedChannels: [SavedChannel]) {
        guard !preferences.values.contains(where: { $0.isFavorite }) else { return }
        for (index, saved) in savedChannels.enumerated() {
            var p = preferences(for: saved.id)
            p.isFavorite    = true
            p.favoriteOrder = index
            preferences[p.channelID] = p
        }
        persist()
    }

    // MARK: - Persistence

    private func save(_ prefs: ChannelPreferences) {
        preferences[prefs.channelID] = prefs
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ChannelPreferences].self, from: data)
        else { return }
        preferences = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
