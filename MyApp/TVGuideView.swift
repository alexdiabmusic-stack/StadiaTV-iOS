import SwiftUI
import Combine

// MARK: - TVGuideView

struct TVGuideView: View {
    /// When non-nil, channel taps call this closure instead of presenting a new PlayerView.
    var onChannelSelected: ((CanonicalChannel) -> Void)? = nil

    @EnvironmentObject private var repository: EPGRepository
    @EnvironmentObject private var watchStore: WatchStore
    @EnvironmentObject private var guideStore: GuideChannelStore
    @StateObject private var vm = TVGuideViewModel()

    @Environment(\.dismiss) private var dismiss

    @State private var playingChannel: CanonicalChannel?
    @State private var catchupChannel: Channel?
    @State private var selectedProgramme: EPGProgramme?
    @State private var selectedProgrammeChannel: CanonicalChannel?
    @State private var showingBuildGuide = false
    @State private var showingFilters = false
    @State private var channelForOffset: CanonicalChannel?
    @State private var channelSearchQuery: String = ""

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
        .fullScreenCover(item: $catchupChannel) { ch in
            PlayerView(channel: ch)
        }
        .sheet(item: $selectedProgramme) { prog in
            if let ch = selectedProgrammeChannel {
                ProgrammeDetailSheet(
                    programme: prog,
                    channel: ch,
                    onPlayLive: {
                        if ch.playableChannel != nil {
                            watchStore.recordWatch(ch.playableChannel!)
                            playingChannel = ch
                        }
                    },
                    onPlayCatchup: { url in
                        guard let playable = ch.playableChannel else { return }
                        catchupChannel = Channel(
                            id: "\(playable.id)-catchup",
                            name: ch.name,
                            streamURL: url,
                            logoURL: ch.effectiveLogoURL,
                            group: ch.categoryId,
                            playlistID: playable.playlistID,
                            playlistName: playable.playlistName
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $showingBuildGuide) {
            BuildGuideSheet()
        }
        .sheet(isPresented: $showingFilters) {
            GuideFilterSheet(vm: vm, showingBuildGuide: $showingBuildGuide)
        }
        .sheet(item: $channelForOffset) { ch in
            EPGOffsetSheet(channel: ch, vm: vm)
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
                    guard channel.playableChannel != nil else { return }
                    if let onChannelSelected {
                        onChannelSelected(channel)
                    } else {
                        if let ch = channel.playableChannel { watchStore.recordWatch(ch) }
                        playingChannel = channel
                    }
                } onProgramTap: { programme, channel in
                    if programme.isOnNow() {
                        guard channel.playableChannel != nil else { return }
                        if let onChannelSelected {
                            onChannelSelected(channel)
                        } else {
                            if let ch = channel.playableChannel { watchStore.recordWatch(ch) }
                            playingChannel = channel
                        }
                    } else {
                        selectedProgramme = programme
                        selectedProgrammeChannel = channel
                    }
                } onSetOffset: { channel in
                    channelForOffset = channel
                }
            }
        }
    }

    // MARK: - Guide header

    private var guideHeader: some View {
        VStack(spacing: 6) {
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

                if onChannelSelected != nil {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, height: 34)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Theme.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close guide")
                }
            }

            // Channel name search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                TextField("Search channels…", text: $channelSearchQuery)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: channelSearchQuery) { _, q in
                        vm.setChannelNameFilter(q)
                    }
                if !channelSearchQuery.isEmpty {
                    Button {
                        channelSearchQuery = ""
                        vm.setChannelNameFilter("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
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

// MARK: - Scroll State

/// Reference-type container for the EPG grid's current scroll offset.
/// Stored separately from EPGGuideGrid so that programme cells (ProgrammeGridView)
/// are NOT re-rendered on every scroll frame — only the lightweight overlay views
/// observe this and re-render when the offset changes.
@MainActor
final class EPGScrollState: ObservableObject {
    @Published var offset: CGPoint = .zero
    var viewSize: CGSize = .zero
    var bottomInset: CGFloat = 0
}

// MARK: - Directional Lock

/// Introspects the SwiftUI ScrollView's backing UIScrollView and enables
/// isDirectionalLockEnabled so that diagonal finger movement locks to one axis.
private struct DirectionalLockModifier: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        DispatchQueue.main.async {
            var parent: UIView? = v.superview
            while let p = parent {
                if let sv = p as? UIScrollView {
                    sv.isDirectionalLockEnabled = true
                    break
                }
                parent = p.superview
            }
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - EPG Guide Grid

struct EPGGuideGrid: View {
    @ObservedObject var vm: TVGuideViewModel
    @EnvironmentObject private var repository: EPGRepository
    let onChannelTap: (CanonicalChannel) -> Void
    let onProgramTap: (EPGProgramme, CanonicalChannel) -> Void
    let onSetOffset: ((CanonicalChannel) -> Void)?

    @StateObject private var scrollState = EPGScrollState()
    /// Incrementing triggers ProgrammeGridView to animate-scroll to current time.
    @State private var scrollToNowTrigger: Int = 0
    @State private var hasScrolledToNow = false
    @State private var now: Date = Date()

    private let rowH = TVGuideViewModel.rowHeight
    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight

    var body: some View {
        // IMPORTANT: this body does NOT read scrollState.offset.
        // Only the lightweight overlay sub-views observe EPGScrollState, so the
        // expensive programme cell grid is NOT re-rendered on every scroll frame.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ProgrammeGridView(
                    vm: vm,
                    scrollState: scrollState,
                    scrollToNowTrigger: scrollToNowTrigger,
                    now: now,
                    onProgramTap: onProgramTap
                )
                ChannelColumnOverlayView(
                    vm: vm,
                    scrollState: scrollState,
                    onChannelTap: onChannelTap,
                    onSetOffset: onSetOffset
                )
                TimeRulerOverlayView(vm: vm, scrollState: scrollState)
                cornerOverlay
                NowLineOverlayView(vm: vm, scrollState: scrollState, now: now)
                JumpToNowOverlayView(vm: vm, scrollState: scrollState, now: now) {
                    vm.scrollToNow()
                }
            }
            .clipped()
            .onAppear {
                scrollState.viewSize = geo.size
                scrollState.bottomInset = geo.safeAreaInsets.bottom
                triggerScrollToNow()
            }
            .onChange(of: geo.size) { _, size in
                scrollState.viewSize = size
                triggerScrollToNow()
            }
        }
        .onChange(of: vm.visibleChannels.count) { _, _ in triggerScrollToNow() }
        .onChange(of: vm.scrollToNowToken) { _, _ in scrollToNowTrigger += 1 }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
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

    private func triggerScrollToNow() {
        guard !hasScrolledToNow,
              !vm.visibleChannels.isEmpty,
              scrollState.viewSize.width > 0 else { return }
        hasScrolledToNow = true
        scrollToNowTrigger += 1
    }
}

// MARK: - Programme Grid View

/// The scrollable programme cell content. Deliberately passes EPGScrollState as a plain
/// reference (not @ObservedObject) so it WRITES offset updates but does NOT re-render
/// when the offset changes — only the overlay views observe it.
private struct ProgrammeGridView: View {
    @ObservedObject var vm: TVGuideViewModel
    @EnvironmentObject var repository: EPGRepository
    let scrollState: EPGScrollState
    let scrollToNowTrigger: Int
    let now: Date
    let onProgramTap: (EPGProgramme, CanonicalChannel) -> Void

    @State private var scrollPos = ScrollPosition(x: 0, y: 0)

    private let rowH = TVGuideViewModel.rowHeight
    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: colW + vm.guideWindowWidth,
                        height: rulerH + CGFloat(vm.visibleChannels.count) * rowH
                    )
                    .background(DirectionalLockModifier())

                ForEach(Array(vm.visibleChannels.enumerated()), id: \.element.id) { i, _ in
                    Divider().overlay(Theme.hairline)
                        .frame(width: colW + vm.guideWindowWidth)
                        .offset(x: 0, y: rulerH + CGFloat(i) * rowH)
                }

                ForEach(Array(vm.visibleChannels.enumerated()), id: \.element.id) { i, ch in
                    let rowY = rulerH + CGFloat(i) * rowH
                    programCells(for: ch, rowIndex: i, rowY: rowY)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .scrollPosition($scrollPos)
        .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, offset in
            scrollState.offset = offset
            let firstRow = max(0, Int((offset.y - rulerH) / rowH))
            let visibleRows = max(1, Int(scrollState.viewSize.height / rowH) + 2)
            vm.prefetchProgrammesAround(rowIndex: firstRow, visibleRowCount: visibleRows)
        }
        .contentMargins(.bottom, scrollState.bottomInset + 16, for: .scrollContent)
        .onChange(of: scrollToNowTrigger) { _, _ in
            let target = vm.initialScrollOffset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                scrollPos = ScrollPosition(x: target, y: 0)
            }
        }
    }

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
                ProgrammeCell(
                    programme: prog,
                    width: w,
                    now: now,
                    hasCatchup: channel.hasCatchup
                ) {
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
}

// MARK: - Channel Column Overlay

private struct ChannelColumnOverlayView: View {
    @ObservedObject var vm: TVGuideViewModel
    @ObservedObject var scrollState: EPGScrollState
    @EnvironmentObject var guideStore: GuideChannelStore
    let onChannelTap: (CanonicalChannel) -> Void
    let onSetOffset: ((CanonicalChannel) -> Void)?

