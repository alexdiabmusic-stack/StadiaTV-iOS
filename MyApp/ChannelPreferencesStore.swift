import Foundation
import SwiftUI
import Combine

/// Persists per-channel user preferences: rename, hide, EPG override, EPG offset.
/// These are user-owned overlays stored separately from provider data.
/// Provider refreshes never touch this store, so user customisations survive.
@MainActor
final class ChannelPreferencesStore: ObservableObject {

    @Published private(set) var preferences: [String: ChannelPreferences] = [:] {
        didSet { rebuildDerived() }
    }
    /// Ordered favourite channel IDs (ascending favoriteOrder), cached on write.
    private(set) var favoriteChannelIDs: [String] = []
    private(set) var hiddenChannelIDs: Set<String> = []
    private(set) var customNames: [String: String] = [:]
    /// Bumped on every preference change; a cheap key for list models and `.task(id:)`.
    private(set) var revision = 0

    private let defaultsKey = "bannertv.channelprefs.v1"
    /// Where older builds kept their own favourites list (`WatchStore`); see `absorbLegacyFavorites`.
    private static let legacyFavoritesDefaultsKey = "bannertv.favoritechannels.v1"
    /// Last favourites list written to or read from iCloud, to avoid redundant writes.
    private var lastCloudFavoriteIDs: [String]?

    init() {
        load()
        absorbLegacyFavorites()
        NotificationCenter.default.addObserver(
            forName: .bannertvCloudSyncDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.applyCloudFavorites() }
        }
    }

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

    var favoriteCount: Int {
        favoriteChannelIDs.count
    }

    private func rebuildDerived() {
        favoriteChannelIDs = preferences.values
            .filter { $0.isFavorite }
            .sorted { ($0.favoriteOrder ?? Int.max) < ($1.favoriteOrder ?? Int.max) }
            .map { $0.channelID }
        hiddenChannelIDs = Set(preferences.values.lazy.filter(\.isHidden).map(\.channelID))
        customNames = preferences.values.reduce(into: [:]) { names, p in
            if let name = p.customName { names[p.channelID] = name }
        }
        revision &+= 1
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

    /// Adds each channel ID as a favourite after the existing ones, in the order given.
    /// IDs that are already favourites keep their position.
    private func appendFavorites(_ channelIDs: [String]) {
        var nextOrder = (preferences.values.compactMap(\.favoriteOrder).max() ?? -1) + 1
        var updated = preferences
        var changed = false
        for id in channelIDs {
            var p = updated[id] ?? ChannelPreferences(channelID: id)
            guard !p.isFavorite else { continue }
            p.isFavorite = true
            p.favoriteOrder = nextOrder
            nextOrder += 1
            updated[id] = p
            changed = true
        }
        // ChannelPreferences compares by channelID only, so detect changes explicitly.
        if changed { preferences = updated }
    }

    /// Makes the favourites exactly `channelIDs`, in that order. Used when iCloud wins.
    private func replaceFavorites(with channelIDs: [String]) {
        let wanted = Set(channelIDs)
        var updated = preferences
        var changed = false
        let dropped = updated.filter { $0.value.isFavorite && !wanted.contains($0.key) }.map(\.key)
        for id in dropped {
            updated[id]?.isFavorite = false
            updated[id]?.favoriteOrder = nil
            changed = true
        }
        for (index, id) in channelIDs.enumerated() {
            var p = updated[id] ?? ChannelPreferences(channelID: id)
            if p.isFavorite && p.favoriteOrder == index { continue }
            p.isFavorite = true
            p.favoriteOrder = index
            updated[id] = p
            changed = true
        }
        guard changed else { return }
        preferences = updated
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Legacy favourites

    /// Folds in favourites saved by older builds — `WatchStore` kept its own list of channel
    /// snapshots — then deletes those copies. The snapshots embedded each stream's URL, which
    /// carries Xtream credentials, and this store is now the only home for favourites.
    private func absorbLegacyFavorites() {
        let defaults = UserDefaults.standard
        var legacyIDs: [String] = []
        if let data = defaults.data(forKey: Self.legacyFavoritesDefaultsKey),
           let saved = try? JSONDecoder().decode([SavedChannel].self, from: data) {
            legacyIDs += saved.map(\.id)
        }
        if let cloud: [SavedChannel] = CloudSyncService.shared.load([SavedChannel].self, for: .favoriteChannels) {
            legacyIDs += cloud.map(\.id)
        }
        if !legacyIDs.isEmpty {
            appendFavorites(legacyIDs)
            persist()
        }
        defaults.removeObject(forKey: Self.legacyFavoritesDefaultsKey)
        CloudSyncService.shared.removeValue(for: .favoriteChannels)
    }

    // MARK: - iCloud sync (favourite IDs only)

    private func applyCloudFavorites() {
        guard CloudSyncService.shared.isEnabled else { return }
        if let cloudIDs = CloudSyncService.shared.load([String].self, for: .favoriteChannelIDs) {
            lastCloudFavoriteIDs = cloudIDs
            if cloudIDs != favoriteChannelIDs { replaceFavorites(with: cloudIDs) }
        } else if !favoriteChannelIDs.isEmpty {
            pushFavoritesToCloudIfChanged()
        }
        // A device still on an older build may keep re-uploading its own favourites list.
        absorbLegacyFavorites()
    }

    private func pushFavoritesToCloudIfChanged() {
        guard CloudSyncService.shared.isEnabled, lastCloudFavoriteIDs != favoriteChannelIDs else { return }
        lastCloudFavoriteIDs = favoriteChannelIDs
        CloudSyncService.shared.save(favoriteChannelIDs, for: .favoriteChannelIDs)
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
        pushFavoritesToCloudIfChanged()
    }
}

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
