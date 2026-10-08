import Foundation
import Dispatch
import Darwin
import SwiftUI

/// Developer diagnostic tool. Not part of the shipped feature set — gated so it compiles
/// into Debug builds automatically, and into Release builds only when the `GUIDEBENCHMARK`
/// Swift compilation condition is added to that build configuration (see Stage 1 of the
/// guide/matching overhaul plan — perf numbers from a Debug build are not representative).
#if DEBUG || GUIDEBENCHMARK

/// Drives a saved playlist + guide + match-list fixture through the real import/matching
/// pipeline (`EPGRepository`, `StreamAvailabilityStore`) and reports stage timings, memory,
/// main-thread stalls, guide coverage, and confirmed-stream rate. Launch with
/// `-guideBenchmark <fixtureDirectory>`, where the directory contains `playlist.m3u`,
/// `guide.xml`, and `matches.json`.
@MainActor
enum GuideBenchmark {

    static var requestedDirectory: String? {
        UserDefaults.standard.string(forKey: "guideBenchmark")
    }

    private struct MatchFixture: Decodable {
        struct TeamFixture: Decodable {
            let displayName: String
            let shortName: String
            let abbreviation: String
        }
        let id: String
        let leaguePath: String
        let date: Date
        let name: String
        let shortName: String
        let statusDetail: String
        let home: TeamFixture
        let away: TeamFixture
        let broadcasts: [String]
    }

    private struct StageResult {
        let name: String
        let seconds: Double
        let residentMemoryMB: Double
    }

    static func run(directoryPath: String) async {
        let dir = URL(fileURLWithPath: directoryPath)
        print("=== Guide Benchmark ===")
        print("Fixture directory: \(directoryPath)")

        let stallMonitor = MainThreadStallMonitor(thresholdMs: 100)
        stallMonitor.start()

        var stages: [StageResult] = []
        func measure<T>(_ name: String, _ body: () async -> T) async -> T {
            let clockStart = DispatchTime.now()
            let result = await body()
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - clockStart.uptimeNanoseconds
            stages.append(StageResult(name: name, seconds: Double(elapsedNs) / 1_000_000_000, residentMemoryMB: residentMemoryMB()))
            return result
        }

        let isXtreamExport = FileManager.default.fileExists(atPath: dir.appendingPathComponent("streams.json").path)
        let channels: [Channel] = await measure("playlist parse") {
            isXtreamExport ? await parseXtreamExport(directory: dir) : parsePlaylist(directory: dir)
        }
        guard !channels.isEmpty else {
            // EPGRepository.setupWithChannels silently no-ops on an empty channel list
            // (`guard !channels.isEmpty else { return }`), so importProgress.state never
            // reaches .ready and waitForImportSettled would otherwise burn its full 60s
            // timeout before reporting a misleading all-zero benchmark.
            print("GuideBenchmark: 0 channels parsed — aborting (see the parse error printed above)")
            return
        }

        let repository = EPGRepository()
        let guideFileURL = dir.appendingPathComponent(isXtreamExport ? "xmltv.xml" : "guide.xml")
        await measure("guide import") {
            repository.setupWithChannels(channels, customEPGURLs: [guideFileURL])
            await waitForImportSettled(repository)
        }

        let matches: [Match] = await measure("load matches") {
            isXtreamExport ? loadRealEvents(directory: dir) : loadMatches(directory: dir)
        }

        let streamStore = StreamAvailabilityStore()
        await measure("stream matching") {
            await streamStore.scan(matches: matches, channels: channels, epgRepository: repository)
        }

        let stalls = stallMonitor.stop()

        let coveredChannels = repository.canonicalChannels.filter {
            repository.currentProgramme(for: $0.id) != nil || repository.nextProgramme(for: $0.id) != nil
        }.count
        let totalChannels = repository.canonicalChannels.count
        let guideCoveragePct = totalChannels == 0 ? 0 : Double(coveredChannels) / Double(totalChannels) * 100

        let confirmedMatches = matches.filter { streamStore.confirmedCount(for: $0.id) > 0 }.count
        let confirmedPct = matches.isEmpty ? 0 : Double(confirmedMatches) / Double(matches.count) * 100

        print("\n--- Stage times & memory ---")
        for stage in stages {
            let namePadded = stage.name.padding(toLength: 20, withPad: " ", startingAt: 0)
            let timeStr = String(format: "%8.3fs", stage.seconds)
            let memStr = String(format: "%8.1f MB resident", stage.residentMemoryMB)
            print("\(namePadded) \(timeStr)  \(memStr)")
        }

        print("\n--- Main-thread stalls > 100ms ---")
        if stalls.isEmpty {
            print("none")
        } else {
            for stall in stalls {
                print(String(format: "  %.1f ms", stall))
            }
            print(String(format: "count=%d max=%.1fms", stalls.count, stalls.max() ?? 0))
        }

        print("\n--- Coverage ---")
        print("channels: \(totalChannels), programmes retained: \(repository.importProgress.programmesRetained)")
        print(String(format: "guide coverage: %.1f%% (%d/%d channels)", guideCoveragePct, coveredChannels, totalChannels))
        print(String(format: "games with confirmed stream: %.1f%% (%d/%d matches)", confirmedPct, confirmedMatches, matches.count))
        print("========================")

        writeJSONReport(
            to: dir.appendingPathComponent("benchmark.json"), stages: stages, stalls: stalls,
            totalChannels: totalChannels, coveredChannels: coveredChannels,
            programmesRetained: repository.importProgress.programmesRetained,
            matchesTotal: matches.count, matchesConfirmed: confirmedMatches
        )
    }

