import Foundation
import Testing
@testable import BannerTV

@Suite("Guide day")
struct GuideDayTests {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("A day is 24 hours long, except across a clock change")
    func dayLengths() {
        let newYork = calendar("America/New_York")
        func hours(_ year: Int, _ month: Int, _ day: Int) -> Double {
            let start = date(year, month, day, in: newYork)
            return GuideDay.end(startingAt: start, calendar: newYork).timeIntervalSince(start) / 3600
        }
        #expect(hours(2026, 6, 15) == 24)
        #expect(hours(2026, 3, 8) == 23, "clocks go forward")
        #expect(hours(2026, 11, 1) == 25, "clocks go back")
    }

    @Test("The window ends at the next local midnight, so adding 24 hours would be wrong on a change day")
    func endIsNextMidnight() {
        let newYork = calendar("America/New_York")
        let start = date(2026, 11, 1, in: newYork)
        let end = GuideDay.end(startingAt: start, calendar: newYork)
        #expect(end == date(2026, 11, 2, in: newYork))
        #expect(end != start.addingTimeInterval(24 * 3600), "24 hours would stop an hour short of midnight")
    }

    @Test("After midnight the guide follows from the day that just ended, but not from a day the user chose")
    func followingMidnight() {
        let london = calendar("Europe/London")
        let yesterday = date(2026, 10, 3, in: london)
        let today = date(2026, 10, 4, in: london)
        #expect(GuideDay.followingMidnight(selected: yesterday, today: today, calendar: london) == today)
        #expect(GuideDay.followingMidnight(selected: today, today: today, calendar: london) == today)
        let chosen = date(2026, 10, 9, in: london)
        #expect(GuideDay.followingMidnight(selected: chosen, today: today, calendar: london) == chosen)
        let earlier = date(2026, 9, 28, in: london)
        #expect(GuideDay.followingMidnight(selected: earlier, today: today, calendar: london) == earlier)
    }

    @Test("Rolling over works across a clock change too")
    func followingMidnightAcrossDST() {
        let newYork = calendar("America/New_York")
        let saturday = date(2026, 3, 7, in: newYork)
        let sunday = date(2026, 3, 8, in: newYork)        // 23 hours long
        let monday = date(2026, 3, 9, in: newYork)
        #expect(GuideDay.followingMidnight(selected: saturday, today: sunday, calendar: newYork) == sunday)
        #expect(GuideDay.followingMidnight(selected: sunday, today: monday, calendar: newYork) == monday)
    }
}
