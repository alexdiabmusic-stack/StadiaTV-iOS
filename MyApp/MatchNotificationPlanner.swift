import Foundation

// Pure planning for match notifications: given what is happening and what has already been
// sent, decide what the pending queue should contain. Kept free of UserNotifications types so
// it can be tested without a device; `MatchNotificationService` applies the result.

/// The facts about a match that notification scheduling depends on, copied out of `Match`.
nonisolated struct NotificationCandidate: Equatable, Sendable {
    let matchID: String
    let leagueID: String
    let date: Date
    let state: GameState
    let awayShortName: String
    let homeShortName: String
    let awayScore: String?
    let homeScore: String?
    let statusDetail: String
    /// Largest score gap that still counts as a close game; nil where the sport has no such notion.
    let closeMargin: Int?

    var isClose: Bool {
        guard let closeMargin, let away = Int(awayScore ?? ""), let home = Int(homeScore ?? "") else { return false }
        return abs(away - home) <= closeMargin
    }
}

/// A match in the daily briefing.
nonisolated struct DigestCandidate: Equatable, Sendable {
    let date: Date
    let state: GameState
    let shortName: String
}

/// A local notification the schedule should contain.
nonisolated struct PlannedNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    /// When to deliver; nil means right away.
    let fireDate: Date?
    let userInfo: [String: String]
}

/// A local notification currently waiting in the system's pending queue.
nonisolated struct PendingNotificationSnapshot: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date?
    /// `userInfo["origin"]`: who scheduled it.
    let origin: String?
}

