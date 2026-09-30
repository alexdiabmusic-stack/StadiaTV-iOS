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

        let channels: [Channel] = await measure("playlist parse") {
            parsePlaylist(directory: dir)
        }

        let repository = EPGRepository()
        let guideFileURL = dir.appendingPathComponent("guide.xml")
        await measure("guide import") {
            repository.setupWithChannels(channels, customEPGURLs: [guideFileURL])
            await waitForImportSettled(repository)
        }

        let matches: [Match] = await measure("load matches") {
            loadMatches(directory: dir)
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
        let liveChannels = adapterChannels.map { LiveChannel.make(from: $0, providerID: provider.id, kind: provider.kind) }
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

    /// `setupWithChannels` kicks off a fire-and-forget import task with no awaitable
    /// completion signal, so this polls the two published state machines it drives.
    private static func waitForImportSettled(_ repository: EPGRepository, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while repository.importProgress.state != .ready, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var sawRefreshing = false
        while Date() < deadline {
            if repository.refreshState == .refreshing { sawRefreshing = true }
            if sawRefreshing, repository.refreshState != .refreshing { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
