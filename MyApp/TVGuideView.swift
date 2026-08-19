import SwiftUI
import Combine

// MARK: - TVGuideView

/// Top-level container for the Live TV Guide / EPG feature.
struct TVGuideView: View {
    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var watchStore: WatchStore
    @StateObject private var vm = TVGuideViewModel()
    @State private var playingChannel: CanonicalChannel?
    @State private var selectedProgramme: EPGProgramme?
    @State private var selectedProgrammeChannel: CanonicalChannel?

    var body: some View {
        Group {
            if repository.canonicalChannels.isEmpty {
                emptyState
            } else {
                guideContent
            }
        }
        .fullScreenCover(item: $playingChannel) { ch in
            PlayerView(canonicalChannel: ch)
        }
        .sheet(item: $selectedProgramme) { prog in
            if let ch = selectedProgrammeChannel {
                ProgrammeDetailSheet(programme: prog, channel: ch) {
                    if ch.playableChannel != nil {
                        playingChannel = ch
                    }
                }
            }
        }
        .onAppear {
            vm.setup(repository: repository)
        }
        .onChange(of: repository.canonicalChannels.count) {
            vm.update(repository: repository)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if repository.refreshState == .refreshing {
                ProgressView().tint(Theme.accent)
                Text("Building your channel guide…").foregroundStyle(Theme.textSecondary)
                    .font(.callout)
            } else {
                Image(systemName: "tv.slash").font(.system(size: 44)).foregroundStyle(Theme.textSecondary)
                Text("No Guide Available").font(.headline).foregroundStyle(Theme.textPrimary)
                Text("Add an IPTV playlist in Settings to see a TV guide.")
                    .font(.callout).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideContent: some View {
        VStack(spacing: 0) {
            categoryBar
            Divider().overlay(Theme.hairline)
            EPGGuideGrid(vm: vm) { channel in
                // Channel logo tapped → play
                if let ch = channel.playableChannel {
                    watchStore.recordWatch(ch)
                    playingChannel = channel
                }
            } onProgramTap: { programme, channel in
                if programme.isOnNow() {
                    // Current program → play
                    if let ch = channel.playableChannel {
                        watchStore.recordWatch(ch)
                        playingChannel = channel
                    }
                } else {
                    // Future program → show details
                    selectedProgramme = programme
                    selectedProgrammeChannel = channel
                }
            }
        }
    }

    // MARK: - Category bar

    private var categoryBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.categories) { cat in
                        categoryChip(cat)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                vm.scrollToNow()
            } label: {
                Text("Now")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.live)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.live.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .background(Theme.background)
    }

    private func categoryChip(_ cat: GuideCategory) -> some View {
        let isSelected = cat.id == vm.selectedCategoryId
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy) { vm.selectCategory(cat.id) }
        } label: {
            Text(cat.name)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isSelected ? Theme.accent : Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EPG Guide Grid

struct EPGGuideGrid: View {
    @ObservedObject var vm: TVGuideViewModel
    @EnvironmentObject private var repository: EPGRepository
    let onChannelTap: (CanonicalChannel) -> Void
    let onProgramTap: (EPGProgramme, CanonicalChannel) -> Void

    @State private var scrollOffset: CGPoint = .zero
    @State private var scrollPos = ScrollPosition(x: 0, y: 0)
    @State private var viewSize: CGSize = .zero
    @State private var bottomInset: CGFloat = 0
    @State private var hasScrolledToNow = false
    @State private var now: Date = Date()

    private let rowH = TVGuideViewModel.rowHeight
    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                mainScrollView
                channelColumnOverlay
                timeRulerOverlay
                cornerOverlay
                nowLineOverlay
            }
            .onAppear {
                viewSize = geo.size
                bottomInset = geo.safeAreaInsets.bottom
                triggerScrollToNow()
            }
            .onChange(of: geo.size) { _, size in
                viewSize = size
                triggerScrollToNow()
            }
            .onChange(of: vm.visibleChannels.count) { _, _ in
                triggerScrollToNow()
            }
            .onChange(of: vm.scrollToNowToken) { _, _ in
                scrollPos = ScrollPosition(x: vm.initialScrollOffset, y: 0)
            }
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { _ in now = Date() }
    }

