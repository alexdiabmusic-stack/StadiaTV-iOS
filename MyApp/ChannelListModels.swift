import Foundation
import Combine

// MARK: - Channel browser

/// Filtered, sorted channel list for `ChannelBrowserView`, computed off the main thread
/// when its inputs change instead of inside `body`.
@MainActor
final class ChannelBrowserModel: ObservableObject {
    @Published private(set) var displayChannels: [Channel] = []
    @Published private(set) var isComputing = false

    /// Everything the list depends on, captured on the main actor.
    struct Input: Sendable {
        enum Source: Sendable {
            case all
            case favorites
            case ids([String])
            case playlistGroup(UUID, String)
        }
        var source: Source
        var channels: [Channel]
        var byPlaylist: [Channel]
        var channelsByID: [String: Channel]
        var hiddenIDs: Set<String>
        var favoriteIDs: [String]
        var customNames: [String: String]
        var query: String
        var sortOrder: ChannelSortOrder
    }

    private var computeTask: Task<Void, Never>?
    private var lastQuery = ""
    private var indexByID: [String: Int] = [:]
    private var prefetchedThrough = -1

    /// Warms the logo cache for the rows just below `channelID` so fast scrolling
    /// doesn't show blank logos.
    func prefetchLogos(after channelID: String, count: Int = 30, maxPixelSize: Int) {
        guard let index = indexByID[channelID] else { return }
        let start = max(index + 1, prefetchedThrough + 1)
        let end = min(displayChannels.count, index + 1 + count)
        guard start < end else { return }
        prefetchedThrough = end - 1
        ImagePipeline.shared.prefetch(displayChannels[start..<end].compactMap(\.logoURL), maxPixelSize: maxPixelSize)
    }

    /// Recomputes the list, debouncing typing (150 ms) and cancelling stale work.
    func update(_ input: Input) {
        prefetchedThrough = -1
        let queryChanged = input.query != lastQuery
        lastQuery = input.query
        computeTask?.cancel()
        isComputing = true
        computeTask = Task { [weak self] in
            if queryChanged {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                ChannelBrowserModel.compute(input)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.displayChannels = result
            self.indexByID = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.isComputing = false
        }
    }

    nonisolated static func compute(_ input: Input) -> [Channel] {
        let base: [Channel]
        switch input.source {
        case .all:
            base = input.channels.filter { !input.hiddenIDs.contains($0.id) }
        case .favorites:
            base = input.favoriteIDs.compactMap { input.channelsByID[$0] }
        case .ids(let ids):
            base = ids.compactMap { input.channelsByID[$0] }
        case .playlistGroup(_, let title):
            base = input.byPlaylist.filter { ($0.group ?? "") == title && !input.hiddenIDs.contains($0.id) }
        }
        if Task.isCancelled { return [] }

        // Sort keys are computed once per channel, not once per comparison, and only when a search
        // or a name-based order reads them: folding 20,000 names isn't free.
        struct Keyed { let channel: Channel; let key: String; let number: Int? }
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = query.isEmpty ? nil : sortKey(query)
        let sortsByName: Bool
        switch input.sortOrder {
        case .nameAZ, .nameZA, .favoritesFirst: sortsByName = true
        case .providerOrder, .channelNumber, .custom: sortsByName = false
        }
        let needsKey = needle != nil || sortsByName
        var keyed: [Keyed] = []
        keyed.reserveCapacity(base.count)
        for channel in base {
            let name = input.customNames[channel.id] ?? channel.name
            let key = needsKey ? sortKey(name) : ""
            if let needle, !key.contains(needle) { continue }
            let number = input.sortOrder == .channelNumber ? channelNumber(name) : nil
            keyed.append(Keyed(channel: channel, key: key, number: number))
        }
        if Task.isCancelled { return [] }

        switch input.sortOrder {
        case .providerOrder, .custom:
            break
        case .nameAZ:
            keyed.sort { $0.key < $1.key }
        case .nameZA:
            keyed.sort { $0.key > $1.key }
        case .channelNumber:
            keyed.sort { ($0.number ?? Int.max) < ($1.number ?? Int.max) }
        case .favoritesFirst:
            let favorites = Set(input.favoriteIDs)
            keyed.sort { a, b in
                let aFav = favorites.contains(a.channel.id), bFav = favorites.contains(b.channel.id)
                if aFav != bFav { return aFav }
                return a.key < b.key
            }
        }
        return keyed.map(\.channel)
    }

    /// Case- and diacritic-insensitive key; comparing these approximates localized ordering cheaply.
    nonisolated static func sortKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The number a provider puts in front of a channel name: "12. ESPN", "7 - BBC", "103| TNT", "5) Sky".
    /// A scan of the first few characters rather than two regular-expression searches per channel, which
    /// dominated sorting a large playlist by number. Spacing and digits follow ICU's `\s` (Unicode
    /// White_Space) and `\d` (decimal digits), as the pattern `^\s*(\d+)\s*[.\-|)]` did.
    nonisolated static func channelNumber(_ name: String) -> Int? {
        var rest = name.unicodeScalars[...]
        while let first = rest.first, first.properties.isWhitespace { rest = rest.dropFirst() }
        let digitsStart = rest.startIndex
        while let first = rest.first, first.properties.generalCategory == .decimalNumber { rest = rest.dropFirst() }
        let digits = name.unicodeScalars[digitsStart..<rest.startIndex]
        guard !digits.isEmpty else { return nil }
        while let first = rest.first, first.properties.isWhitespace { rest = rest.dropFirst() }
        guard let separator = rest.first, ".-|)".unicodeScalars.contains(separator) else { return nil }
        return Int(String(digits))
    }
}

// MARK: - Live browser

/// Provider groups and counts for `LiveBrowserView`, rebuilt only when channels or
/// channel/group preferences change rather than on every render.
@MainActor
final class LiveBrowserModel: ObservableObject {
    struct GroupEntry: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let count: Int
    }

