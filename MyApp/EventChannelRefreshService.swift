import Foundation
import Combine

/// Identifies "event categories" — Xtream channel groups whose channel names carry the fixture,
/// e.g. "US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET" — so
/// `EventChannelRefreshService` knows which categories are worth polling for name changes
/// without scanning every category in the playlist. See MatchLinker/PROMPTS.md, Prompt 5.
nonisolated enum EventCategoryDetector {
    private static let keywordPattern = try! NSRegularExpression(
        pattern: #"\b(MLB|NHL|NBA|NFL|MLS|UFC|PPV|DAZN|ESPN\+|EVENT)\b"#, options: [.caseInsensitive]
    )
    private static let fixtureHintPattern = try! NSRegularExpression(
        pattern: #"\s(?:vs|@)\s|\b\d{1,2}:\d{2}\s*(?:AM|PM)\b"#, options: [.caseInsensitive]
    )

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Raw Xtream category ids that look like event slots: the category's own title names a
    /// league/event keyword, or at least 30% of its channels' names carry a fixture separator
    /// (" vs ", " @ ") or a clock time. Channels with no `xtreamCategoryID` (M3U) are ignored.
    static func eventCategoryIDs(in channels: [Channel]) -> Set<String> {
        var byCategory: [String: (title: String, members: [Channel])] = [:]
        for channel in channels {
            guard let categoryID = channel.xtreamCategoryID else { continue }
            byCategory[categoryID, default: (channel.group ?? "", [])].members.append(channel)
        }
        var result: Set<String> = []
        for (categoryID, entry) in byCategory {
            if matches(keywordPattern, entry.title) {
                result.insert(categoryID)
                continue
            }
            guard !entry.members.isEmpty else { continue }
            let fixtureLike = entry.members.filter { matches(fixtureHintPattern, $0.name) }.count
            if Double(fixtureLike) / Double(entry.members.count) >= 0.3 {
                result.insert(categoryID)
            }
        }
        return result
    }
}

/// Keeps event-slot channel names current by polling just their categories
/// (`get_live_streams&category_id=`, ~16 KB/0.35s per the provider's docs — an API call, not a
/// stream connection, so this is safe even on a single-connection account) instead of
/// re-downloading the full 6.9 MB stream list. See MatchLinker/PROMPTS.md, Prompt 5.
@MainActor
final class EventChannelRefreshService: ObservableObject {

    /// Every (stream id, name) pairing ever seen, first-seen date — a channel whose current
    /// name was first seen under an hour ago gets a "New" tag (`isNew`).
    @Published private(set) var firstSeenByKey: [String: Date] = [:]

    private var eventCategoryIDsByPlaylist: [UUID: Set<String>] = [:]
    private var didFullRefresh: Set<UUID> = []
    private var lastPollByKey: [String: Date] = [:]

    private let normalInterval: TimeInterval = 10 * 60
    private let hotInterval: TimeInterval = 60

    /// Call once per playlist load/reload (e.g. on `channelsRevision` change) — computing which
    /// categories look like event slots is an O(channels) scan, not worth repeating every poll.
    func noteChannelsLoaded(playlistID: UUID, channels: [Channel]) {
        eventCategoryIDsByPlaylist[playlistID] = EventCategoryDetector.eventCategoryIDs(in: channels)
        didFullRefresh.insert(playlistID)
    }

    /// Polls every known event category whose last poll has gone stale, for every Xtream
    /// playlist. `hot` requests the faster 60s cadence (30 minutes either side of a kickoff with
    /// no confident option yet, per Prompt 5 step 2) instead of the normal 10 minutes. Returns
    /// whether any channel was actually renamed, so the caller knows whether to invalidate and
    /// re-run matching (see `MatchesView`'s poll loop).
    @discardableResult
    func refreshIfDue(playlists: PlaylistStore, hot: Bool = false) async -> Bool {
        var anyChanged = false
        for playlist in playlists.playlists where playlist.kind == .xtream {
            guard let categoryIDs = eventCategoryIDsByPlaylist[playlist.id], !categoryIDs.isEmpty else { continue }
            var session = URLSession.shared
            #if DEBUG
            if let override = XtreamProviderAdapterTestHooks.session { session = override }
            #endif
            let adapter = XtreamProviderAdapter(provider: LiveProvider(playlist: playlist), session: session)
            for categoryID in categoryIDs {
                let key = "\(playlist.id.uuidString)|\(categoryID)"
                let interval = hot ? hotInterval : normalInterval
                if let last = lastPollByKey[key], Date().timeIntervalSince(last) < interval { continue }
                lastPollByKey[key] = Date()
                guard let fresh = try? await adapter.liveStreams(categoryID: categoryID) else { continue }
                if apply(fresh, playlistID: playlist.id, playlists: playlists) { anyChanged = true }
            }
        }
        return anyChanged
    }

    @discardableResult
    private func apply(_ fresh: [AdapterChannel], playlistID: UUID, playlists: PlaylistStore) -> Bool {
        var current = playlists.channelsByPlaylist[playlistID] ?? []
        guard !current.isEmpty else { return false }
        var indexByStreamID: [Int: Int] = [:]
        for (i, channel) in current.enumerated() {
            if let streamID = channel.xtreamStreamID { indexByStreamID[streamID] = i }
        }
        let now = Date()
        var changed = false
        for freshChannel in fresh {
            guard let streamID = freshChannel.xtreamStreamID, let index = indexByStreamID[streamID] else { continue }
            let key = "\(streamID)|\(freshChannel.name)"
            if firstSeenByKey[key] == nil { firstSeenByKey[key] = now }
            if current[index].name != freshChannel.name {
                current[index] = current[index].renamed(to: freshChannel.name)
                changed = true
            }
        }
        guard changed else { return false }
        playlists.updateChannels(current, for: playlistID)
        return true
    }

    /// True for the first hour after a (stream id, name) pairing was first observed — drives a
    /// "New" tag so a just-renamed event slot stands out (Prompt 5 step 4).
    func isNew(streamID: Int, name: String) -> Bool {
        guard let seen = firstSeenByKey["\(streamID)|\(name)"] else { return false }
        return Date().timeIntervalSince(seen) < 3600
    }
}
