import Foundation
import SwiftUI
import Combine

// MARK: - Guide View Model

@MainActor
final class TVGuideViewModel: ObservableObject {

    @Published var selectedCategoryId: String = "featured"
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var categories: [GuideCategory] = []
    @Published var visibleChannels: [CanonicalChannel] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// Incremented by scrollToNow() so EPGGuideGrid can observe and react.
    @Published private(set) var scrollToNowToken: Int = 0

    private weak var repository: EPGRepository?
    private var refreshTimer: Timer?

    // Guide geometry constants (shared with UI)
    static let ptsPerMinute: CGFloat = 3.0
    static let channelColumnWidth: CGFloat = 80
    static let rowHeight: CGFloat = 72
    static let timeRulerHeight: CGFloat = 44
    static let minProgramWidth: CGFloat = 20

    // Guide window: show -3h to +21h from start of selected day
    var guideWindowStart: Date { selectedDate }
    var guideWindowEnd: Date { selectedDate.addingTimeInterval(24 * 3600) }
    var guideWindowWidth: CGFloat {
        CGFloat(guideWindowEnd.timeIntervalSince(guideWindowStart) / 60) * Self.ptsPerMinute
    }

    /// x offset (from guideWindowStart) for a given date
    func xOffset(for date: Date) -> CGFloat {
        let mins = date.timeIntervalSince(guideWindowStart) / 60
        return CGFloat(mins) * Self.ptsPerMinute
    }

    /// Width in points for a programme's duration
    func width(for programme: EPGProgramme) -> CGFloat {
        let mins = programme.end.timeIntervalSince(programme.start) / 60
        return max(Self.minProgramWidth, CGFloat(mins) * Self.ptsPerMinute)
    }

    // MARK: - Setup

    func setup(repository: EPGRepository) {
        self.repository = repository
        buildCategories(from: repository)
        filterChannels(repository: repository)
    }

    func update(repository: EPGRepository) {
        filterChannels(repository: repository)
    }

    private func buildCategories(from repository: EPGRepository) {
        guard let config = CuratedGuideConfig.load() else { return }

        var cats: [GuideCategory] = [
            GuideCategory(id: "featured", name: "Featured", sort: -10, isVirtual: true, isEnabled: true),
            GuideCategory(id: "all", name: "All Channels", sort: -5, isVirtual: true, isEnabled: true),
        ]

        for cat in config.categories.sorted(by: { $0.sort < $1.sort }) {
            cats.append(GuideCategory(
                id: cat.id,
                name: cat.name,
                sort: cat.sort,
                isVirtual: false,
                isEnabled: cat.defaultEnabled
            ))
        }

        categories = cats
    }

    private func filterChannels(repository: EPGRepository) {
        let all = repository.canonicalChannels
        switch selectedCategoryId {
        case "featured":
            visibleChannels = featuredChannels(from: all, repository: repository)
        case "all":
            visibleChannels = all
        default:
            visibleChannels = all.filter { $0.categoryId == selectedCategoryId }
        }
    }

    private func featuredChannels(from all: [CanonicalChannel], repository: EPGRepository) -> [CanonicalChannel] {
        let withEPG = all.filter { repository.hasProgrammes(for: $0.id) }
        let byPriority = withEPG.sorted { $0.priority > $1.priority }
        return Array(byPriority.prefix(40))
    }

    // MARK: - Category selection

    func selectCategory(_ id: String) {
        guard let repository else { return }
        selectedCategoryId = id
        filterChannels(repository: repository)
    }

    /// Resets the selected date to today and signals EPGGuideGrid to scroll to NOW.
    func scrollToNow() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        if let repository { filterChannels(repository: repository) }
        scrollToNowToken += 1
    }

    // MARK: - Programme queries

    func programmes(for channel: CanonicalChannel, in window: ClosedRange<Date>) -> [EPGProgramme] {
        repository?.programmes(for: channel.id, from: window.lowerBound, to: window.upperBound) ?? []
    }

    func currentProgramme(for channel: CanonicalChannel) -> EPGProgramme? {
        repository?.currentProgramme(for: channel.id)
    }

    func nextProgramme(for channel: CanonicalChannel) -> EPGProgramme? {
        repository?.nextProgramme(for: channel.id)
    }

    // MARK: - Time helpers

    /// Initial horizontal scroll offset to position current time ~20% from left
    var initialScrollOffset: CGFloat {
        let now = Date()
        guard now >= guideWindowStart, now <= guideWindowEnd else { return 0 }
        let nowX = xOffset(for: now)
        // Position now at 20% from left edge of visible area
        let screenWidth: CGFloat = UIScreen.main.bounds.width - Self.channelColumnWidth
        return max(0, nowX - screenWidth * 0.20)
    }

    /// Time labels for the ruler every 30 minutes
    func timeLabels(in range: ClosedRange<Date>) -> [(date: Date, label: String, x: CGFloat)] {
        var labels: [(date: Date, label: String, x: CGFloat)] = []
        let cal = Calendar.current
        var cur = cal.dateInterval(of: .hour, for: range.lowerBound)?.start ?? range.lowerBound

        // Round up to next 30-min mark
        let mins = cal.component(.minute, from: cur)
        if mins > 0 {
            cur = cur.addingTimeInterval(TimeInterval((60 - mins) * 60))
            if cal.component(.minute, from: cur) == 30 {
                // already on a 30-min mark
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = .current

        while cur <= range.upperBound {
            labels.append((date: cur, label: formatter.string(from: cur), x: xOffset(for: cur)))
            cur = cur.addingTimeInterval(1800)  // 30 min
        }
        return labels
    }

    // MARK: - Date navigation

    func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }

    var displayDate: String {
        if isToday(selectedDate) { return "Today" }
        let f = DateFormatter()
        f.dateFormat = "E, MMM d"
        return f.string(from: selectedDate)
    }

    var nowIsVisible: Bool {
        let now = Date()
        return now >= guideWindowStart && now <= guideWindowEnd
    }
}
