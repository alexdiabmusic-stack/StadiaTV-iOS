import SwiftUI
import Combine

// MARK: - TVGuideView

struct TVGuideView: View {
    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var guideStore: GuideChannelStore
    @StateObject private var vm = TVGuideViewModel()

    @State private var playingChannel: CanonicalChannel?
    @State private var selectedProgramme: EPGProgramme?
    @State private var selectedProgrammeChannel: CanonicalChannel?
    @State private var showingBuildGuide = false
    @State private var showingFilters = false

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
                    if ch.playableChannel != nil { playingChannel = ch }
                }
            }
        }
        .sheet(isPresented: $showingBuildGuide) {
            BuildGuideSheet()
        }
        .sheet(isPresented: $showingFilters) {
            GuideFilterSheet(vm: vm, showingBuildGuide: $showingBuildGuide)
        }
        .onAppear {
            vm.setup(repository: repository)
            vm.applyGuideStore(guideStore, repository: repository)
        }
        .onChange(of: repository.canonicalChannels.count) { _, _ in
            vm.update(repository: repository)
            vm.applyGuideStore(guideStore, repository: repository)
        }
        .onChange(of: guideStore.selectedChannelIDs) { _, _ in
            vm.applyGuideStore(guideStore, repository: repository)
        }
        .onChange(of: guideStore.guideMode) { _, _ in
            vm.applyGuideStore(guideStore, repository: repository)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            if repository.refreshState == .refreshing {
                ProgressView().tint(Theme.accent)
                Text("Building your channel guide…")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.callout)
            } else {
                Image(systemName: "tv.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.textSecondary)
                Text("No Guide Available")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Add an IPTV playlist in Settings to see a TV guide.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Guide content

    private var guideContent: some View {
        VStack(spacing: 0) {
            guideHeader
            Divider().overlay(Theme.hairline)
            if guideStore.guideMode == .myGuide && !guideStore.hasConfigured {
                myGuideSetupPrompt
            } else {
                EPGGuideGrid(vm: vm) { channel in
                    if let ch = channel.playableChannel {
                        watchStore.recordWatch(ch)
                        playingChannel = channel
                    }
                } onProgramTap: { programme, channel in
                    if programme.isOnNow() {
                        if let ch = channel.playableChannel {
                            watchStore.recordWatch(ch)
                            playingChannel = channel
                        }
                    } else {
                        selectedProgramme = programme
                        selectedProgrammeChannel = channel
                    }
                }
            }
        }
    }

    // MARK: - Guide header

    private var guideHeader: some View {
        HStack(spacing: 10) {
            GuideModeControl(
                mode: guideStore.guideMode,
                myGuideCount: guideStore.selectedCount
            ) { newMode in
                vm.setGuideMode(newMode, store: guideStore)
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showingFilters = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(vm.filterCategoryId != nil ? Theme.accent : Theme.textPrimary)
                    .frame(width: 36, height: 34)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(vm.filterCategoryId != nil ? Theme.accent.opacity(0.5) : Theme.hairline)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Guide filters")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    // MARK: - My Guide setup prompt

    private var myGuideSetupPrompt: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "list.star")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 8) {
                Text("Build Your Guide")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Choose what you actually watch.\nYou can change this anytime.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Get Started") {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showingBuildGuide = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .font(.headline)
            Button("Browse All Channels") {
                vm.setGuideMode(.allChannels, store: guideStore)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Guide Mode Control

struct GuideModeControl: View {
    let mode: GuideMode
    let myGuideCount: Int
    let onSelect: (GuideMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.myGuide, label: "My Guide")
            modeButton(.allChannels, label: "All Channels")
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func modeButton(_ target: GuideMode, label: String) -> some View {
        let selected = mode == target
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy) { onSelect(target) }
        } label: {
            Text(label)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: selected)
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

    // Whether the NOW indicator is off the visible horizontal viewport.
    private var isNowOffScreen: Bool {
        guard vm.nowIsVisible, viewSize.width > 0 else { return false }
        let nowContentX = vm.xOffset(for: now)
        let viewportStart = scrollOffset.x
        let viewportEnd = scrollOffset.x + max(0, viewSize.width - colW)
        return nowContentX < viewportStart || nowContentX > viewportEnd
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                mainScrollView
                channelColumnOverlay
                timeRulerOverlay
                cornerOverlay
                nowLineOverlay
                jumpToNowButton
            }
            .clipped()
            .simultaneousGesture(channelColumnTapGesture)
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

    private var channelColumnTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let loc = value.location
                guard loc.x < colW, loc.y >= rulerH else { return }
                let channelY = loc.y + scrollOffset.y - rulerH
                let idx = Int(channelY / rowH)
                guard idx >= 0, idx < visibleChannels.count else { return }
                let ch = visibleChannels[idx]
                if ch.playableChannel != nil { onChannelTap(ch) }
            }
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

                // Row dividers (full width)
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
            let firstRow = max(0, Int((offset.y - rulerH) / rowH))
            let visibleRows = max(1, Int(viewSize.height / rowH) + 2)
            vm.prefetchProgrammesAround(rowIndex: firstRow, visibleRowCount: visibleRows)
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
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
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

    /// Channel column: only renders rows visible in the current viewport + a buffer,
    /// avoiding SwiftUI layout work for thousands of offscreen cells.
    private var channelColumnOverlay: some View {
        let firstRow = max(0, Int(scrollOffset.y / rowH) - 1)
        let visibleRowCount = max(1, Int(viewSize.height / rowH)) + 4
        let lastRow = min(visibleChannels.count, firstRow + visibleRowCount)

        return ZStack(alignment: .topLeading) {
            Theme.background
                .frame(width: colW, height: viewSize.height)

            ForEach(firstRow..<lastRow, id: \.self) { i in
                let ch = visibleChannels[i]
                let cellY = rulerH + CGFloat(i) * rowH - scrollOffset.y
                ChannelLogoCell(channel: ch) { }
                    .frame(width: colW, height: rowH)
                    .offset(y: cellY)
                Divider()
                    .overlay(Theme.hairline)
                    .frame(width: colW)
                    .offset(y: cellY + rowH - 0.5)
            }
        }
        .frame(width: colW, height: viewSize.height)
        .clipped()
        .allowsHitTesting(false)
    }

    /// Time ruler: pinned at y=0, labels positioned relative to scroll offset.
    private var timeRulerOverlay: some View {
        ZStack(alignment: .topLeading) {
            Theme.background
            ForEach(timeLabels, id: \.0.timeIntervalSince1970) { _, label, x in
                let screenX = colW + x - scrollOffset.x
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
        .allowsHitTesting(false)
    }

    private var cornerOverlay: some View {
        ZStack {
            Theme.background
            Text("CH")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(width: colW, height: rulerH)
        .allowsHitTesting(false)
    }

    private var nowLineOverlay: some View {
        Group {
            if vm.nowIsVisible {
                let nowX = colW + vm.xOffset(for: now) - scrollOffset.x
                if nowX >= colW && nowX <= viewSize.width {
                    let maxLineH = max(0, viewSize.height - rulerH - bottomInset)
                    let lineH = min(CGFloat(vm.visibleChannels.count) * rowH, maxLineH)
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Theme.live)
                            .frame(width: 2, height: lineH)
                        Circle()
                            .fill(Theme.live)
                            .frame(width: 8, height: 8)
                            .offset(y: -4)
                    }
                    .frame(width: 2)
                    .offset(x: nowX, y: rulerH)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// "Jump to Now" button — appears when the current-time line is off-screen.
    @ViewBuilder
    private var jumpToNowButton: some View {
        if isNowOffScreen {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        vm.scrollToNow()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.badge.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Now")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.live, in: Capsule())
                        .shadow(color: Theme.live.opacity(0.4), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.bottom, 20 + bottomInset)
                }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isNowOffScreen)
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

    // Static formatter to avoid re-creating DateFormatter on every cell render.
    nonisolated static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCurrent ? Theme.accent.opacity(0.18) : Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isCurrent ? Theme.accent.opacity(0.4) : Theme.hairline)
                    )

                // Thin progress bar for currently-airing programmes
                if isCurrent {
                    GeometryReader { g in
                        Rectangle()
                            .fill(Theme.accent.opacity(0.15))
                            .frame(width: g.size.width * programme.progress(at: now))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Text content — responsive to card width
                if width >= 36 {
                    cellContent
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var cellContent: some View {
        let narrow = width < 70
        VStack(alignment: .leading, spacing: 2) {
            Text(programme.title)
                .font(.system(size: narrow ? 10 : 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if width > 90 {
                Text(timeSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, narrow ? 4 : 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeSubtitle: String {
        if isCurrent {
            let mins = programme.minutesRemaining(from: now)
            if mins < 60 { return "\(mins)m left" }
            return "\(mins / 60)h \(mins % 60)m left"
        } else {
            return "\(Self.timeFmt.string(from: programme.start)) – \(Self.timeFmt.string(from: programme.end))"
        }
    }

    private var accessibilityLabel: String {
        if isCurrent {
            let mins = programme.minutesRemaining(from: now)
            return "\(programme.title), \(Self.timeFmt.string(from: programme.start)) to \(Self.timeFmt.string(from: programme.end)), now playing, \(mins) minutes remaining."
        }
        return "\(programme.title), \(Self.timeFmt.string(from: programme.start)) to \(Self.timeFmt.string(from: programme.end))."
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

                        if channel.playableChannel != nil {
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPlay() }
                            } label: {
                                Label("Watch Channel", systemImage: "play.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
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
        "\(ProgrammeCell.timeFmt.string(from: programme.start)) – \(ProgrammeCell.timeFmt.string(from: programme.end))"
    }
}

// MARK: - Build Guide Sheet

struct BuildGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var guideStore: GuideChannelStore
    @EnvironmentObject private var repository: EPGRepository

    @State private var step = 1
    @State private var selectedCategoryIds: Set<String> = []
    @State private var localSelectedIDs: Set<String>
    @State private var searchText = ""

    private let config = CuratedGuideConfig.load()

    init() {
        _localSelectedIDs = State(initialValue: [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if step == 1 {
                    categoryStep
                } else {
                    channelStep
                }
            }
        }
        .tint(Theme.accent)
        .onAppear {
            // Prefill with existing selections
            localSelectedIDs = guideStore.selectedChannelIDs
            // Pre-select categories that have selected channels
            let existingCats = Set(
                repository.canonicalChannels
                    .filter { guideStore.isSelected($0.id) }
                    .map { $0.categoryId }
            )
            if !existingCats.isEmpty {
                selectedCategoryIds = existingCats
            }
        }
    }

    // MARK: Step 1 — Categories

    private var categoryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose what you actually watch.")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                let cats = config?.categories.sorted { $0.sort < $1.sort } ?? []
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(cats) { cat in
                        CategoryToggleCard(
                            name: cat.name,
                            isSelected: selectedCategoryIds.contains(cat.id)
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if selectedCategoryIds.contains(cat.id) {
                                selectedCategoryIds.remove(cat.id)
                            } else {
                                selectedCategoryIds.insert(cat.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 100)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Build Your Guide")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(Theme.textSecondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Next") {
                    // Pre-select all channels in chosen categories
                    let toAdd = repository.canonicalChannels.filter { selectedCategoryIds.contains($0.categoryId) }
                    localSelectedIDs = Set(toAdd.map { $0.id })
                    withAnimation { step = 2 }
                }
                .font(.headline)
                .disabled(selectedCategoryIds.isEmpty)
            }
        }
    }

    // MARK: Step 2 — Channels

    private var channelStep: some View {
        Group {
            if repository.canonicalChannels.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().tint(Theme.accent)
                    Text("Loading channels…")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                channelList
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Select Channels")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search channels")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") { withAnimation { step = 1 } }
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .safeAreaInset(edge: .bottom) { confirmBar }
    }

    private var channelList: some View {
        let grouped = groupedChannels
        return List {
            ForEach(grouped, id: \.categoryId) { group in
                Section {
                    ForEach(group.channels) { ch in
                        ChannelSelectRow(
                            channel: ch,
                            isSelected: localSelectedIDs.contains(ch.id)
                        ) {
                            if localSelectedIDs.contains(ch.id) {
                                localSelectedIDs.remove(ch.id)
                            } else {
                                localSelectedIDs.insert(ch.id)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.categoryName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        let catIds = group.channels.map { $0.id }
                        let allSelected = catIds.allSatisfy { localSelectedIDs.contains($0) }
                        Button(allSelected ? "Deselect All" : "Select All") {
                            if allSelected {
                                catIds.forEach { localSelectedIDs.remove($0) }
                            } else {
                                catIds.forEach { localSelectedIDs.insert($0) }
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .hidesScrollContentBackground()
        .scrollContentBackground(.hidden)
    }

    private var confirmBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack {
                Text("\(localSelectedIDs.count) channels selected")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("View My Guide") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    guideStore.setChannels(localSelectedIDs)
                    guideStore.markConfigured()
                    guideStore.setGuideMode(.myGuide)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(localSelectedIDs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.background)
        }
    }

    // MARK: - Helpers

    private var groupedChannels: [(categoryId: String, categoryName: String, channels: [CanonicalChannel])] {
        let catNames: [String: String] = config?.categories.reduce(into: [:]) { $0[$1.id] = $1.name } ?? [:]

        let filtered = repository.canonicalChannels.filter { ch in
            selectedCategoryIds.contains(ch.categoryId) &&
            (searchText.isEmpty || ch.name.localizedCaseInsensitiveContains(searchText))
        }

        var result: [(categoryId: String, categoryName: String, channels: [CanonicalChannel])] = []
        var seen: Set<String> = []
        for ch in filtered {
            guard !seen.contains(ch.categoryId) else { continue }
            seen.insert(ch.categoryId)
            let catChannels = filtered
                .filter { $0.categoryId == ch.categoryId }
                .sorted { $0.priority > $1.priority }
            let name = catNames[ch.categoryId] ?? ch.categoryId
            result.append((ch.categoryId, name, catChannels))
        }
        return result
    }
}

// MARK: - Category Toggle Card

private struct CategoryToggleCard: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Theme.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .white : Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isSelected ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline)
            )
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: isSelected)
    }
}

// MARK: - Channel Select Row

private struct ChannelSelectRow: View {
    let channel: CanonicalChannel
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                if let logoURL = channel.effectiveLogoURL {
                    AsyncImage(url: logoURL) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFit()
                        } else {
                            channelInitials
                        }
                    }
                    .frame(width: 36, height: 24)
                } else {
                    channelInitials.frame(width: 36, height: 24)
                }

                Text(channel.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                    .font(.system(size: 20))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var channelInitials: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated)
            Text(channel.name.prefix(2).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
        }
    }
}

// MARK: - Guide Filter Sheet

struct GuideFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var guideStore: GuideChannelStore
    @ObservedObject var vm: TVGuideViewModel
    @Binding var showingBuildGuide: Bool

    var body: some View {
        NavigationStack {
            List {
                if vm.guideMode == .allChannels {
                    Section("Category") {
                        Button {
                            vm.setFilterCategory(nil)
                            dismiss()
                        } label: {
                            HStack {
                                Text("All Categories")
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if vm.filterCategoryId == nil {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        ForEach(vm.categories.filter { !$0.isVirtual }) { cat in
                            Button {
                                vm.setFilterCategory(cat.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(cat.name)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    if vm.filterCategoryId == cat.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("My Guide") {
                    Button {
                        showingBuildGuide = true
                        dismiss()
                    } label: {
                        HStack {
                            Label(
                                guideStore.hasConfigured ? "Edit My Guide" : "Build My Guide",
                                systemImage: "list.star"
                            )
                            .foregroundStyle(Theme.textPrimary)
                            if guideStore.selectedCount > 0 {
                                Spacer()
                                Text("\(guideStore.selectedCount) channels")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .hidesScrollContentBackground()
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - What's On View

/// Grid of currently airing programmes across all guide channels.
struct WhatsOnView: View {
    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var guideStore: GuideChannelStore
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
        .onAppear {
            vm.setup(repository: repository)
            vm.applyGuideStore(guideStore, repository: repository)
        }
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
