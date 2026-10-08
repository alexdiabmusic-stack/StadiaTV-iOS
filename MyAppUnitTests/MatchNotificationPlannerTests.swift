import Foundation
import Testing
@testable import BannerTV

/// What the notification schedule should contain (`MatchNotificationPlanner`): each alert goes out once, the pending
/// queue is only touched where it differs, and the sync never removes a request it doesn't own.
@Suite("Match notification planning")
struct MatchNotificationPlannerTests {

    private typealias P = MatchNotificationPlanner

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(2026, 10, 4, 12, 0) }
    private let options = P.Options(leadTimeMinutes: 30)

    private func candidate(
        _ id: String, in seconds: TimeInterval, state: GameState = .pre, away: String? = nil, home: String? = nil,
        margin: Int? = 1, status: String = "7:00 PM", homeFirst: Bool = false,
        awayName: String = "AWY", homeName: String = "HOM"
    ) -> NotificationCandidate {
        NotificationCandidate(
            matchID: id, leagueID: "soccer/eng.1", date: now.addingTimeInterval(seconds), state: state,
            awayShortName: awayName, homeShortName: homeName, awayScore: away, homeScore: home,
            statusDetail: status, closeMargin: margin, homeFirst: homeFirst
        )
    }

    private func snapshot(
        _ planned: PlannedNotification, origin: String? = "favorite"
    ) -> PendingNotificationSnapshot {
        PendingNotificationSnapshot(identifier: planned.identifier, title: planned.title, body: planned.body,
                                    fireDate: planned.fireDate, origin: origin)
    }

    // MARK: Start reminders

    @Test("A start reminder is scheduled once, then left alone")
    func startReminder() throws {
        let planned = P.plan(candidates: [candidate("m1", in: 3 * 86400)], options: options, ledger: [:], now: now)
        let reminder = try #require(planned.first)
        #expect(planned.count == 1)
        #expect(reminder.identifier == "bannertv.match.start.m1")
        #expect(reminder.fireDate == now.addingTimeInterval(3 * 86400 - 1800), "fires the lead time before kickoff")
        #expect(reminder.title == "It's game time in 30 minutes!!")
        #expect(reminder.userInfo["matchID"] == "m1")
        #expect(reminder.userInfo["leagueID"] == "soccer/eng.1")
        #expect(reminder.userInfo["origin"] == "favorite", "carries what a tap needs, and who scheduled it")

        let unchanged = P.diff(desired: planned, pending: [snapshot(reminder)], isManaged: { $0.origin == "favorite" })
        #expect(unchanged.add.isEmpty && unchanged.remove.isEmpty, "a second sync against identical pending requests does nothing")
        let first = P.diff(desired: planned, pending: [], isManaged: { _ in true })
        #expect(first.add.count == 1 && first.remove.isEmpty)
    }

    @Test("Inside the lead window the alert goes out once, not on every refresh")
    func insideLeadWindow() throws {
        let soon = candidate("m2", in: 10 * 60)   // starts in 10 minutes, the lead is 30
        var ledger: [String: Date] = [:]
        let first = P.plan(candidates: [soon], options: options, ledger: ledger, now: now)
        let alert = try #require(first.first)
        #expect(first.count == 1 && alert.fireDate == nil, "the first sync sends one immediate alert")
        ledger[alert.identifier] = now
        for tick in 1...5 {
            let again = P.plan(candidates: [soon], options: options, ledger: ledger, now: now.addingTimeInterval(Double(tick) * 25))
            #expect(again.isEmpty, "refresh \(tick * 25) s later sends nothing")
        }
    }

    @Test("A reminder whose time has passed is not recreated")
    func firedReminder() {
        let match = candidate("m3", in: 20 * 60)   // its fire time, ten minutes ago, has passed
        let ledger = ["bannertv.match.start.m3": now.addingTimeInterval(-10 * 60)]
        #expect(P.plan(candidates: [match], options: options, ledger: ledger, now: now).isEmpty)
        #expect(P.plan(candidates: [match], options: options, ledger: [:], now: now).count == 1, "an unknown one is still sent at once")
    }

    @Test("Changing the lead time replaces the request in place")
    func leadTimeChange() throws {
        let at30 = try #require(P.plan(candidates: [candidate("m9", in: 86400)], options: options, ledger: [:], now: now).first)
        let at60 = P.plan(candidates: [candidate("m9", in: 86400)], options: P.Options(leadTimeMinutes: 60), ledger: [:], now: now)
        let diff = P.diff(desired: at60, pending: [snapshot(at30)], isManaged: { $0.origin == "favorite" })
        #expect(diff.add.count == 1 && diff.add.first?.title.contains("60") == true)
        #expect(diff.remove.isEmpty, "the same identifier replaces the old request")
    }

    // MARK: Live and close-game alerts

    @Test("Live and close-game alerts go out once each")
    func liveAndClose() throws {
        let live = candidate("m4", in: -5 * 60, state: .live, away: "2", home: "1", status: "5'")
        var ledger: [String: Date] = [:]
        let first = P.plan(candidates: [live], options: options, ledger: ledger, now: now)
        #expect(Set(first.map(\.identifier)) == ["bannertv.match.live.m4", "bannertv.match.close.m4"])
        #expect(first.first { $0.identifier.contains("close") }?.body == "2-1 · 5'", "the close-game body shows score and status")
        for alert in first { ledger[alert.identifier] = now }
        #expect(P.plan(candidates: [live], options: options, ledger: ledger, now: now.addingTimeInterval(25)).isEmpty, "the next refresh sends nothing")
    }

    @Test("'Is live' only goes out near kickoff; a close game still does mid-match")
    func openedMidGame() {
        let late = candidate("m5", in: -90 * 60, state: .live, away: "0", home: "3", margin: 1)
        #expect(P.plan(candidates: [late], options: options, ledger: [:], now: now).isEmpty, "opened 90 minutes in, not close: no stale 'is live' alert")
        let lateClose = candidate("m6", in: -90 * 60, state: .live, away: "2", home: "2", margin: 1)
        #expect(P.plan(candidates: [lateClose], options: options, ledger: [:], now: now).map(\.identifier) == ["bannertv.match.close.m6"])
    }

    @Test("Switches, finished games and sports with no close-game notion")
    func switchesAndStates() {
        let live = candidate("m4", in: -5 * 60, state: .live, away: "2", home: "1", status: "5'")
        var off = options
        off.liveAlerts = false
        off.closeGameAlerts = false
        #expect(P.plan(candidates: [live], options: off, ledger: [:], now: now).isEmpty, "both switches off")
        let finished = candidate("m7", in: -3600, state: .final, away: "2", home: "2")
        #expect(P.plan(candidates: [finished], options: options, ledger: [:], now: now).isEmpty, "finished games produce nothing")
        let noMargin = candidate("m8", in: -300, state: .live, away: "100", home: "99", margin: nil)
        #expect(P.plan(candidates: [noMargin], options: options, ledger: [:], now: now).map(\.identifier) == ["bannertv.match.live.m8"])
    }

    @Test("Soccer reads the home side first")
    func soccerOrder() {
        let soccer = candidate("s1", in: -300, state: .live, away: "1", home: "2", status: "34'", homeFirst: true, awayName: "CHE", homeName: "ARS")
        let planned = P.plan(candidates: [soccer], options: options, ledger: [:], now: now)
        #expect(planned.first { $0.identifier.contains("live") }?.title == "ARS vs CHE is live")
        #expect(planned.first { $0.identifier.contains("close") }?.title == "Close game: ARS vs CHE")
        #expect(planned.first { $0.identifier.contains("close") }?.body == "2-1 · 34'", "the score reads home to away")
    }

    // MARK: The pending queue

    @Test("Games beyond the horizon aren't scheduled, and the soonest 40 are kept")
    func horizonAndCap() {
        #expect(P.plan(candidates: [candidate("far", in: 8 * 86400)], options: options, ledger: [:], now: now).isEmpty, "8 days out is beyond the horizon")
        let stale = PendingNotificationSnapshot(identifier: "bannertv.match.start.far", title: "t", body: "b",
                                                fireDate: now.addingTimeInterval(8 * 86400), origin: "favorite")
        #expect(P.diff(desired: [], pending: [stale], isManaged: { $0.origin == "favorite" }).remove == ["bannertv.match.start.far"],
                "a pending request beyond the horizon is removed")

        let many = (0..<60).map { candidate("g\($0)", in: Double(1 + $0) * 3600 + 7200) }
        let planned = P.plan(candidates: many, options: options, ledger: [:], now: now)
        #expect(planned.count == P.maxScheduledStartReminders)
        #expect(planned.map(\.identifier) == (0..<P.maxScheduledStartReminders).map { "bannertv.match.start.g\($0)" }, "the soonest, in order")
        // iOS keeps 64 pending local notifications per app; the briefings and programme reminders share them.
        #expect(P.maxScheduledStartReminders + P.digestDays + 10 <= 64, "match reminders leave room for everything else")
    }

    @Test("Only the sync's own requests are ever removed")
    func ownership() {
        func pending(_ id: String, origin: String?) -> PendingNotificationSnapshot {
            PendingNotificationSnapshot(identifier: id, title: "", body: "", fireDate: nil, origin: origin)
        }
        let mine = pending("bannertv.match.start.a", origin: "favorite")
        let theirs = pending("bannertv.match.start.b", origin: "user")
        let older = pending("bannertv.match.start.c", origin: nil)
        let unrelated = pending("bannertv.prog.xyz", origin: nil)
        let known = P.managedIdentifiers(for: [candidate("c", in: 100), candidate("a", in: 100)])
        let diff = P.diff(desired: [], pending: [mine, theirs, older, unrelated], isManaged: {
            $0.origin == P.favoriteSyncOrigin || (known.contains($0.identifier) && $0.origin != P.userOrigin)
        })
        #expect(Set(diff.remove) == ["bannertv.match.start.a", "bannertv.match.start.c"],
                "its own, and older ones for matches it knows; never a reminder the person set or an unrelated request")
    }

    @Test("Old ledger entries are dropped")
    func ledgerPruning() {
        let ledger = ["old": now.addingTimeInterval(-4 * 86400), "recent": now.addingTimeInterval(-3600), "future": now.addingTimeInterval(86400)]
        #expect(Set(P.prunedLedger(ledger, now: now).keys) == ["recent", "future"])
    }

    // MARK: Morning briefings

    @Test("Briefings are one-shot, for the next seven days, on days with games")
    func briefings() {
        func game(_ day: Int, _ hour: Int, _ name: String, state: GameState = .pre) -> DigestCandidate {
            DigestCandidate(date: date(2026, 10, day, hour), state: state, shortName: name)
        }
        let games = [game(4, 18, "A@B"), game(5, 19, "C@D"), game(5, 13, "E@F"), game(5, 21, "G@H"), game(5, 22, "I@J"),
                     game(7, 20, "K@L"), game(5, 9, "done", state: .final), game(20, 12, "far")]
        let planned = P.planDigests(matches: games, hour: 8, now: now, calendar: utc)   // 8:00 today has passed
        #expect(planned.map(\.identifier) == ["bannertv.morning.digest.20261005", "bannertv.morning.digest.20261007"])
        #expect(planned.first?.fireDate == date(2026, 10, 5, 8), "fires at the chosen hour")
        #expect(planned.first?.body == "4 games today: E@F  ·  C@D  ·  G@H", "the first three by start time, and the count")
        #expect(planned.last?.body == "1 game today: K@L")

        let early = P.planDigests(matches: games, hour: 8, now: date(2026, 10, 4, 6, 0), calendar: utc)
        #expect(early.first?.identifier == "bannertv.morning.digest.20261004", "before the briefing hour, today's is included")
        #expect(P.planDigests(matches: games, hour: 13, now: now, calendar: utc).first?.identifier == "bannertv.morning.digest.20261004")

        let legacy = PendingNotificationSnapshot(identifier: "bannertv.morning.digest", title: "Today in Sports", body: "old",
                                                 fireDate: date(2026, 10, 5, 8), origin: nil)
        let stale = PendingNotificationSnapshot(identifier: "bannertv.morning.digest.20261009", title: "x", body: "y",
                                                fireDate: date(2026, 10, 9, 8), origin: "digest")
        let diff = P.diff(desired: planned, pending: [legacy, stale], isManaged: { $0.identifier.hasPrefix(P.digestIdentifierPrefix) })
        #expect(Set(diff.remove) == ["bannertv.morning.digest", "bannertv.morning.digest.20261009"], "the old repeating briefing and stale days go")
        #expect(diff.add.count == 2)
    }
}