nonisolated enum MatchNotificationPlanner {
    nonisolated struct Options: Equatable, Sendable {
        var leadTimeMinutes: Int
        var liveAlerts = true
        var closeGameAlerts = true
    }

    /// `userInfo["origin"]` values. Only `favoriteSync` requests are added and removed by the sync;
    /// `user` marks a reminder the person asked for on a specific match.
    static let favoriteSyncOrigin = "favorite"
    static let userOrigin = "user"
    static let digestOrigin = "digest"

    static let identifierPrefix = "bannertv.match."
    static let digestIdentifierPrefix = "bannertv.morning.digest"

    /// Start reminders are only scheduled this far ahead.
    static let horizon: TimeInterval = 7 * 24 * 3600
    /// iOS keeps at most 64 pending local notifications per app; match reminders take a share
    /// and leave room for programme reminders, daily briefings and Fantasy alerts.
    static let maxScheduledStartReminders = 40
    /// An "is live" alert is only worth sending near kickoff, not when the app is opened mid-game.
    static let liveAlertWindow: TimeInterval = 30 * 60
    /// Ledger entries are kept this long after they were due.
    static let ledgerRetention: TimeInterval = 3 * 24 * 3600
    static let digestDays = 7

    static func startIdentifier(_ matchID: String) -> String { "\(identifierPrefix)start.\(matchID)" }
    static func liveIdentifier(_ matchID: String) -> String { "\(identifierPrefix)live.\(matchID)" }
    static func closeIdentifier(_ matchID: String) -> String { "\(identifierPrefix)close.\(matchID)" }

    // MARK: - Match notifications

    /// The notifications that should exist for `candidates`.
    ///
    /// `ledger` maps an identifier to when its notification was due or sent. It is what stops a
    /// notification from being sent again on every refresh: anything already in it is never
    /// re-sent immediately, and a scheduled start reminder that has since fired isn't re-created.
    static func plan(
        candidates: [NotificationCandidate],
        options: Options,
        ledger: [String: Date],
        now: Date
    ) -> [PlannedNotification] {
        var scheduledStarts: [PlannedNotification] = []
        var immediate: [PlannedNotification] = []

        for match in candidates {
            switch match.state {
            case .pre:
                guard match.date <= now.addingTimeInterval(horizon),
                      let reminder = startReminder(for: match, leadTimeMinutes: options.leadTimeMinutes, now: now, origin: favoriteSyncOrigin)
                else { continue }
                if reminder.fireDate != nil {
                    scheduledStarts.append(reminder)
                } else if ledger[reminder.identifier] == nil {
                    immediate.append(reminder)   // inside the lead window and never sent
                }
            case .live:
                if options.liveAlerts,
                   now.timeIntervalSince(match.date) <= liveAlertWindow,
                   ledger[liveIdentifier(match.matchID)] == nil {
                    immediate.append(liveAlert(for: match, origin: favoriteSyncOrigin))
                }
                if options.closeGameAlerts, match.isClose, ledger[closeIdentifier(match.matchID)] == nil {
                    immediate.append(closeGameAlert(for: match, origin: favoriteSyncOrigin))
                }
            case .final:
                continue
            }
        }

        let soonest = scheduledStarts
            .sorted { ($0.fireDate ?? .distantFuture, $0.identifier) < ($1.fireDate ?? .distantFuture, $1.identifier) }
            .prefix(maxScheduledStartReminders)
        return Array(soonest) + immediate.sorted { $0.identifier < $1.identifier }
    }

    // MARK: Individual notifications

    /// The "game starting" reminder: scheduled for `leadTimeMinutes` before kickoff, or, when
    /// kickoff is closer than that, due right away (`fireDate` nil). Nil once the game has begun.
    static func startReminder(
        for match: NotificationCandidate,
        leadTimeMinutes: Int,
        now: Date,
        origin: String
    ) -> PlannedNotification? {
        guard match.date > now else { return nil }
        let fireDate = match.date.addingTimeInterval(-TimeInterval(leadTimeMinutes * 60))
        return PlannedNotification(
            identifier: startIdentifier(match.matchID),
            title: "It's game time in \(leadTimeMinutes) minutes!!",
            body: "Don't forget to tune into BannerTV to watch the action live!",
            fireDate: fireDate > now ? fireDate : nil,
            userInfo: userInfo(for: match, type: "gameTimeReminder", origin: origin)
        )
    }

    static func liveAlert(for match: NotificationCandidate, origin: String) -> PlannedNotification {
        PlannedNotification(
            identifier: liveIdentifier(match.matchID),
            title: "\(match.awayShortName) vs \(match.homeShortName) is live",
            body: match.statusDetail,
            fireDate: nil,
            userInfo: userInfo(for: match, type: "gameLive", origin: origin)
        )
    }

    static func closeGameAlert(for match: NotificationCandidate, origin: String) -> PlannedNotification {
        PlannedNotification(
            identifier: closeIdentifier(match.matchID),
            title: "Close game: \(match.awayShortName) vs \(match.homeShortName)",
            body: "\(match.awayScore ?? "-")-\(match.homeScore ?? "-") · \(match.statusDetail)",
            fireDate: nil,
            userInfo: userInfo(for: match, type: "closeGame", origin: origin)
        )
    }

    /// Every identifier the sync could own for `candidates`, whether or not it is wanted right now.
    static func managedIdentifiers(for candidates: [NotificationCandidate]) -> Set<String> {
        Set(candidates.flatMap { [startIdentifier($0.matchID), liveIdentifier($0.matchID), closeIdentifier($0.matchID)] })
    }

    // MARK: - Daily briefing

    /// One-shot briefings for the next `digestDays` days at `hour`. A repeating trigger would
    /// repeat a body computed once; this recomputes it each time the schedule is refreshed.
    static func planDigests(
        matches: [DigestCandidate],
        hour: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [PlannedNotification] {
        var planned: [PlannedNotification] = []
        for offset in 0..<digestDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  let fireDate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                  fireDate > now else { continue }
            let games = matches
                .filter { $0.state != .final && calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date < $1.date }
            guard !games.isEmpty else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let names = games.prefix(3).map(\.shortName).joined(separator: "  ·  ")
            planned.append(PlannedNotification(
                identifier: String(format: "%@.%04d%02d%02d", digestIdentifierPrefix, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                title: "Today in Sports",
                body: "\(games.count) game\(games.count == 1 ? "" : "s") today: \(names)",
                fireDate: fireDate,
                userInfo: ["notificationType": "morningDigest", "origin": digestOrigin]
            ))
        }
        return planned
    }

    // MARK: - Reconciling with the pending queue

    /// What to remove from, and add to, the pending queue so it matches `desired`, touching only
    /// requests `isManaged` claims. Requests that already match are left alone.
    static func diff(
        desired: [PlannedNotification],
        pending: [PendingNotificationSnapshot],
        isManaged: (PendingNotificationSnapshot) -> Bool
    ) -> (remove: [String], add: [PlannedNotification]) {
        let desiredIDs = Set(desired.map(\.identifier))
        let remove = pending.filter { isManaged($0) && !desiredIDs.contains($0.identifier) }.map(\.identifier)
        let pendingByID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let add = desired.filter { planned in
            guard let existing = pendingByID[planned.identifier] else { return true }
            return !existing.isEquivalent(to: planned)
        }
        return (remove, add)
    }

    /// Entries whose notification was due recently enough to still matter.
    static func prunedLedger(_ ledger: [String: Date], now: Date) -> [String: Date] {
        ledger.filter { now.timeIntervalSince($0.value) <= ledgerRetention }
    }

    private static func userInfo(for match: NotificationCandidate, type: String, origin: String) -> [String: String] {
        [
            "matchID": match.matchID,
            "leagueID": match.leagueID,
            "matchDate": String(Int(match.date.timeIntervalSince1970)),
            "notificationType": type,
            "origin": origin,
        ]
    }
}

private extension PendingNotificationSnapshot {
    /// Same content, delivered at the same minute. A pending request with a near-immediate
    /// trigger counts as equivalent to a planned "right away" one.
    func isEquivalent(to planned: PlannedNotification) -> Bool {
        guard title == planned.title, body == planned.body else { return false }
        switch (fireDate, planned.fireDate) {
        case let (existing?, wanted?): return Int(existing.timeIntervalSince1970 / 60) == Int(wanted.timeIntervalSince1970 / 60)
        case (_, nil): return true
        case (nil, _?): return false
        }
    }
}