    private static func writeJSONReport(
        to url: URL, stages: [StageResult], stalls: [Double],
        totalChannels: Int, coveredChannels: Int, programmesRetained: Int,
        matchesTotal: Int, matchesConfirmed: Int
    ) {
        let report: [String: Any] = [
            "stages": stages.map { ["name": $0.name, "seconds": $0.seconds, "residentMemoryMB": $0.residentMemoryMB] },
            "mainThreadStallsMs": stalls,
            "coverage": [
                "channels": totalChannels,
                "channelsWithProgrammes": coveredChannels,
                "programmesRetained": programmesRetained,
                "matchesTotal": matchesTotal,
                "matchesConfirmed": matchesConfirmed,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }

    private static func parsePlaylist(directory: URL) -> [Channel] {
        let playlistURL = directory.appendingPathComponent("playlist.m3u")
        guard let text = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            print("GuideBenchmark: could not read playlist.m3u at \(playlistURL.path)")
            return []
        }
        let (_, adapterChannels) = M3UProviderAdapter.parseM3U(text)
        // Dummy m3uURL: parsing runs directly on the local file's text above, so this
        // URL is never fetched — it only satisfies Playlist/LiveProvider's field.
        let playlist = Playlist(name: "GuideBenchmark", kind: .m3u, m3uURL: "https://benchmark.invalid/playlist.m3u")
        let provider = LiveProvider(playlist: playlist)
        let liveChannels = LiveChannel.makeAll(from: adapterChannels, providerID: provider.id, kind: provider.kind)
        return liveChannels.map { $0.asChannel(playlistName: playlist.name, defaultUserAgent: playlist.userAgent) }
    }

    private static func loadMatches(directory: URL) -> [Match] {
        let matchesURL = directory.appendingPathComponent("matches.json")
        guard let data = try? Data(contentsOf: matchesURL) else {
            print("GuideBenchmark: could not read matches.json at \(matchesURL.path)")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let fixtures = try? decoder.decode([MatchFixture].self, from: data) else {
            print("GuideBenchmark: could not decode matches.json")
            return []
        }
        return fixtures.map { fixture in
            let league = League.all.first { $0.path == fixture.leaguePath } ?? League.all[0]
            return Match(
                id: fixture.id,
                league: league,
                date: fixture.date,
                name: fixture.name,
                shortName: fixture.shortName,
                state: .live,
                statusDetail: fixture.statusDetail,
                home: TeamSide(displayName: fixture.home.displayName, shortName: fixture.home.shortName, abbreviation: fixture.home.abbreviation, logoURL: nil, score: nil, record: nil, isWinner: false),
                away: TeamSide(displayName: fixture.away.displayName, shortName: fixture.away.shortName, abbreviation: fixture.away.abbreviation, logoURL: nil, score: nil, record: nil, isWinner: false),
                broadcasts: fixture.broadcasts,
                venue: nil
            )
        }
    }

    /// Real `MatchLinker/Scripts/export_playlist.sh` + `export_events.py` output: `streams.json`
    /// / `cats.json` (Xtream `get_live_streams` / `get_live_categories`), `xmltv.xml` (the
    /// provider's own guide) and `events.json`. Drives the real `XtreamProviderAdapter` with a
    /// stub `URLProtocol` that answers only the two `player_api.php` calls from those two JSON
    /// files — no network, no credentials beyond a throwaway Keychain entry deleted right after.
    private static func parseXtreamExport(directory: URL) async -> [Channel] {
        guard let catsData = try? Data(contentsOf: directory.appendingPathComponent("cats.json")),
              let streamsData = try? Data(contentsOf: directory.appendingPathComponent("streams.json")) else {
            print("GuideBenchmark: could not read cats.json/streams.json in \(directory.path)")
            return []
        }
        GuideBenchmarkStubURLProtocol.catsData = catsData
        GuideBenchmarkStubURLProtocol.streamsData = streamsData
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GuideBenchmarkStubURLProtocol.self]
        let session = URLSession(configuration: config)

        let credentialID = UUID()
        try? KeychainStore.saveXtreamCredentials(XtreamCredentials(username: "stub", password: "stub"), for: credentialID)
        defer { KeychainStore.deleteXtreamCredentials(for: credentialID) }

        let playlist = Playlist(name: "GuideBenchmark", kind: .xtream, host: "http://benchmark.invalid", credentialID: credentialID)
        let provider = LiveProvider(playlist: playlist)
        let adapter = XtreamProviderAdapter(provider: provider, session: session)
        guard let (_, adapterChannels) = try? await adapter.loadChannels() else {
            print("GuideBenchmark: XtreamProviderAdapter.loadChannels() failed")
            return []
        }
        let liveChannels = LiveChannel.makeAll(from: adapterChannels, providerID: provider.id, kind: provider.kind)
        return liveChannels.map { $0.asChannel(playlistName: playlist.name, defaultUserAgent: playlist.userAgent) }
    }

    /// `export_events.py`'s real shape: `{league, id, date, name, home:{name,short,abbr,nick,
    /// city}, away:{...}, broadcasts, state}`, dates as `yyyy-MM-dd'T'HH:mm'Z'` (no seconds) —
    /// the same shape `linker-cli` reads, so results are directly comparable to it.
    private static func loadRealEvents(directory: URL) -> [Match] {
        struct EventFixture: Decodable {
            struct TeamFixture: Decodable { let name: String; let short: String?; let abbr: String? }
            let league: String
            let id: String
            let date: String
            let name: String
            let home: TeamFixture
            let away: TeamFixture
            let broadcasts: [String]
            let state: String?
        }
        let eventsURL = directory.appendingPathComponent("events.json")
        guard let data = try? Data(contentsOf: eventsURL),
              let fixtures = try? JSONDecoder().decode([EventFixture].self, from: data) else {
            print("GuideBenchmark: could not read/decode events.json at \(eventsURL.path)")
            return []
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return fixtures.compactMap { fixture in
            guard let date = fmt.date(from: fixture.date) else { return nil }
            let league = League.all.first { $0.path == fixture.league } ?? League.all[0]
            let state: GameState = fixture.state == "live" ? .live : (fixture.state == "final" ? .final : .pre)
            return Match(
                id: fixture.id, league: league, date: date, name: fixture.name,
                shortName: "\(fixture.away.abbr ?? "") @ \(fixture.home.abbr ?? "")", state: state,
                statusDetail: "",
                home: TeamSide(displayName: fixture.home.name, shortName: fixture.home.short ?? fixture.home.name, abbreviation: fixture.home.abbr ?? "", logoURL: nil, score: nil, record: nil, isWinner: false),
                away: TeamSide(displayName: fixture.away.name, shortName: fixture.away.short ?? fixture.away.name, abbreviation: fixture.away.abbr ?? "", logoURL: nil, score: nil, record: nil, isWinner: false),
                broadcasts: fixture.broadcasts, venue: nil
            )
        }
    }

    /// `setupWithChannels` kicks off a fire-and-forget import task with no awaitable
    /// completion signal, so this polls the published state it drives.
    private static func waitForImportSettled(_ repository: EPGRepository, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while repository.importProgress.state != .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // The scheduled custom-EPG refresh (which is what actually parses customEPGURLs,
        // right after the initial import reaches .ready) always bumps lastUpdated exactly
        // once when it completes — a one-shot, unambiguous signal. Polling refreshState
        // == .refreshing instead was a race: a refresh fast enough to start and finish
        // between two 50ms polls could flip through that value without ever being observed,
        // burning the full timeout.
        let initialLastUpdated = repository.lastUpdated
        while repository.lastUpdated == initialLastUpdated, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // Give any in-flight finalize/persist a brief moment to land.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}

/// Detects turns of the main run loop that block longer than `thresholdMs` by chaining
/// `DispatchQueue.main.async` heartbeats and watching the gap between them from a
/// background timer. Not `@MainActor` — it deliberately owns its own locking so the
/// background timer can read the heartbeat without hopping onto the (possibly stalled) main actor.
private final class MainThreadStallMonitor {
    private let thresholdMs: Double
    private let lock = NSLock()
    private var lastHeartbeat = Date()
    private var stalls: [Double] = []
    private var timer: DispatchSourceTimer?
    private var running = false
    private let monitorQueue = DispatchQueue(label: "com.stadiatv.guidebenchmark.stallmonitor")

    init(thresholdMs: Double) {
        self.thresholdMs = thresholdMs
    }

    func start() {
        running = true
        heartbeat()
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        self.timer = timer
    }

    func stop() -> [Double] {
        running = false
        timer?.cancel()
        timer = nil
        lock.lock()
        defer { lock.unlock() }
        return stalls
    }

    private func heartbeat() {
        guard running else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.lock.lock()
            self.lastHeartbeat = Date()
            self.lock.unlock()
            self.heartbeat()
        }
    }

    private func checkForStall() {
        lock.lock()
        let gapMs = Date().timeIntervalSince(lastHeartbeat) * 1000
        if gapMs > thresholdMs {
            stalls.append(gapMs)
        }
        lock.unlock()
    }
}

/// Answers `player_api.php?...action=get_live_categories` / `get_live_streams` from
/// pre-loaded export data, so `XtreamProviderAdapter` runs against a real playlist export
/// with no network and no live account. `xmltv.php` is not stubbed: the guide is instead
/// handed to `EPGRepository` directly as a local `file://` URL via `customEPGURLs`.
private final class GuideBenchmarkStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var catsData = Data()
    nonisolated(unsafe) static var streamsData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/player_api.php"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let data: Data
        switch action {
        case "get_live_categories": data = Self.catsData
        case "get_live_streams": data = Self.streamsData
        default: data = Data("[]".utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct GuideBenchmarkRunnerView: View {
    let directory: String
    @State private var started = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Running guide benchmark…")
        }
        .task {
            guard !started else { return }
            started = true
            await GuideBenchmark.run(directoryPath: directory)
            exit(0)
        }
    }
}

#endif
