import Foundation
import SwiftUI
import Combine

// MARK: - Guide View Model

@MainActor
final class TVGuideViewModel: ObservableObject {

    @Published var guideMode: GuideMode = .myGuide
    @Published var filterCategoryId: String? = nil     // active category filter in All Channels mode
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var categories: [GuideCategory] = []
    @Published var visibleChannels: [CanonicalChannel] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// Incremented by scrollToNow() so EPGGuideGrid can observe and react.
    @Published private(set) var scrollToNowToken: Int = 0

    private weak var repository: EPGRepository?
    private var myGuideIDs: Set<String> = []

    // Guide geometry constants (shared with UI)
    static let ptsPerMinute: CGFloat = 3.0
    static let channelColumnWidth: CGFloat = 80
    static let rowHeight: CGFloat = 72
    static let timeRulerHeight: CGFloat = 44
    static let minProgramWidth: CGFloat = 20

    // Reused formatter — creating DateFormatter is expensive.
    nonisolated private static let rulerFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.timeZone = .current
        return f
    }()

    // Guide window: full selected day
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
        prefetchVisibleProgrammes(repository: repository)
    }

    func update(repository: EPGRepository) {
        filterChannels(repository: repository)
        prefetchVisibleProgrammes(repository: repository)
    }

    /// Applies guide mode and channel selections from the GuideChannelStore.
    func applyGuideStore(_ store: GuideChannelStore, repository: EPGRepository) {
        guideMode = store.guideMode
        myGuideIDs = store.selectedChannelIDs
        filterChannels(repository: repository)
        prefetchVisibleProgrammes(repository: repository)
    }

    private func buildCategories(from repository: EPGRepository) {
        guard let config = CuratedGuideConfig.load() else { return }

        var cats: [GuideCategory] = [
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
        switch guideMode {
        case .myGuide:
            if myGuideIDs.isEmpty {
                // Nothing selected yet — show top-priority channels as a preview.
                visibleChannels = featuredChannels(from: all, repository: repository)
            } else {
                visibleChannels = all.filter { myGuideIDs.contains($0.id) }
                    .sorted { $0.priority > $1.priority }
            }
        case .allChannels:
            if let catId = filterCategoryId {
                visibleChannels = all.filter { $0.categoryId == catId }
            } else {
                visibleChannels = all
            }
        }
    }

    private func featuredChannels(from all: [CanonicalChannel], repository: EPGRepository) -> [CanonicalChannel] {
        Array(all.sorted { $0.priority > $1.priority }.prefix(80))
    }

    private func prefetchVisibleProgrammes(repository: EPGRepository) {
        prefetchProgrammes(in: 0..<min(30, visibleChannels.count), repository: repository)
    }

    func prefetchProgrammesAround(rowIndex: Int, visibleRowCount: Int) {
        guard let repository else { return }
        let start = max(0, rowIndex - 8)
        let end = min(visibleChannels.count, rowIndex + visibleRowCount + 16)
        guard start < end else { return }
        prefetchProgrammes(in: start..<end, repository: repository)
    }

    private func prefetchProgrammes(in range: Range<Int>, repository: EPGRepository) {
        repository.prefetchProgrammes(for: Array(visibleChannels[range]))
    }

    // MARK: - Filter controls

    func setFilterCategory(_ catId: String?) {
        filterCategoryId = catId
        if let repository { filterChannels(repository: repository) }
    }

    func setGuideMode(_ mode: GuideMode, store: GuideChannelStore) {
        store.setGuideMode(mode)
        guideMode = mode
        if let repository {
            filterChannels(repository: repository)
            prefetchVisibleProgrammes(repository: repository)
        }
    }

    /// Resets the selected date to today and signals EPGGuideGrid to scroll to NOW.
    func scrollToNow() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        if let repository {
            filterChannels(repository: repository)
            prefetchVisibleProgrammes(repository: repository)
        }
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
        let screenWidth: CGFloat = UIScreen.main.bounds.width - Self.channelColumnWidth
        return max(0, nowX - screenWidth * 0.20)
    }

    /// Time labels for the ruler every 30 minutes
    func timeLabels(in range: ClosedRange<Date>) -> [(date: Date, label: String, x: CGFloat)] {
        var labels: [(date: Date, label: String, x: CGFloat)] = []
        let cal = Calendar.current
        var cur = cal.dateInterval(of: .hour, for: range.lowerBound)?.start ?? range.lowerBound

        let mins = cal.component(.minute, from: cur)
        if mins > 0 {
            cur = cur.addingTimeInterval(TimeInterval((60 - mins) * 60))
        }

        while cur <= range.upperBound {
            labels.append((date: cur, label: Self.rulerFmt.string(from: cur), x: xOffset(for: cur)))
            cur = cur.addingTimeInterval(1800)
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
