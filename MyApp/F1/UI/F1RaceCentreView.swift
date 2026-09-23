import SwiftUI

struct F1RaceCentreView<RelatedContent: View>: View {
    let match: Match
    @ViewBuilder let relatedContent: () -> RelatedContent
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var entitlements: EntitlementStore
    #if DEBUG
    @State private var model = F1RaceCentreViewModel.configuredForDebugReplay()
    @State private var recordingURL: URL?
    #else
    @State private var model = F1RaceCentreViewModel()
    #endif
    @State private var session: F1ScheduledSession?
    @State private var loadError: String?
    @State private var tab = "Overview"
    @State private var selected: String?
    @State private var revision = 0
    @State private var revealed = false
    @State private var showingPaywall = false
    @FocusState private var focusedDriver: String?
    private let tabs = ["Overview", "Timing", "Track", "Strategy", "Race Control", "Radio"]
    private var sessionID: String? {
        guard let canonical = match.canonicalID else { return nil }
        return SportsIdentityResolver.providerID(from: BannerEntityID(rawValue: canonical), provider: .f1)
    }
    private var hidden: Bool { preferences.spoilerFreeMode && (model.state?.completed == true || match.state == .final) && !revealed }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let state = model.state {
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        F1SessionHeaderView(state: state, live: model.isLive(at: context.date), connection: model.connection)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text(session?.meeting ?? match.name).font(.title2.bold())
                        Text(session?.name ?? match.statusDetail).font(.headline)
                        if let session {
                            Text(session.start, style: .date); Text(session.start, style: .time)
                            if session.start > .now { Text(session.start, style: .relative).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding().frame(maxWidth: .infinity).background(Theme.surface)
                }
                NavigationLink("Calendar & results") { F1CalendarView() }.font(.caption).frame(minHeight: 44)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(tabs, id: \.self) { item in
                            Button { tab = item } label: { Text(item).font(.subheadline.bold()).frame(minHeight: 44).padding(.horizontal, 8)
                                .background(tab == item ? Theme.surfaceElevated : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .bottom) { if tab == item { Capsule().fill(Theme.accessibleAccent).frame(height: 3) } } }
                                .buttonStyle(.bordered).accessibilityAddTraits(tab == item ? .isSelected : [])
                        }
                    }.padding(8)
                }
                if model.cached { Text("Saved session · \(model.state?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "")").font(.caption).padding(4) }
                if let error = loadError ?? model.error {
                    VStack { Text(error).font(.caption); Button("Retry") { revision += 1 } }.padding(8)
                }
                if entitlements.isPremium {
                    if let state = model.state { content(state, wide: geometry.size.width > 850) }
                    else if let session, session.start > .now {
                        ContentUnavailableView("Session has not started", systemImage: "flag.checkered", description: Text("Live timing appears when Formula 1 publishes this session."))
                    } else if loadError == nil && model.error == nil {
                        VStack(spacing: 18) {
                            ProgressView("Loading Race Centre")
                            ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceElevated).frame(height: 60) }
                        }.padding()
                    } else { ContentUnavailableView("Live timing temporarily unavailable", systemImage: "wifi.exclamationmark") }
                } else {
                    ScrollView {
                        PremiumGateOverlay(icon: "flag.checkered", title: "Race Centre", description: "Timing, strategy, race control and driver telemetry.", showPaywall: $showingPaywall)
                        relatedContent()
                    }
                }
            }.background(Theme.background).foregroundStyle(Theme.textPrimary)
        }.tint(Theme.accessibleAccent)
        .blur(radius: hidden ? 12 : 0).accessibilityHidden(hidden).allowsHitTesting(!hidden)
        .overlay { if hidden { Button("Reveal session result") { revealed = true }.padding().background(Theme.surface, in: Capsule()).accessibilityHidden(false) } }
        .sheet(isPresented: $showingPaywall) {
            #if os(tvOS)
            TVPaywallView()
            #else
            PaywallView()
            #endif
        }
        .task(id: "\(sessionID ?? ""): \(scenePhase == .active): \(revision)") {
            guard let id = sessionID else { loadError = "Open this session from the Formula 1 calendar."; return }
            do {
                guard let found = try await F1CalendarService.shared.session(id: id) else { loadError = "Session unavailable in the Formula 1 calendar."; return }
                guard !Task.isCancelled else { return }
                session = found; loadError = nil
                await model.run(session: found, active: scenePhase == .active)
            } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
        }
        .task {
            var previous: Bool?
            for await connected in SportsConnectivity.changes() {
                if Task.isCancelled { return }
                if connected, previous == false { revision += 1 }
                previous = connected
            }
        }
        #if DEBUG
        .toolbar {
            ToolbarItem {
                Button(recordingURL == nil ? "Record timing" : "Stop recording") {
                    if recordingURL != nil { model.recorder = nil; recordingURL = nil }
                    else {
                        let url = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("F1-\(sessionID ?? "session")-\(Int(Date().timeIntervalSince1970)).jsonl")
                        recordingURL = url; model.recorder = F1FixtureRecorder(url: url); revision += 1
                    }
                }
            }
        }
        #endif
        .onChange(of: focusedDriver) { _, value in if let value { selected = value } }
    }
    @ViewBuilder private func content(_ state: F1SessionState, wide: Bool) -> some View {
        switch tab {
        case "Timing", "Track":
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    if tab == "Track" { F1TrackMapView(session: state, model: model.highFrequency, selected: $selected, showSelectedCard: !wide) }
                    LazyVStack(spacing: 0) {
                        ForEach(state.drivers) { driver in
                            Button { selected = driver.id } label: { F1DriverTimingRow(timing: driver, type: state.type) }
                                .buttonStyle(.plain).focused($focusedDriver, equals: driver.id)
                            if !wide && selected == driver.id { F1DriverDetailView(timing: driver, session: state, highFrequency: model.highFrequency) }
                            Divider()
                        }
                    }.padding().animation(.easeInOut(duration: 0.25), value: state.drivers.map(\.id))
                    if state.drivers.isEmpty { ContentUnavailableView("Timing not yet available", systemImage: "stopwatch") }
                }
                if wide, let driver = state.drivers.first(where: { $0.id == selected }) ?? state.drivers.first {
                    ScrollView { F1DriverDetailView(timing: driver, session: state, highFrequency: model.highFrequency) }.frame(width: 350)
                }
            }
        case "Strategy": ScrollView { F1StrategyView(state: state).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
        case "Race Control": ScrollView { F1RaceControlView(messages: state.messages).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
        case "Radio": ScrollView { F1TeamRadioView(state: state).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let circuit = state.circuit { Label(circuit, systemImage: "mappin.and.ellipse") }
                    ForEach(Array(state.drivers.prefix(3))) { F1DriverTimingRow(timing: $0, type: state.type) }
                    if let fastest = state.drivers.filter({ F1Date.duration($0.bestLap) != nil }).min(by: { (F1Date.duration($0.bestLap) ?? .infinity) < (F1Date.duration($1.bestLap) ?? .infinity) }) {
                        Label("Fastest lap · \(fastest.driver.tla) · \(fastest.bestLap ?? "")", systemImage: "stopwatch.fill").font(.headline)
                    }
                    if let weather = state.weather { F1WeatherView(weather: weather) }
                    if let latest = state.messages.last { Text("Latest race control").font(.headline); F1RaceControlView(messages: [latest]) }
                    relatedContent()
                }.padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
        }
    }
}