    private func triggerScrollToNow() {
        guard !hasScrolledToNow,
              !vm.visibleChannels.isEmpty,
              viewSize.width > 0 else { return }
        hasScrolledToNow = true
        let targetX = vm.initialScrollOffset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            scrollPos = ScrollPosition(x: targetX, y: 0)
        }
    }

    // MARK: - Main 2-D scroll view

    private var mainScrollView: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Content size driver
                Color.clear
                    .frame(
                        width: colW + vm.guideWindowWidth,
                        height: rulerH + CGFloat(vm.visibleChannels.count) * rowH
                    )

                // Row dividers
                ForEach(Array(vm.visibleChannels.enumerated()), id: \.element.id) { i, _ in
                    Divider().overlay(Theme.hairline)
                        .frame(width: colW + vm.guideWindowWidth)
                        .offset(x: 0, y: rulerH + CGFloat(i) * rowH)
                }

                // Programme cells per channel
                ForEach(Array(visibleChannels.enumerated()), id: \.element.id) { i, ch in
                    let rowY = rulerH + CGFloat(i) * rowH
                    programCells(for: ch, rowIndex: i, rowY: rowY)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($scrollPos)
        .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
            scrollOffset = offset
        }
        .contentMargins(.bottom, bottomInset + 16, for: .scrollContent)
    }

    // MARK: - Programme cells for one channel row

    @ViewBuilder
    private func programCells(for channel: CanonicalChannel, rowIndex: Int, rowY: CGFloat) -> some View {
        let window = vm.guideWindowStart...vm.guideWindowEnd
        let progs = vm.programmes(for: channel, in: window)
        if progs.isEmpty {
            if repository.refreshState == .refreshing {
                // EPG still loading — subtle skeleton
                Rectangle()
                    .fill(Theme.surface.opacity(0.35))
                    .frame(width: max(120, vm.guideWindowWidth), height: rowH - 2)
                    .offset(x: colW, y: rowY + 1)
            } else {
                noEPGCell(channel: channel, rowY: rowY)
            }
        } else {
            ForEach(progs) { prog in
                let x = colW + vm.xOffset(for: prog.start)
                let w = vm.width(for: prog)
                ProgrammeCell(programme: prog, width: w, now: now) {
                    onProgramTap(prog, channel)
                }
                .frame(width: w, height: rowH - 2)
                .offset(x: x, y: rowY + 1)
            }
            gapCells(progs: progs, rowY: rowY)
        }
    }

    @ViewBuilder
    private func noEPGCell(channel: CanonicalChannel, rowY: CGFloat) -> some View {
        Text("No guide data")
            .font(.caption).foregroundStyle(Theme.textTertiary)
            .frame(width: max(120, vm.guideWindowWidth), height: rowH - 2, alignment: .leading)
            .padding(.leading, 12)
            .offset(x: colW, y: rowY + 1)
    }

    private func computeGaps(progs: [EPGProgramme]) -> [(Date, Date)] {
        var gaps: [(Date, Date)] = []
        let start = vm.guideWindowStart
        let end = vm.guideWindowEnd
        if let first = progs.first, first.start > start { gaps.append((start, first.start)) }
        for i in 0..<progs.count - 1 {
            let gapStart = progs[i].end
            let gapEnd = progs[i + 1].start
            if gapEnd > gapStart + 30 { gaps.append((gapStart, gapEnd)) }
        }
        if let last = progs.last, last.end < end { gaps.append((last.end, end)) }
        return gaps
    }

    @ViewBuilder
    private func gapCells(progs: [EPGProgramme], rowY: CGFloat) -> some View {
        let gaps = computeGaps(progs: progs)
        ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
            let x = colW + vm.xOffset(for: gap.0)
            let w = CGFloat(gap.1.timeIntervalSince(gap.0) / 60) * TVGuideViewModel.ptsPerMinute
            if w > 4 {
                Rectangle()
                    .fill(Theme.surface.opacity(0.6))
                    .frame(width: w - 2, height: rowH - 2)
                    .offset(x: x + 1, y: rowY + 1)
            }
        }
    }

    // MARK: - Fixed overlays

    /// Channel column: pinned at x=0, scrolls vertically in sync with the content.
    private var channelColumnOverlay: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleChannels.enumerated()), id: \.element.id) { _, ch in
                ChannelLogoCell(channel: ch) { onChannelTap(ch) }
                    .frame(width: colW, height: rowH)
                Divider().overlay(Theme.hairline)
            }
        }
        .frame(width: colW)
        .background(Theme.background)
        // When scrollOffset.y == 0 the column starts at y=rulerH (below the ruler).
        // As the user scrolls down scrollOffset.y grows and the column moves up in sync.
        .offset(x: 0, y: rulerH - scrollOffset.y)
    }

    /// Time ruler: pinned at y=0, labels positioned at their absolute timeline x minus current scroll offset.
    private var timeRulerOverlay: some View {
        ZStack(alignment: .topLeading) {
            Theme.background
            ForEach(timeLabels, id: \.0.timeIntervalSince1970) { _, label, x in
                let screenX = colW + x - scrollOffset.x
                // Only render labels whose left edge is inside (or just entering) the viewport
                if screenX < viewSize.width + 4 {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                        .frame(height: rulerH, alignment: .center)
                        .offset(x: screenX)
                }
            }
        }
        .frame(height: rulerH)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
        .clipped()
        .allowsHitTesting(false) // let scroll gesture pass through to mainScrollView
        // No y offset — stays fixed at y=0 in the outer ZStack
    }

    /// Corner CH cell: pinned at (0,0), covers the top-left intersection.
    private var cornerOverlay: some View {
        ZStack {
            Theme.background
            Text("CH")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: colW, height: rulerH)
        .allowsHitTesting(false)
        // No offset — stays at (0,0) in the outer ZStack
    }

    /// NOW line: vertical indicator for current time, rendered only for today.
    private var nowLineOverlay: some View {
        Group {
            if vm.nowIsVisible {
                let nowX = colW + vm.xOffset(for: now) - scrollOffset.x
                if nowX >= colW && nowX <= viewSize.width {
                    let lineH = CGFloat(vm.visibleChannels.count) * rowH
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Theme.live)
                            .frame(width: 2, height: max(0, lineH))
                        Circle()
                            .fill(Theme.live)
                            .frame(width: 8, height: 8)
                            .offset(y: -4)
                    }
                    .frame(width: 2)
                    // Start the line at the bottom edge of the time ruler
                    .offset(x: nowX, y: rulerH)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Helpers

    private var visibleChannels: [CanonicalChannel] { vm.visibleChannels }

    private var timeLabels: [(Date, String, CGFloat)] {
        let window = vm.guideWindowStart...vm.guideWindowEnd
        return vm.timeLabels(in: window).map { ($0.date, $0.label, $0.x) }
    }
}

// MARK: - Programme Cell

struct ProgrammeCell: View {
    let programme: EPGProgramme
    let width: CGFloat
    let now: Date
    let onTap: () -> Void

    private var isCurrent: Bool { programme.isOnNow(at: now) }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Theme.accent.opacity(0.18) : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isCurrent ? Theme.accent.opacity(0.4) : Theme.hairline)
                    )

                if isCurrent {
                    GeometryReader { g in
                        Rectangle()
                            .fill(Theme.accent.opacity(0.15))
                            .frame(width: g.size.width * programme.progress(at: now))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(programme.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if width > 90 {
                        Text(timeSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(isCurrent ? Theme.accent : Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var timeSubtitle: String {
        if isCurrent {
            let mins = programme.minutesRemaining(from: now)
            if mins < 60 { return "\(mins)m left" }
            return "\(mins / 60)h \(mins % 60)m left"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm a"
            return "\(fmt.string(from: programme.start)) – \(fmt.string(from: programme.end))"
        }
    }

    private var accessibilityLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        if isCurrent {
            let mins = programme.minutesRemaining(from: now)
            return "\(programme.title), \(fmt.string(from: programme.start)) to \(fmt.string(from: programme.end)), now playing, \(mins) minutes remaining."
        }
        return "\(programme.title), \(fmt.string(from: programme.start)) to \(fmt.string(from: programme.end))."
    }
}

// MARK: - Channel Logo Cell

struct ChannelLogoCell: View {
    let channel: CanonicalChannel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                if let logoURL = channel.effectiveLogoURL {
                    AsyncImage(url: logoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFit()
                        } else {
                            channelInitials
                        }
                    }
                    .frame(width: 44, height: 28)
                } else {
                    channelInitials
                        .frame(width: 44, height: 28)
                }
                Text(channel.name)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: TVGuideViewModel.channelColumnWidth - 8)
            }
            .frame(width: TVGuideViewModel.channelColumnWidth, height: TVGuideViewModel.rowHeight)
        }
        .buttonStyle(.plain)
    }

    private var channelInitials: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceElevated)
            Text(initials).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
        }
    }

    private var initials: String {
        let words = channel.name.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}

