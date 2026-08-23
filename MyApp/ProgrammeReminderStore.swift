import Foundation
import Combine
import UserNotifications

// MARK: - Reminder model

struct ProgrammeReminder: Codable, Identifiable, Hashable {
    let id: String              // UNNotificationRequest identifier
    let channelID: String
    let channelName: String
    let programmeTitle: String
    let programmeStart: Date
    let programmeEnd: Date
    var leadTimeMinutes: Int
    var scheduledAt: Date
}

// MARK: - tvOS stub

#if os(tvOS)
@MainActor
final class ProgrammeReminderStore: ObservableObject {
    static let shared = ProgrammeReminderStore()
    private init() {}

    @Published private(set) var reminders: [ProgrammeReminder] = []

    func hasReminder(for programme: EPGProgramme) -> Bool { false }
    func reminderID(for programme: EPGProgramme) -> String? { nil }
    func addReminder(for programme: EPGProgramme, channel: CanonicalChannel, leadTimeMinutes: Int = 5) async -> Bool { false }
    func removeReminder(id: String) {}
    func syncAfterEPGRefresh(_ updated: [EPGProgramme]) {}
}

// MARK: - iOS / macOS implementation

#else
@MainActor
final class ProgrammeReminderStore: ObservableObject {
    static let shared = ProgrammeReminderStore()

    @Published private(set) var reminders: [ProgrammeReminder] = []

    private let center = UNUserNotificationCenter.current()
    private let storeKey = "stadiatv.programme.reminders.v1"
    private let idPrefix = "stadiatv.prog."

    private init() {
        load()
        pruneExpired()
    }

    // MARK: - Query

    func hasReminder(for programme: EPGProgramme) -> Bool {
        reminders.contains { $0.id == notificationID(for: programme) }
    }

    func reminderID(for programme: EPGProgramme) -> String? {
        hasReminder(for: programme) ? notificationID(for: programme) : nil
    }

    // MARK: - Add

    /// Schedules a UNNotificationRequest and persists the reminder.
    /// Returns true if the notification was successfully scheduled.
    func addReminder(
        for programme: EPGProgramme,
        channel: CanonicalChannel,
        leadTimeMinutes: Int = 5
    ) async -> Bool {
        let authorized = await ensureAuthorized()
        guard authorized else { return false }

        let fireDate = programme.start.addingTimeInterval(-TimeInterval(leadTimeMinutes * 60))
        guard fireDate > Date() else { return false }

        let content = UNMutableNotificationContent()
        content.title = programme.title
        content.body = "\(channel.name) · starts in \(leadTimeMinutes == 1 ? "1 minute" : "\(leadTimeMinutes) minutes")"
        content.sound = .default
        content.userInfo = [
            "stadiatv_type":    "programme_reminder",
            "channelID":        channel.id,
            "programmeTitle":   programme.title,
            "programmeStart":   programme.start.timeIntervalSince1970
        ]

        let id = notificationID(for: programme)
        let dateComps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            return false
        }

        let reminder = ProgrammeReminder(
            id: id,
            channelID: channel.id,
            channelName: channel.name,
            programmeTitle: programme.title,
            programmeStart: programme.start,
            programmeEnd: programme.end,
            leadTimeMinutes: leadTimeMinutes,
            scheduledAt: Date()
        )
        reminders.removeAll { $0.id == id }
        reminders.append(reminder)
        save()
        return true
    }

    // MARK: - Remove

    func removeReminder(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        reminders.removeAll { $0.id == id }
        save()
    }

    // MARK: - EPG sync

    /// Call after an EPG refresh to reschedule/cancel reminders whose times shifted.
    /// Programmes that no longer appear in the guide are cancelled silently.
    func syncAfterEPGRefresh(_ updated: [EPGProgramme]) {
        let progsByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        var toCancel: [String] = []

        for reminder in reminders {
            let progID = programmeIDFromNotification(id: reminder.id)
            guard let refreshed = progsByID[progID] else {
                toCancel.append(reminder.id)
                continue
            }
            // If start shifted by more than 1 minute, the old notification fires at the wrong time.
            if abs(refreshed.start.timeIntervalSince(reminder.programmeStart)) > 60 {
                toCancel.append(reminder.id)
            }
        }

        if !toCancel.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toCancel)
            reminders.removeAll { toCancel.contains($0.id) }
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([ProgrammeReminder].self, from: data) else { return }
        reminders = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func pruneExpired() {
        let now = Date()
        let before = reminders.count
        reminders.removeAll { $0.programmeEnd < now }
        if reminders.count != before { save() }
    }

    // MARK: - Authorization

    private func ensureAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    // MARK: - ID helpers

    private func notificationID(for programme: EPGProgramme) -> String {
        "\(idPrefix)\(programme.id)"
    }

    private func programmeIDFromNotification(id: String) -> String {
        String(id.dropFirst(idPrefix.count))
    }
}
#endif