    private let rowH = TVGuideViewModel.rowHeight
    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight

    var body: some View {
        let offsetY = scrollState.offset.y
        let viewH = scrollState.viewSize.height
        let firstRow = max(0, Int(offsetY / rowH) - 1)
        let visibleRowCount = max(1, Int(viewH / rowH)) + 4
        let lastRow = min(vm.visibleChannels.count, firstRow + visibleRowCount)

        ZStack(alignment: .topLeading) {
            Theme.background
                .frame(width: colW, height: viewH)

            if lastRow > firstRow {
                ForEach(firstRow..<lastRow, id: \.self) { i in
                    let ch = vm.visibleChannels[i]
                    let cellY = rulerH + CGFloat(i) * rowH - offsetY
                    let inGuide = guideStore.isSelected(ch.id)
                    let offsetMinutes = vm.epgOffsetMinutes(for: ch)
                    ChannelLogoCell(channel: ch) {
                        if ch.playableChannel != nil { onChannelTap(ch) }
                    }
                    .frame(width: colW, height: rowH)
                    .offset(y: cellY)
                    .contextMenu {
                        Button {
                            guideStore.toggle(ch.id)
                            if !guideStore.hasConfigured { guideStore.markConfigured() }
                        } label: {
                            Label(inGuide ? "Remove from My Guide" : "Add to My Guide",
                                  systemImage: inGuide ? "star.slash" : "star")
                        }
                        Divider()
                        Button {
                            onSetOffset?(ch)
                        } label: {
                            Label(
                                offsetMinutes == 0
                                    ? "Set EPG Offset…"
                                    : "EPG Offset: \(formattedOffset(offsetMinutes))",
                                systemImage: "clock.badge"
                            )
                        }
                        if offsetMinutes != 0 {
                            Button(role: .destructive) {
                                guideStore.setEPGOffset(0, for: ch.id)
                            } label: {
                                Label("Clear EPG Offset", systemImage: "clock.badge.xmark")
                            }
                        }
                    }
                    Divider()
                        .overlay(Theme.hairline)
                        .frame(width: colW)
                        .offset(y: cellY + rowH - 0.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: colW, height: viewH)
        .clipped()
    }

    private func formattedOffset(_ minutes: Int) -> String {
        let sign = minutes > 0 ? "+" : ""
        let abs = Swift.abs(minutes)
        if abs < 60 { return "\(sign)\(minutes)m" }
        let h = abs / 60, m = abs % 60
        return m == 0 ? "\(sign)\(minutes > 0 ? h : -h)h" : "\(sign)\(minutes > 0 ? h : -h)h \(m)m"
    }
}

// MARK: - Time Ruler Overlay

private struct TimeRulerOverlayView: View {
    @ObservedObject var vm: TVGuideViewModel
    @ObservedObject var scrollState: EPGScrollState

    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight

    private var timeLabels: [(Date, String, CGFloat)] {
        let window = vm.guideWindowStart...vm.guideWindowEnd
        return vm.timeLabels(in: window).map { ($0.date, $0.label, $0.x) }
    }

    var body: some View {
        let offsetX = scrollState.offset.x
        let viewW = scrollState.viewSize.width
        ZStack(alignment: .topLeading) {
            Theme.background
            ForEach(timeLabels, id: \.0.timeIntervalSince1970) { _, label, x in
                let screenX = colW + x - offsetX
                if screenX < viewW + 4 {
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
}

// MARK: - Now Line Overlay

private struct NowLineOverlayView: View {
    @ObservedObject var vm: TVGuideViewModel
    @ObservedObject var scrollState: EPGScrollState
    let now: Date

    private let colW = TVGuideViewModel.channelColumnWidth
    private let rulerH = TVGuideViewModel.timeRulerHeight
    private let rowH = TVGuideViewModel.rowHeight

    var body: some View {
        if vm.nowIsVisible {
            let nowX = colW + vm.xOffset(for: now) - scrollState.offset.x
            if nowX >= colW && nowX <= scrollState.viewSize.width {
                let maxLineH = max(0, scrollState.viewSize.height - rulerH - scrollState.bottomInset)
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

// MARK: - Jump to Now Overlay

private struct JumpToNowOverlayView: View {
    @ObservedObject var vm: TVGuideViewModel
    @ObservedObject var scrollState: EPGScrollState
    let now: Date
    let onJump: () -> Void

    private let colW = TVGuideViewModel.channelColumnWidth

    private var isNowOffScreen: Bool {
        guard vm.nowIsVisible, scrollState.viewSize.width > 0 else { return false }
        let nowContentX = vm.xOffset(for: now)
        let viewportStart = scrollState.offset.x
        let viewportEnd = scrollState.offset.x + max(0, scrollState.viewSize.width - colW)
        return nowContentX < viewportStart || nowContentX > viewportEnd
    }

    var body: some View {
        Group {
            if isNowOffScreen {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onJump()
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
                        .padding(.bottom, 20 + scrollState.bottomInset)
                    }
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isNowOffScreen)
    }
}

// MARK: - Programme Cell

struct ProgrammeCell: View {
    let programme: EPGProgramme
    let width: CGFloat
    let now: Date
    var hasCatchup: Bool = false
    let onTap: () -> Void

    private var isCurrent: Bool { programme.isOnNow(at: now) }
    private var isPast: Bool { programme.isPast(at: now) }
    private var showCatchupBadge: Bool { isPast && hasCatchup && width >= 80 }

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
                    .fill(isCurrent ? Theme.accent.opacity(0.18) : isPast ? Theme.surface.opacity(0.6) : Theme.surface)
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

                // Catch-up available badge
                if showCatchupBadge {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
    let onPlayLive: () -> Void
    var onPlayCatchup: ((URL) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var guideStore: GuideChannelStore
    @EnvironmentObject private var reminderStore: ProgrammeReminderStore
    @EnvironmentObject private var recordingService: RecordingService

    @State private var catchupState: CatchupState = .idle
    @State private var selectedLeadTime: Int = 5
    @State private var reminderAdding = false
    @State private var showingRecordingSchedule = false
    @State private var recordingScheduled = false

    private enum CatchupState {
        case idle, loading, available(URL), failed, notEligible
    }

    private let resolver = CatchupResolver()
    private let now = Date()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        channelHeader
                        programmeImage
                        programmeMetadata
                        programmeDescription
                        actionButtons
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
        .task {
            await resolveCatchupIfNeeded()
        }
        .sheet(isPresented: $showingRecordingSchedule) {
            RecordingScheduleSheet(
                programme: programme,
                channel: channel,
                onScheduled: { _ in recordingScheduled = true }
            )
        }
    }

    // MARK: - Subviews

    private var channelHeader: some View {
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
                programmeStateBadge
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var programmeStateBadge: some View {
        if programme.isOnNow(at: now) {
            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.live)
        } else if programme.isFuture(at: now) {
            Label("Upcoming", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        } else if case .available = catchupState {
            Label("Catch-up available", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder
    private var programmeImage: some View {
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
    }

    private var programmeMetadata: some View {
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
    }

    @ViewBuilder
    private var programmeDescription: some View {
        if let desc = programme.description, !desc.isEmpty {
            Text(desc)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Live or catch-up playback button
            if programme.isOnNow(at: now), channel.playableChannel != nil {
                watchLiveButton
            } else if programme.isPast(at: now) {
                catchupButton
            }

            // Future programme: Remind Me
            if programme.isFuture(at: now) {
                reminderSection
            }

            // Recording: available for live and future programmes
            if programme.isOnNow(at: now) || programme.isFuture(at: now) {
                recordingSection
            }
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        let mode = recordingService.preferredMode(for: channel)
        if mode != .unavailable {
            if recordingScheduled {
                Label("Recording scheduled", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                Button { showingRecordingSchedule = true } label: {
                    Label(
                        programme.isOnNow(at: now) ? "Record Now" : "Schedule Recording",
                        systemImage: "record.circle"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.live.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Theme.live)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var watchLiveButton: some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onPlayLive() }
        } label: {
            Label("Watch Live", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var catchupButton: some View {
        switch catchupState {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                ProgressView().tint(Theme.accent)
                Text("Checking archive…")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        case .available(let url):
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onPlayCatchup?(url)
                }
            } label: {
                Label("Watch from Beginning", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        case .failed:
            Text("Archive unavailable — stream failed to load.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .notEligible:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reminderSection: some View {
        let hasReminder = reminderStore.hasReminder(for: programme)
        VStack(spacing: 10) {
            if !hasReminder {
                Picker("Remind me", selection: $selectedLeadTime) {
                    Text("5 min before").tag(5)
                    Text("10 min before").tag(10)
                    Text("15 min before").tag(15)
                    Text("30 min before").tag(30)
                }
                .pickerStyle(.segmented)
            }

            Button {
                if hasReminder {
                    if let id = reminderStore.reminderID(for: programme) {
                        reminderStore.removeReminder(id: id)
                    }
                } else {
                    reminderAdding = true
                    Task {
                        _ = await reminderStore.addReminder(
                            for: programme,
                            channel: channel,
                            leadTimeMinutes: selectedLeadTime
                        )
                        reminderAdding = false
                    }
                }
            } label: {
                Group {
                    if reminderAdding {
                        ProgressView().tint(.white)
                    } else if hasReminder {
                        Label("Cancel Reminder", systemImage: "bell.slash.fill")
                    } else {
                        Label("Remind Me", systemImage: "bell.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    hasReminder ? Theme.surfaceElevated : Theme.accent,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(hasReminder ? Theme.textPrimary : .white)
            }
            .buttonStyle(.plain)
            .disabled(reminderAdding)
        }
    }

    // MARK: - Catch-up resolution

    private func resolveCatchupIfNeeded() async {
        guard programme.isPast(at: now) else { return }
        guard resolver.isEligible(programme: programme, channel: channel, now: now) else {
            catchupState = .notEligible
            return
        }
        catchupState = .loading
        let offset = guideStore.epgOffset(for: channel.id)
        do {
            let url = try await resolver.resolveURL(
                programme: programme,
                channel: channel,
                epgOffsetMinutes: offset
            )
            catchupState = .available(url)
        } catch {
            catchupState = .notEligible
        }
    }

    // MARK: - Helpers

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

// MARK: - EPG Offset Sheet

struct EPGOffsetSheet: View {
    let channel: CanonicalChannel
    @ObservedObject var vm: TVGuideViewModel
    @EnvironmentObject private var guideStore: GuideChannelStore
    @Environment(\.dismiss) private var dismiss

    @State private var offsetMinutes: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 28) {
                    // Channel identity
                    VStack(spacing: 6) {
                        if let logoURL = channel.effectiveLogoURL {
                            AsyncImage(url: logoURL) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFit()
                                } else {
                                    Image(systemName: "tv").foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text(channel.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 8) {
                        Text("EPG Offset")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(offsetMinutes == 0 ? "No offset" : formattedOffset(offsetMinutes))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(offsetMinutes == 0 ? Theme.textTertiary : Theme.accent)
                            .animation(.snappy, value: offsetMinutes)
                            .contentTransition(.numericText())
                    }

                    Stepper(value: $offsetMinutes, in: -720...720, step: 15) {
                        Text("Adjust in 15-minute steps")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 20)

                    Text("Positive offset: your stream is ahead of the EPG listing.\nNegative offset: your stream is behind the EPG listing.")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    if offsetMinutes != 0 {
                        Button("Clear Offset") {
                            withAnimation(.snappy) { offsetMinutes = 0 }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("EPG Offset")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guideStore.setEPGOffset(offsetMinutes, for: channel.id)
                        dismiss()
                    }
                    .font(.headline)
                }
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            offsetMinutes = guideStore.epgOffset(for: channel.id)
        }
    }

    private func formattedOffset(_ minutes: Int) -> String {
        let sign = minutes > 0 ? "+" : ""
        let abs = Swift.abs(minutes)
        if abs < 60 { return "\(sign)\(minutes)m" }
        let h = abs / 60, m = abs % 60
        return m == 0 ? "\(sign)\(minutes > 0 ? h : -h)h" : "\(sign)\(minutes > 0 ? h : -h)h \(m)m"
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
