import Foundation
import Testing
@testable import BannerTV

// Prompt 8 of MatchLinker/PROMPTS.md: budgets and an opt-in real-fixture integration test, so
// the match rate and the speed don't regress silently.

#if !DEBUG
/// Release-only: Debug timings run ~10x slower and aren't representative (see MatchLinker/
/// PROMPTS.md, "How to work" #3), so this budget would be meaningless — and spuriously flaky —
/// in a Debug test run.
@Suite("StreamLinker performance budgets (Release only)")
struct StreamLinkerBudgetTests {

    @Test("Index build and median link time stay within budget on a synthetic 22k-channel playlist")
    func buildAndLinkBudgets() {
        // Mirrors the shape MatchLinker/README.md measures against: 22,304 channels, ~115k
        // programmes in a 60-hour window, ~4,700 distinct guide ids shared across mirrors.
        let streams = (0..<22_000).map { i in
            LinkerStream(id: "s\(i)", name: "US ★ Channel \(i) HD", category: "US ❖ SPORTS", guideID: "guide\(i % 4_700)")
        }
        let now = Date()
        let programmes = (0..<115_000).map { i -> LinkerProgramme in
            let start = now.addingTimeInterval(TimeInterval(i % 60) * 3600)
            return LinkerProgramme(
                guideID: "guide\(i % 4_700)", start: start, end: start.addingTimeInterval(3600),
                title: "Programme \(i)", desc: nil
            )
        }

        let buildStart = Date()
        let linker = StreamLinker(streams: streams, programmes: programmes)
        let buildTime = Date().timeIntervalSince(buildStart)
        #expect(buildTime < 1.5, "index build took \(buildTime)s, budget is 1.5s")

        let events = (0..<50).map { i in
            LinkerEvent(
                id: "e\(i)", league: "hockey/nhl", kickoff: now,
                home: LinkerTeam(name: "Home Team \(i)"), away: LinkerTeam(name: "Away Team \(i)")
            )
        }
        let linkTimes: [TimeInterval] = events.map { event in
            let t0 = Date()
            _ = linker.link(event)
            return Date().timeIntervalSince(t0)
        }
        let median = linkTimes.sorted()[linkTimes.count / 2]
        #expect(median < 0.005, "median link took \(median * 1000)ms, budget is 5ms")
    }
}
#endif

/// Opt-in: set `LINKER_FIXTURE_DIR` to a real export folder (streams.json/cats.json/
/// guide_window.json, from MatchLinker/Scripts/export_playlist.sh +
/// export_guide_window.py) to link the bundled `MatchLinker/Fixtures/events_next48h.json`
/// against it. Skipped (passes trivially) when the variable isn't set — never commit an
/// export folder, so this can't run unattended in CI without one being provided out of band.
@Suite("StreamLinker real-fixture integration (opt-in)")
struct StreamLinkerFixtureIntegrationTests {

    @Test("Linking real exported fixtures never throws, and every option has a stream id")
    func fixtureIntegration() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["LINKER_FIXTURE_DIR"] else { return }
        let dir = URL(fileURLWithPath: dirPath)

        let cats = try decode([XtreamCatalogCategory].self, from: dir.appendingPathComponent("cats.json"))
        let categoryNames = Dictionary(uniqueKeysWithValues: cats.map { ($0.category_id, $0.category_name) })
        let rawStreams = try decode([XtreamCatalogStream].self, from: dir.appendingPathComponent("streams.json"))
        let streams = rawStreams.map { s in
            LinkerStream(
                id: String(s.stream_id), name: s.name,
                category: s.category_id.flatMap { categoryNames[$0] } ?? "",
                guideID: (s.epg_channel_id?.isEmpty ?? true) ? nil : s.epg_channel_id
            )
        }

        let guideRows = try decode([[JSONAny]].self, from: dir.appendingPathComponent("guide_window.json"))
        let programmes: [LinkerProgramme] = guideRows.compactMap { row in
            guard row.count >= 4,
                  let guideID = row[0].stringValue, let start = row[1].doubleValue, let end = row[2].doubleValue,
                  let title = row[3].stringValue else { return nil }
            let desc = row.count > 4 ? row[4].stringValue : nil
            return LinkerProgramme(guideID: guideID, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), title: title, desc: desc)
        }

        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MatchLinker/Fixtures/events_next48h.json")
        let events = try decode([LinkerEventFixture].self, from: fixturesURL)

        let linker = StreamLinker(streams: streams, programmes: programmes)
        var linkTimes: [TimeInterval] = []
        for fixture in events {
            let event = fixture.asLinkerEvent()
            let t0 = Date()
            let feeds = linker.link(event)
            linkTimes.append(Date().timeIntervalSince(t0))
            for feed in feeds {
                #expect(!feed.streamIDs.isEmpty, "\(fixture.name) produced an option with no stream ids")
            }
        }
        guard !linkTimes.isEmpty else { return }
        let median = linkTimes.sorted()[linkTimes.count / 2]
        #expect(median < 0.005, "median link took \(median * 1000)ms, budget is 5ms")
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

private struct XtreamCatalogCategory: Decodable { let category_id: String; let category_name: String }
private struct XtreamCatalogStream: Decodable { let stream_id: Int; let name: String; let category_id: String?; let epg_channel_id: String? }

/// Loosely-typed JSON value for `guide_window.json` rows (`[guideID, startUnix, endUnix, title,
/// desc]`), which mix strings and numbers in one array — `JSONDecoder` has no "any" type.
private enum JSONAny: Decodable {
    case string(String), double(Double), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .null }
    }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? { if case .double(let d) = self { return d }; return nil }
}

private struct LinkerEventFixture: Decodable {
    struct TeamFixture: Decodable { let name: String; let short: String?; let abbr: String?; let nick: String?; let city: String? }
    let league: String
    let id: String
    let date: String
    let name: String
    let home: TeamFixture
    let away: TeamFixture
    let broadcasts: [String]

    func asLinkerEvent() -> LinkerEvent {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        let kickoff = fmt.date(from: date) ?? Date()
        func team(_ t: TeamFixture) -> LinkerTeam { LinkerTeam(name: t.name, short: t.short, nick: t.nick, city: t.city, abbr: t.abbr) }
        let nationalKeys = ["fifa.", "uefa.nations", "uefa.euro", "concacaf.nations", "worldq"]
        return LinkerEvent(id: id, league: league, kickoff: kickoff, home: team(home), away: team(away),
                            broadcasts: broadcasts, isNational: nationalKeys.contains { league.contains($0) })
    }
}
