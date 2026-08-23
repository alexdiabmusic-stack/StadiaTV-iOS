import Foundation

/// Persists the Live tab's UI state between app launches so the user returns
/// to the same provider, group, guide filter, and approximate scroll position.
///
/// All values are optional — missing entries cause the tab to start from defaults.
/// Write-through to UserDefaults; no explicit save step required.
final class LiveStateRestoration {
    static let shared = LiveStateRestoration()

    private enum Keys {
        static let liveFilter         = "stadiatv.live.restore.filter.v1"
        static let playlistID         = "stadiatv.live.restore.playlistID.v1"
        static let groupID            = "stadiatv.live.restore.groupID.v1"
        static let guideDisplayMode   = "stadiatv.live.restore.guideMode.v1"
        static let guideChannelOffset = "stadiatv.live.restore.guideChanOffset.v1"
        static let guideTimeOffset    = "stadiatv.live.restore.guideTimeOffset.v1"
    }

    private init() {}

    // MARK: - Live tab filter

    /// The last selected LiveFilter rawValue (e.g. "guide", "recordings").
    var liveFilter: String {
        get { UserDefaults.standard.string(forKey: Keys.liveFilter) ?? "forYou" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.liveFilter) }
    }

    // MARK: - Channel browser

    /// The last selected playlist UUID string (used to restore the browser's selected playlist tab).
    var playlistIDString: String? {
        get { UserDefaults.standard.string(forKey: Keys.playlistID) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.playlistID) }
    }

    var playlistID: UUID? {
        get { playlistIDString.flatMap(UUID.init(uuidString:)) }
        set { playlistIDString = newValue?.uuidString }
    }

    /// The last selected group ID within the browser.
    var groupID: String? {
        get { UserDefaults.standard.string(forKey: Keys.groupID) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.groupID) }
    }

    // MARK: - Guide

    /// "myGuide" or "all" — the last active guide display mode.
    var guideDisplayMode: String {
        get { UserDefaults.standard.string(forKey: Keys.guideDisplayMode) ?? "myGuide" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.guideDisplayMode) }
    }

    /// Approximate channel row index the guide was scrolled to.
    var guideChannelOffset: Int {
        get { UserDefaults.standard.integer(forKey: Keys.guideChannelOffset) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.guideChannelOffset) }
    }

    /// Approximate time offset (in minutes from midnight) the guide timeline was scrolled to.
    var guideTimeOffsetMinutes: Int {
        get { UserDefaults.standard.integer(forKey: Keys.guideTimeOffset) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.guideTimeOffset) }
    }

    // MARK: - Reset

    func clearAll() {
        let d = UserDefaults.standard
        [Keys.liveFilter, Keys.playlistID, Keys.groupID,
         Keys.guideDisplayMode, Keys.guideChannelOffset, Keys.guideTimeOffset]
            .forEach { d.removeObject(forKey: $0) }
    }
}
