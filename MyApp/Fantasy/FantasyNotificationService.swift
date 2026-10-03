import Foundation
import UserNotifications

#if os(tvOS)
/// tvOS notifications support badges only, so Fantasy alerts are a no-op there (mirrors MatchNotificationService).
@MainActor
final class FantasyNotificationService {
    static let shared = FantasyNotificationService()

    private init() {}

    func requestAuthorization() async -> Bool { false }
    func syncTonightPlayers(_ games: [FantasyPlayerGame], leagueName: String) async {}
    func notifyInjuryChanges(roster: FantasyRoster, previousInjuryStatusByPlayerID: [String: String?], players: [FantasyPlayer], leagueName: String) async {}
    func removeAllFantasyNotifications() {}
}
#else
@MainActor
final class FantasyNotificationService {
    static let shared = FantasyNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "bannertv.fantasy."
    private let concerningInjuryStatuses: Set<String> = ["O", "OUT", "D", "DOUBTFUL", "IR", "IR-R"]

    private init() {}

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// One digest notification per day, ~30 minutes before the earliest upcoming starter's game.
    func syncTonightPlayers(_ games: [FantasyPlayerGame], leagueName: String) async {
        guard await isAuthorized() else { return }

        let identifier = "\(identifierPrefix)tonight.\(dayKey(for: Date()))"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let starters = games.filter { $0.isFantasyStarter && $0.gameState == .upcoming }
        guard !starters.isEmpty, let earliest = starters.compactMap(\.event?.date).min() else { return }
        let fireDate = earliest.addingTimeInterval(-30 * 60)
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Fantasy tonight"
        let names = starters.prefix(3).map(\.fantasyPlayer.fullName).joined(separator: ", ")
        let count = starters.count
        content.body = "\(count) of your \(leagueName) starter\(count == 1 ? "" : "s") play\(count == 1 ? "s" : "") tonight: \(names)"
        content.sound = .default
        content.userInfo = ["notificationType": "fantasyTonight"]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    /// Fires an immediate alert for each starter whose injury status newly became concerning
    /// between the previous and current refresh. De-duplicated by player+status identifier.
    func notifyInjuryChanges(roster: FantasyRoster, previousInjuryStatusByPlayerID: [String: String?], players: [FantasyPlayer], leagueName: String) async {
        guard await isAuthorized() else { return }

        let playersByID = Dictionary(uniqueKeysWithValues: players.map { ($0.id, $0) })
        for slot in roster.starters {
            guard let player = playersByID[slot.playerID] else { continue }
            let newStatus = player.injuryStatus?.uppercased()
            let oldStatus = (previousInjuryStatusByPlayerID[slot.playerID] ?? nil)?.uppercased()
            guard let newStatus, newStatus != oldStatus, concerningInjuryStatuses.contains(newStatus) else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Fantasy injury alert"
            content.body = "\(player.fullName) has been listed as \(player.injuryStatus ?? newStatus) in \(leagueName)."
            content.sound = .default
            content.userInfo = ["notificationType": "fantasyInjury", "playerID": slot.playerID]

            let identifier = "\(identifierPrefix)injury.\(slot.playerID).\(newStatus)"
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }

    func removeAllFantasyNotifications() {
        center.getPendingNotificationRequests { [identifierPrefix] requests in
            let identifiers = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
#endif
