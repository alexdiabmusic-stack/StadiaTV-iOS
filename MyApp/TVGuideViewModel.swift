import Foundation
import SwiftUI
import Combine

// MARK: - Guide View Model

@MainActor
final class TVGuideViewModel: ObservableObject {

    @Published var guideMode: GuideMode = .myGuide
    @Published var filterCategoryId: String? = nil     // active category filter in All Channels mode
    @Published var channelNameFilter: String = ""      // text search across channel names
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var categories: [GuideCategory] = []
    @Published var visibleChannels: [CanonicalChannel] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    /// Incremented by scrollToNow() so EPGGuideGrid can observe and react.
    @Published private(set) var scrollToNowToken: Int = 0

    private weak var repository: EPGRepository?
    private var guideStore: GuideChannelStore?
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
        guideStore = store
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

    func setChannelNameFilter(_ text: String) {
        channelNameFilter = text
        if let repository { filterChannels(repository: repository) }
    }

    private func filterChannels(repository: EPGRepository) {
        let all = repository.canonicalChannels
        var result: [CanonicalChannel]
        switch guideMode {
        case .myGuide:
            if myGuideIDs.isEmpty {
                result = featuredChannels(from: all, repository: repository)
            } else {
                result = all.filter { myGuideIDs.contains($0.id) }
                    .sorted { $0.priority > $1.priority }
            }
        case .allChannels:
            if let catId = filterCategoryId {
                result = all.filter { $0.categoryId == catId }
            } else {
                result = all
            }
        }
        if !channelNameFilter.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(channelNameFilter) }
        }
        visibleChannels = result
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

    // MARK: - EPG Offset

    /// Per-channel EPG offset in minutes stored in GuideChannelStore (keyed by canonical channel ID).
    func epgOffsetMinutes(for channel: CanonicalChannel) -> Int {
        guideStore?.epgOffset(for: channel.id) ?? 0
    }

    // MARK: - Programme queries

    /// Returns programmes for the given channel adjusted by any user-configured EPG offset.
    func programmes(for channel: CanonicalChannel, in window: ClosedRange<Date>) -> [EPGProgramme] {
        let offsetMinutes = epgOffsetMinutes(for: channel)
        let offsetInterval = TimeInterval(offsetMinutes * 60)
        // Invert the offset when querying: if the stream is 30m ahead, look at EPG 30m earlier.
        let adjustedFrom = window.lowerBound.addingTimeInterval(-offsetInterval)
        let adjustedTo   = window.upperBound.addingTimeInterval(-offsetInterval)
        let progs = repository?.programmes(for: channel.id, from: adjustedFrom, to: adjustedTo) ?? []
        guard offsetMinutes != 0 else { return progs }
        return progs.map { $0.shifted(by: offsetMinutes) }
    }

    // MARK: - Row layout cache

    /// One programme cell (or gap) positioned within a guide row.
    struct GuideCellLayout: Identifiable {
        let id: String
        let programme: EPGProgramme?
        let x: CGFloat
        let width: CGFloat
    }

    struct GuideRowLayout {
        let cells: [GuideCellLayout]
        var isEmpty: Bool { !cells.contains { $0.programme != nil } }
    }

    private struct RowLayoutKey: Equatable {
        let date: Date
        let offset: Int
        let revision: Int
    }
    private var rowLayoutCache: [String: (key: RowLayoutKey, layout: GuideRowLayout)] = [:]

    /// Cell positions for a channel's row, cached until the day, EPG offset or guide data changes,
    /// so scrolling and re-rendering don't redo the date maths for every cell.
    func rowLayout(for channel: CanonicalChannel) -> GuideRowLayout {
        let key = RowLayoutKey(date: selectedDate, offset: epgOffsetMinutes(for: channel),
                               revision: repository?.programmeRevision ?? 0)
        if let cached = rowLayoutCache[channel.id], cached.key == key { return cached.layout }

        let progs = programmes(for: channel, in: guideWindowStart...guideWindowEnd)
        var cells: [GuideCellLayout] = []
        cells.reserveCapacity(progs.count * 2)
        func addGap(_ from: Date, _ to: Date) {
            let width = CGFloat(to.timeIntervalSince(from) / 60) * Self.ptsPerMinute
            guard width > 4 else { return }
            cells.append(GuideCellLayout(id: "gap-\(from.timeIntervalSince1970)", programme: nil,
                                         x: xOffset(for: from) + 1, width: width - 2))
        }
        if let first = progs.first, first.start > guideWindowStart { addGap(guideWindowStart, first.start) }
        for (index, prog) in progs.enumerated() {
            cells.append(GuideCellLayout(id: prog.id, programme: prog, x: xOffset(for: prog.start), width: width(for: prog)))
            if index + 1 < progs.count, progs[index + 1].start > prog.end + 30 {
                addGap(prog.end, progs[index + 1].start)
            }
        }
        if let last = progs.last, last.end < guideWindowEnd { addGap(last.end, guideWindowEnd) }

        let layout = GuideRowLayout(cells: cells)
        if rowLayoutCache.count > 2_000 { rowLayoutCache.removeAll(keepingCapacity: true) }
        rowLayoutCache[channel.id] = (key, layout)
        return layout
    }

    // MARK: - Fantasy indicator cache

    private var fantasyIndicatorCache: [String: Int] = [:]
    private var fantasyIndicatorRevision = -1

    /// Fantasy badge count for a programme, computed once per programme per fantasy-data change.
    func fantasyIndicatorCount(for programme: EPGProgramme, channel: CanonicalChannel,
                               revision: Int, compute: () -> Int) -> Int {
        if revision != fantasyIndicatorRevision {
            fantasyIndicatorCache.removeAll(keepingCapacity: true)
            fantasyIndicatorRevision = revision
        }
        let key = "\(channel.id)|\(programme.id)"
        if let cached = fantasyIndicatorCache[key] { return cached }
        let value = compute()
        fantasyIndicatorCache[key] = value
        return value
    }

    // MARK: - Prefetch throttle

    private var lastPrefetchRow = -1
    private var lastPrefetchAt = Date.distantPast

    /// Called on scroll; prefetches at most every 250 ms and only when the first visible row changes.
    func scrolledTo(firstRow: Int, visibleRowCount: Int) {
        let now = Date()
        guard firstRow != lastPrefetchRow, now.timeIntervalSince(lastPrefetchAt) >= 0.25 else { return }
        lastPrefetchRow = firstRow
        lastPrefetchAt = now
        prefetchProgrammesAround(rowIndex: firstRow, visibleRowCount: visibleRowCount)
    }

    func currentProgramme(for channel: CanonicalChannel) -> EPGProgramme? {
        let offsetMinutes = epgOffsetMinutes(for: channel)
        let adjustedNow = Date().addingTimeInterval(-TimeInterval(offsetMinutes * 60))
        guard let prog = repository?.currentProgramme(for: channel.id, at: adjustedNow) else { return nil }
        return offsetMinutes != 0 ? prog.shifted(by: offsetMinutes) : prog
    }

    func nextProgramme(for channel: CanonicalChannel) -> EPGProgramme? {
        let offsetMinutes = epgOffsetMinutes(for: channel)
        let adjustedNow = Date().addingTimeInterval(-TimeInterval(offsetMinutes * 60))
        guard let prog = repository?.nextProgramme(for: channel.id, after: adjustedNow) else { return nil }
        return offsetMinutes != 0 ? prog.shifted(by: offsetMinutes) : prog
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
