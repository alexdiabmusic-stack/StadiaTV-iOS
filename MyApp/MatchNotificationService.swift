import Foundation
import UserNotifications

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

    func syncNotifications(matches: [Match], favorites: [FavoriteTeam], leadTime: MatchReminderLeadTime) async {
        guard !favorites.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let favoriteIDs = Set(favorites.map(\.id))
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

    func removeAllMatchNotifications() {
        center.getPendingNotificationRequests { [identifierPrefix] requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private func scheduleStartNotificationIfNeeded(for match: Match, leadTime: MatchReminderLeadTime) async {
        guard match.state == .pre else { return }
        let fireDate = match.date.addingTimeInterval(TimeInterval(-leadTime.minutes * 60))
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "It's game time in \(leadTime.minutes) minutes!!"
        content.body = "Don't forget to tune into StadiaTV to watch the action live!"
        content.sound = .default
        content.userInfo = [
            "matchID": match.id,
            "leagueID": match.league.id,
            "notificationType": "gameTimeReminder"
        ]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        await addRequest(identifier: startIdentifier(for: match), content: content, trigger: trigger)
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
        guard let teamID = side.teamID else { return false }
        return favoriteIDs.contains("\(league.path)-\(teamID)")
    }

    private func isCloseGame(_ match: Match) -> Bool {
        guard let away = Int(match.away.score ?? ""), let home = Int(match.home.score ?? "") else { return false }
        let spread = abs(away - home)
        switch match.league.group {
        case .football: return spread <= 8
        case .basketball: return spread <= 5
        case .baseball, .hockey, .soccer: return spread <= 1
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
