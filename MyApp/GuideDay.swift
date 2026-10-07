import Foundation

/// The day the guide shows. A calendar day isn't always 24 hours long: on the two days a year the
/// clocks change it is 23 or 25, so adding 24 hours to its start misses the last hour of the long
/// day and spills into the next one on the short day.
nonisolated enum GuideDay {

    /// Midnight at the end of the day that begins at `start`.
    static func end(startingAt start: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * 3600)
    }

    /// The day to show once the calendar has reached `today` (the start of the current day).
    /// A guide that was showing the day that just ended follows to the new one; one the user
    /// had moved to another day stays where it is.
    static func followingMidnight(selected: Date, today: Date, calendar: Calendar = .current) -> Date {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today), selected == yesterday else { return selected }
        return today
    }
}
