import Foundation
import Combine

/// Somewhere the app can open from outside its own UI: a tapped notification or a
/// `banner://` URL. Game links from CarPlay, Live Activities and Siri (`banner://game/{id}`)
/// are `BannerDeepLink`'s; the two share the `banner` scheme and each ignores the other's hosts.
nonisolated enum DeepLink: Equatable, Sendable {
    /// A game's detail screen. `date` is the game's start, when known, so the loader can ask
    /// for just that day's scoreboard.
    case match(leagueID: String, matchID: String, date: Date?)
    case home
    case following
    case live
    case discover
    case settings

    static let scheme = "banner"

    /// `banner://match?league=soccer%2Feng.1&id=401234&date=1790000000`, or `banner://live`
    /// (and `home`, `following`, `discover`, `settings`) to switch tabs.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased() else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch host {
        case "match":
            guard let leagueID = value("league"), let matchID = value("id") else { return nil }
            self = .match(leagueID: leagueID, matchID: matchID, date: Self.date(from: value("date")))
        case "home": self = .home
        case "following": self = .following
        case "live": self = .live
        case "discover": self = .discover
        case "settings": self = .settings
        default: return nil
        }
    }

    /// From the `userInfo` of a local notification this app scheduled.
    init?(notificationUserInfo userInfo: [AnyHashable: Any]) {
        if let matchID = userInfo["matchID"] as? String, let leagueID = userInfo["leagueID"] as? String {
            self = .match(leagueID: leagueID, matchID: matchID, date: Self.date(from: userInfo["matchDate"] as? String))
            return
        }
        switch (userInfo["bannertv_type"] as? String) ?? (userInfo["notificationType"] as? String) {
        case "programme_reminder": self = .live
        case "morningDigest": self = .home
        case "fantasyTonight", "fantasyInjury": self = .following
        default: return nil
        }
    }

    private static func date(from epochSeconds: String?) -> Date? {
        epochSeconds.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}

/// Hands a `DeepLink` from wherever it arrives (the notification delegate, `onOpenURL`) to the
/// UI that can open it.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    /// The link waiting to be opened. It stays set until a view takes it, so a link that arrives
    /// before the UI exists (a cold launch from a notification tap, or during onboarding) isn't lost.
    @Published private(set) var pending: DeepLink?

    private init() {}

    func handle(_ link: DeepLink) {
        pending = link
    }

    /// Marks the pending link as taken.
    func clear() {
        pending = nil
    }
}