    /// Groups per playlist, before user ordering.
    @Published private(set) var groupsByPlaylist: [UUID: [GroupEntry]] = [:]
    @Published private(set) var visibleChannelCount = 0

    private var groupTask: Task<Void, Never>?
    private var countTask: Task<Void, Never>?

    func rebuildGroups(channelsByPlaylist: [UUID: [Channel]]) {
        groupTask?.cancel()
        groupTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                var result: [UUID: [GroupEntry]] = [:]
                for (playlistID, channels) in channelsByPlaylist {
                    var counts: [String: Int] = [:]
                    var order: [String] = []
                    for channel in channels {
                        let title = channel.group ?? channel.playlistName
                        if counts[title] == nil { order.append(title) }
                        counts[title, default: 0] += 1
                    }
                    result[playlistID] = order.map {
                        GroupEntry(id: "\(playlistID.uuidString)|\($0)", title: $0, count: counts[$0] ?? 0)
                    }
                }
                return result
            }.value
            guard let self, !Task.isCancelled else { return }
            self.groupsByPlaylist = built
        }
    }

    func rebuildVisibleCount(channels: [Channel], hiddenIDs: Set<String>) {
        countTask?.cancel()
        countTask = Task { [weak self] in
            let count = await Task.detached(priority: .utility) {
                hiddenIDs.isEmpty ? channels.count : channels.reduce(0) { $0 + (hiddenIDs.contains($1.id) ? 0 : 1) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.visibleChannelCount = count
        }
    }

    /// User order first, then alphabetical. Only touches the (small) group list.
    func sortedGroups(for playlistID: UUID, sortOrder: (String) -> Int?) -> [GroupEntry] {
        let groups = groupsByPlaylist[playlistID] ?? []
        let keyed = groups.map { ($0, sortOrder($0.id) ?? Int.max, ChannelBrowserModel.sortKey($0.title)) }
        return keyed.sorted { a, b in
            if a.1 != Int.max || b.1 != Int.max { return a.1 < b.1 }
            return a.2 < b.2
        }
        .map(\.0)
    }
}