// MARK: - Programme Detail Sheet

struct ProgrammeDetailSheet: View {
    let programme: EPGProgramme
    let channel: CanonicalChannel
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Channel info
                        HStack(spacing: 12) {
                            if let logoURL = channel.effectiveLogoURL {
                                AsyncImage(url: logoURL) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "tv").foregroundStyle(Theme.accent)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(channel.name)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textPrimary)
                                Text(timeRange)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }

                        // Programme art if available
                        if let imgURL = programme.imageURL {
                            AsyncImage(url: imgURL) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill()
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 180)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                        }

                        // Title
                        VStack(alignment: .leading, spacing: 6) {
                            Text(programme.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            if let sub = programme.subtitle {
                                Text(sub)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            HStack(spacing: 12) {
                                if let s = programme.season, let e = programme.episode {
                                    Label("S\(s)E\(e)", systemImage: "list.number")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                if let rating = programme.rating {
                                    Text(rating)
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                if !programme.categories.isEmpty {
                                    Text(programme.categories.first!)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                        }

                        if let desc = programme.description, !desc.isEmpty {
                            Text(desc)
                                .font(.callout)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(programme.title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
    }

    private var timeRange: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mm a"
        return "\(fmt.string(from: programme.start)) – \(fmt.string(from: programme.end))"
    }
}

// MARK: - What's On View

/// Grid of currently airing programmes across all guide channels.
struct WhatsOnView: View {
    @EnvironmentObject private var repository: EPGRepository
    @StateObject private var vm = TVGuideViewModel()
    @State private var playingChannel: CanonicalChannel?
    @EnvironmentObject private var watchStore: WatchStore

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 12)]
    private let now = Date()

    var body: some View {
        Group {
            if currentItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tv").font(.system(size: 44)).foregroundStyle(Theme.textSecondary)
                    Text("No guide data available").font(.callout).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(currentItems) { item in
                            WhatsOnCard(item: item) {
                                if let ch = item.channel.playableChannel {
                                    watchStore.recordWatch(ch)
                                    playingChannel = item.channel
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .fullScreenCover(item: $playingChannel) { ch in PlayerView(canonicalChannel: ch) }
        .onAppear { vm.setup(repository: repository) }
    }

    private var currentItems: [WhatsOnItem] {
        vm.visibleChannels.compactMap { ch in
            guard let prog = vm.currentProgramme(for: ch) else { return nil }
            return WhatsOnItem(channel: ch, programme: prog)
        }
    }
}

struct WhatsOnItem: Identifiable {
    let channel: CanonicalChannel
    let programme: EPGProgramme
    var id: String { "\(channel.id)-\(programme.id)" }
}

struct WhatsOnCard: View {
    let item: WhatsOnItem
    let onPlay: () -> Void
    private let now = Date()

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let logoURL = item.channel.effectiveLogoURL {
                        AsyncImage(url: logoURL) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFit()
                            } else {
                                Image(systemName: "tv").foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 32, height: 32)
                    }
                    Text(item.channel.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.programme.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    let mins = item.programme.minutesRemaining(from: now)
                    Text(mins < 60 ? "\(mins)m left" : "\(mins / 60)h \(mins % 60)m left")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceElevated)
                        Capsule()
                            .fill(Theme.accent.opacity(0.7))
                            .frame(width: g.size.width * item.programme.progress(at: now))
                    }
                }
                .frame(height: 3)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}
