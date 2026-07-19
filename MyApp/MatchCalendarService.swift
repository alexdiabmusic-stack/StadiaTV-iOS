import EventKit
import Foundation

@MainActor
final class MatchCalendarService {
    static let shared = MatchCalendarService()

    private let eventStore = EKEventStore()

    private init() {}

    func add(matches: [Match]) async throws -> Int {
        guard try await requestWriteAccess() else { throw CalendarError.accessDenied }
        guard let calendar = eventStore.defaultCalendarForNewEvents else { throw CalendarError.noWritableCalendar }

        var savedCount = 0
        for match in matches where match.state == .pre && match.date > Date() {
            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = "\(match.away.shortName) vs \(match.home.shortName)"
            event.startDate = match.date
            event.endDate = match.date.addingTimeInterval(defaultDuration(for: match))
            event.location = match.venue
            event.notes = notes(for: match)
            event.availability = .free
            event.addAlarm(EKAlarm(relativeOffset: -15 * 60))
            try eventStore.save(event, span: .thisEvent, commit: false)
            savedCount += 1
        }

        if savedCount > 0 {
            try eventStore.commit()
        }
        return savedCount
    }

    private func requestWriteAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return true
        case .notDetermined:
            return try await eventStore.requestWriteOnlyAccessToEvents()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func defaultDuration(for match: Match) -> TimeInterval {
        switch match.league.group {
        case .baseball: return 3.5 * 60 * 60
        case .football: return 3.25 * 60 * 60
        case .basketball, .hockey, .soccer: return 2.5 * 60 * 60
        }
    }

    private func notes(for match: Match) -> String {
        var lines = [match.league.name, match.statusDetail]
        if !match.broadcasts.isEmpty {
            lines.append("Broadcast: \(match.broadcasts.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    enum CalendarError: LocalizedError {
        case accessDenied
        case noWritableCalendar

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Calendar access was not granted."
            case .noWritableCalendar: return "No writable calendar is available."
            }
        }
    }
}
