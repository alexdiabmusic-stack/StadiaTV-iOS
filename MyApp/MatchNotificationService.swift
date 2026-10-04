import Foundation
import UserNotifications

#if os(tvOS)
/// tvOS notifications support badges only, so match reminders are a no-op there.
@MainActor
final class MatchNotificationService {
    static let shared = MatchNotificationService()

    private init() {}

    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func scheduleReminder(for match: Match, leadTime: MatchReminderLeadTime) async -> Bool { false }
    func remindedMatchIDs() async -> Set<String> { [] }
    func cancelReminder(forMatchID matchID: String) async {}
    func syncNotifications(matches: [Match], favorites: [FavoriteTeam], settings: NotificationSettings) async {}
    func scheduleMorningDigest(matches: [Match], hour: Int) async {}
    func removeMorningDigests() async {}
    func removeAllMatchNotifications() {}
}
#else
@MainActor
final class MatchNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MatchNotificationService()

    private typealias Planner = MatchNotificationPlanner

    private let center = UNUserNotificationCenter.current()
    /// Identifier → when its notification was due or sent. Stops alerts repeating on every refresh.
    private let ledgerKey = "bannertv.match.notificationLedger.v1"

    private override init() {
        super.init()
        // The delegate has to be in place before the app finishes launching, or a tap that
        // launches the app is never delivered; `MyApp.init` touches `shared` for that reason.
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap on a delivered notification opens whatever it was about.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let link = DeepLink(notificationUserInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run { DeepLinkRouter.shared.handle(link) }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // MARK: - A reminder the person asked for

    /// Schedules (or, for a live game, sends) the alerts for one match they tapped the bell on.
    func scheduleReminder(for match: Match, leadTime: MatchReminderLeadTime) async -> Bool {
        let settings = await center.notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = await requestAuthorization()
        default:
            authorized = false
        }
        guard authorized else { return false }

        let candidate = Self.candidate(from: match)
        let now = Date()
        var planned: [PlannedNotification] = []
        switch match.state {
        case .pre:
            guard let reminder = Planner.startReminder(for: candidate, leadTimeMinutes: leadTime.minutes, now: now, origin: Planner.userOrigin) else {
                return true
            }
            planned = [reminder]
        case .live:
            planned = [Planner.liveAlert(for: candidate, origin: Planner.userOrigin)]
            if candidate.isClose { planned.append(Planner.closeGameAlert(for: candidate, origin: Planner.userOrigin)) }
        case .final:
            return false
        }

        var ledger = loadLedger()
        for notification in planned {
            if await add(notification) { ledger[notification.identifier] = notification.fireDate ?? now }
        }
        saveLedger(Planner.prunedLedger(ledger, now: now))
        return true
    }

    /// Match IDs that currently have a start reminder waiting, however it was scheduled.
    func remindedMatchIDs() async -> Set<String> {
        let prefix = Planner.startIdentifier("")
        let requests = await center.pendingNotificationRequests()
        return Set(requests.compactMap { request -> String? in
            guard request.identifier.hasPrefix(prefix) else { return nil }
            return request.content.userInfo["matchID"] as? String
        })
    }

    /// Cancels the start reminder for one match (the bell toggled off).
    func cancelReminder(forMatchID matchID: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [Planner.startIdentifier(matchID)])
    }

    // MARK: - Favourite-team sync

    /// Brings the pending notifications for the favourite teams' games in line with `matches`,
    /// changing only what differs. Called on every refresh, so it must be cheap and must not
    /// repeat an alert that has already gone out (see `MatchNotificationPlanner`).
    func syncNotifications(matches: [Match], favorites: [FavoriteTeam], settings: NotificationSettings) async {
        guard settings.enabled, await isAuthorized() else { return }

        let favoriteIDs = Set(favorites.map(\.id) + favorites.map(\.canonicalTeamID))
        let favoriteMatches = favorites.isEmpty ? [] : matches.filter { match in
            isFavorite(match.away, in: favoriteIDs, league: match.league) || isFavorite(match.home, in: favoriteIDs, league: match.league)
        }
        let candidates = favoriteMatches.map(Self.candidate(from:))
        let now = Date()
        var ledger = loadLedger()

        let desired = Planner.plan(
            candidates: candidates,
            options: .init(
                leadTimeMinutes: settings.leadTime.minutes,
                liveAlerts: settings.liveAlerts,
                closeGameAlerts: settings.closeGameAlerts
            ),
            ledger: ledger,
            now: now
        )
        let managed = Planner.managedIdentifiers(for: candidates)
        let pendingNow = await pendingSnapshots()
        let changes = Planner.diff(desired: desired, pending: pendingNow) { pending in
            // Never touch a reminder the person set on a specific game; requests from builds
            // that predate `origin` are ours when they are for one of these games.
            pending.origin == Planner.favoriteSyncOrigin
                || (managed.contains(pending.identifier) && pending.origin != Planner.userOrigin)
        }

        if !changes.remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        }
        for notification in changes.add {
            if await add(notification) { ledger[notification.identifier] = notification.fireDate ?? now }
        }
        saveLedger(Planner.prunedLedger(ledger, now: now))
    }

    // MARK: - Morning briefing

    /// One-shot briefings for the next week at `hour`, replacing any repeating one an older
    /// build scheduled.
    func scheduleMorningDigest(matches: [Match], hour: Int) async {
        guard await isAuthorized() else { return }
        let candidates = matches.map { DigestCandidate(date: $0.date, state: $0.state, shortName: $0.shortName) }
        let desired = Planner.planDigests(matches: candidates, hour: hour, now: Date())
        let pendingNow = await pendingSnapshots()
        let changes = Planner.diff(desired: desired, pending: pendingNow) {
            $0.identifier.hasPrefix(Planner.digestIdentifierPrefix)
        }
        if !changes.remove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: changes.remove)
        }
        for notification in changes.add {
            _ = await add(notification)
        }
    }

    func removeMorningDigests() async {
        await removePending { $0.identifier.hasPrefix(Planner.digestIdentifierPrefix) }
    }

    // MARK: - Removal

    func removeAllMatchNotifications() {
        Task {
            await removePending {
                $0.identifier.hasPrefix(Planner.identifierPrefix) || $0.identifier.hasPrefix(Planner.digestIdentifierPrefix)
            }
        }
    }

    private func removePending(where shouldRemove: (PendingNotificationSnapshot) -> Bool) async {
        let identifiers = await pendingSnapshots().filter(shouldRemove).map(\.identifier)
        if !identifiers.isEmpty { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    }

    // MARK: - Center plumbing

    private func pendingSnapshots() async -> [PendingNotificationSnapshot] {
        await center.pendingNotificationRequests().map { request in
            let fireDate = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return PendingNotificationSnapshot(
                identifier: request.identifier,
                title: request.content.title,
                body: request.content.body,
                fireDate: fireDate,
                origin: request.content.userInfo["origin"] as? String
            )
        }
    }

    private func add(_ planned: PlannedNotification) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.sound = .default
        content.userInfo = planned.userInfo

        let trigger: UNNotificationTrigger
        if let fireDate = planned.fireDate {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        do {
            try await center.add(UNNotificationRequest(identifier: planned.identifier, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    private func loadLedger() -> [String: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: ledgerKey) as? [String: TimeInterval] ?? [:]
        return stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveLedger(_ ledger: [String: Date]) {
        UserDefaults.standard.set(ledger.mapValues { $0.timeIntervalSince1970 }, forKey: ledgerKey)
    }

    // MARK: - Matching

    private func isFavorite(_ side: TeamSide, in favoriteIDs: Set<String>, league: League) -> Bool {
        if let teamID = side.teamID, favoriteIDs.contains("\(league.path)-\(teamID)") {
            return true
        }
        if let canonicalID = side.canonicalIDString, favoriteIDs.contains(canonicalID) {
            return true
        }
        return false
    }

    private static func candidate(from match: Match) -> NotificationCandidate {
        NotificationCandidate(
            matchID: match.id,
            leagueID: match.league.id,
            date: match.date,
            state: match.state,
            awayShortName: match.away.shortName,
            homeShortName: match.home.shortName,
            awayScore: match.away.score,
            homeScore: match.home.score,
            statusDetail: match.statusDetail,
            closeMargin: closeMargin(for: match.league.group),
            homeFirst: match.listsHomeSideFirst
        )
    }

    /// Largest score gap that still counts as a close game.
    private static func closeMargin(for group: SportGroup) -> Int? {
        switch group {
        case .football: return 8
        case .basketball: return 5
        case .baseball, .hockey, .soccer: return 1
        case .golf, .racing, .tennis, .cycling, .wrestling, .esports: return nil
        }
    }
}
#endif
