import Foundation
import UserNotifications

#if os(tvOS)
/// tvOS notifications support badges only, so match reminders are a no-op there.
@MainActor
final class MatchNotificationService {
    static let shared = MatchNotificationService()

    private init() {}

    func requestAuthorization() async -> Bool { false }
    func scheduleReminder(for match: Match, leadTime: MatchReminderLeadTime) async -> Bool { false }
    func syncNotifications(matches: [Match], favorites: [FavoriteTeam], leadTime: MatchReminderLeadTime) async {}
    func scheduleMorningDigest(matches: [Match]) async {}
    func removeAllMatchNotifications() {}
}
#else
@MainActor
final class MatchNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MatchNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "stadiatv.match."

    private override init() {
        super.init()
        center.delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

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

        switch match.state {
        case .pre:
            await scheduleStartNotificationIfNeeded(for: match, leadTime: leadTime)
            return true
        case .live:
            await scheduleLiveNotificationIfNeeded(for: match)
            await scheduleCloseGameNotificationIfNeeded(for: match)
            return true
        case .final:
            return false
        }
    }

    func syncNotifications(matches: [Match], favorites: [FavoriteTeam], leadTime: MatchReminderLeadTime) async {
        guard !favorites.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let favoriteIDs = Set(favorites.map(\.id) + favorites.map(\.canonicalTeamID))
        let favoriteMatches = matches.filter { match in
            isFavorite(match.away, in: favoriteIDs, league: match.league) || isFavorite(match.home, in: favoriteIDs, league: match.league)
        }

        let identifiers = favoriteMatches.flatMap { match in
            [startIdentifier(for: match), liveIdentifier(for: match), closeGameIdentifier(for: match)]
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for match in favoriteMatches {
            await scheduleStartNotificationIfNeeded(for: match, leadTime: leadTime)
            await scheduleLiveNotificationIfNeeded(for: match)
            await scheduleCloseGameNotificationIfNeeded(for: match)
        }
    }

    func scheduleMorningDigest(matches: [Match]) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        center.removePendingNotificationRequests(withIdentifiers: ["stadiatv.morning.digest"])

        let calendar = Calendar.current
        let todayMatches = matches
            .filter { calendar.isDateInToday($0.date) && $0.state != .final }
            .sorted { $0.date < $1.date }

        guard !todayMatches.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Today in Sports"
        let names = todayMatches.prefix(3).map(\.shortName).joined(separator: "  ·  ")
        let count = todayMatches.count
        content.body = "\(count) game\(count == 1 ? "" : "s") today: \(names)"
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = 8
        dateComponents.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "stadiatv.morning.digest", content: content, trigger: trigger)
        try? await center.add(request)
    }

    func removeAllMatchNotifications() {
        center.getPendingNotificationRequests { [identifierPrefix] requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private func scheduleStartNotificationIfNeeded(for match: Match, leadTime: MatchReminderLeadTime) async {
        guard match.state == .pre else { return }
        let fireDate = match.date.addingTimeInterval(TimeInterval(-leadTime.minutes * 60))
        guard match.date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "It's game time in \(leadTime.minutes) minutes!!"
        content.body = "Don't forget to tune into StadiaTV to watch the action live!"
        content.sound = .default
        content.userInfo = [
            "matchID": match.id,
            "leagueID": match.league.id,
            "notificationType": "gameTimeReminder"
        ]

        if fireDate > Date() {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            await addRequest(identifier: startIdentifier(for: match), content: content, trigger: trigger)
        } else {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            await addRequest(identifier: startIdentifier(for: match), content: content, trigger: trigger)
        }
    }

    private func scheduleLiveNotificationIfNeeded(for match: Match) async {
        guard match.state == .live else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(match.away.shortName) vs \(match.home.shortName) is live"
        content.body = match.statusDetail
        content.sound = .default
        await addRequest(identifier: liveIdentifier(for: match), content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
    }

    private func scheduleCloseGameNotificationIfNeeded(for match: Match) async {
        guard match.state == .live, isCloseGame(match) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Close game: \(match.away.shortName) vs \(match.home.shortName)"
        content.body = "\(match.away.score ?? "-")-\(match.home.score ?? "-") · \(match.statusDetail)"
        content.sound = .default
        await addRequest(identifier: closeGameIdentifier(for: match), content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
    }

    private func addRequest(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger) async {
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func isFavorite(_ side: TeamSide, in favoriteIDs: Set<String>, league: League) -> Bool {
        if let teamID = side.teamID, favoriteIDs.contains("\(league.path)-\(teamID)") {
            return true
        }
        if let canonicalID = side.canonicalIDString, favoriteIDs.contains(canonicalID) {
            return true
        }
        return false
    }

    private func isCloseGame(_ match: Match) -> Bool {
        guard let away = Int(match.away.score ?? ""), let home = Int(match.home.score ?? "") else { return false }
        let spread = abs(away - home)
        switch match.league.group {
        case .football: return spread <= 8
        case .basketball: return spread <= 5
        case .baseball, .hockey, .soccer: return spread <= 1
        case .golf, .racing, .tennis, .cycling, .wrestling, .esports: return false
        }
    }

    private func startIdentifier(for match: Match) -> String { "\(identifierPrefix)start.\(match.id)" }
    private func liveIdentifier(for match: Match) -> String { "\(identifierPrefix)live.\(match.id)" }
    private func closeGameIdentifier(for match: Match) -> String { "\(identifierPrefix)close.\(match.id)" }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
#endif
