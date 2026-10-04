import Foundation
import Testing
@testable import BannerTV

/// How a `bannertv://` URL or a tapped notification maps to somewhere in the app.
@Suite("Deep links")
struct DeepLinkTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("A match link carries its league, id and, when known, start time")
    func matchURL() {
        #expect(DeepLink(url: url("bannertv://match?league=soccer%2Feng.1&id=401234&date=1790000000"))
                == .match(leagueID: "soccer/eng.1", matchID: "401234", date: Date(timeIntervalSince1970: 1790000000)))
        #expect(DeepLink(url: url("bannertv://match?league=hockey/nhl&id=9"))
                == .match(leagueID: "hockey/nhl", matchID: "9", date: nil), "an unescaped slash is fine, and the date is optional")
        #expect(DeepLink(url: url("bannertv://match?league=a&id=b&date=notanumber"))
                == .match(leagueID: "a", matchID: "b", date: nil), "a bad date is ignored and the link kept")
    }

    @Test("Tab links, in any case")
    func tabURLs() {
        #expect(DeepLink(url: url("BannerTV://Live")) == .live)
        #expect(DeepLink(url: url("bannertv://home")) == .home)
        #expect(DeepLink(url: url("bannertv://following")) == .following)
        #expect(DeepLink(url: url("bannertv://discover")) == .discover)
        #expect(DeepLink(url: url("bannertv://settings")) == .settings)
    }

    @Test("Anything else is rejected")
    func rejected() {
        #expect(DeepLink(url: url("bannertv://match?league=&id=1")) == nil, "empty league")
        #expect(DeepLink(url: url("bannertv://match?id=1")) == nil, "missing league")
        #expect(DeepLink(url: url("bannertv://match?league=a")) == nil, "missing id")
        #expect(DeepLink(url: url("bannertv://unknown")) == nil)
        #expect(DeepLink(url: url("https://example.com/match?league=a&id=b")) == nil, "other schemes")
    }

    @Test("A match notification opens that match")
    func matchNotification() {
        let userInfo: [AnyHashable: Any] = [
            "matchID": "m1", "leagueID": "football/nfl", "matchDate": "1790000000",
            "notificationType": "gameLive", "origin": "favorite",
        ]
        #expect(DeepLink(notificationUserInfo: userInfo)
                == .match(leagueID: "football/nfl", matchID: "m1", date: Date(timeIntervalSince1970: 1790000000)))
        #expect(DeepLink(notificationUserInfo: ["matchID": "m1", "leagueID": "x"])
                == .match(leagueID: "x", matchID: "m1", date: nil), "an older notification without a date")
    }

    @Test("Other notifications open the tab they belong to")
    func otherNotifications() {
        #expect(DeepLink(notificationUserInfo: ["bannertv_type": "programme_reminder", "channelID": "c"]) == .live)
        #expect(DeepLink(notificationUserInfo: ["notificationType": "morningDigest"]) == .home)
        #expect(DeepLink(notificationUserInfo: ["notificationType": "fantasyTonight"]) == .following)
        #expect(DeepLink(notificationUserInfo: ["notificationType": "fantasyInjury", "playerID": "1"]) == .following)
        #expect(DeepLink(notificationUserInfo: ["notificationType": "somethingElse"]) == nil)
        #expect(DeepLink(notificationUserInfo: [:]) == nil)
    }

    @Test("What the planner puts in a reminder parses back to the same match")
    func plannerRoundTrip() throws {
        let kickoff = Date(timeIntervalSince1970: 1_790_000_000)
        let candidate = NotificationCandidate(
            matchID: "abc", leagueID: "basketball/nba", date: kickoff, state: .pre, awayShortName: "A", homeShortName: "H",
            awayScore: nil, homeScore: nil, statusDetail: "", closeMargin: 5
        )
        let reminder = try #require(MatchNotificationPlanner.startReminder(
            for: candidate, leadTimeMinutes: 30, now: kickoff.addingTimeInterval(-86400), origin: "favorite"))
        #expect(DeepLink(notificationUserInfo: reminder.userInfo)
                == .match(leagueID: "basketball/nba", matchID: "abc", date: kickoff))
    }

    @MainActor
    @Test("The router keeps a link until the UI takes it, and a newer link replaces it")
    func router() {
        let router = DeepLinkRouter.shared
        router.clear()
        router.handle(.live)
        #expect(router.pending == .live, "a link that arrives before the UI exists waits for it")
        router.handle(.home)
        #expect(router.pending == .home, "a newer link replaces it")
        router.clear()
        #expect(router.pending == nil, "cleared once taken")
    }
}
