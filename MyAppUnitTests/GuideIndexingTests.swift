import Foundation
import Testing
@testable import BannerTV

/// The pure pieces of the guide pipeline (`GuideIndexing.swift`): no network, no store, no main actor.
@Suite("Guide indexing")
struct GuideIndexingTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func programme(
        _ title: String, guideId: String = "g1", source: String = "custom-0", priority: Int = 0,
        at minutes: Double, for length: Double = 60
    ) -> EPGProgramme {
        EPGProgramme(
            id: "\(guideId)-\(title)", epgChannelId: guideId, canonicalChannelId: nil, title: title,
            subtitle: nil, description: nil, categories: [],
            start: base.addingTimeInterval(minutes * 60), end: base.addingTimeInterval((minutes + length) * 60),
            imageURL: nil, season: nil, episode: nil, rating: nil,
            sourceId: source, sourcePriority: priority, endTimeIsInferred: false
        )
    }

    private func titles(_ programmes: [EPGProgramme]) -> [String] { programmes.map(\.title) }

    // MARK: Schedules

    @Test("Back-to-back programmes are all kept")
    func keepsSequentialProgrammes() {
        let result = GuideProgrammeIndexing.deduplicated([programme("A", at: 0), programme("B", at: 60)])
        #expect(titles(result) == ["A", "B"])
    }

    @Test("Where equal-priority programmes overlap, the earlier one wins")
    func dropsOverlapFromEqualPriority() {
        let result = GuideProgrammeIndexing.deduplicated([programme("A", at: 0), programme("B", at: 30)])
        #expect(titles(result) == ["A"])
    }

    @Test("Where programmes overlap, the lower source priority wins")
    func prefersLowerSourcePriority() {
        let result = GuideProgrammeIndexing.deduplicated([programme("A", priority: 1, at: 0), programme("B", priority: 0, at: 30)])
        #expect(titles(result) == ["B"])
    }

    @Test("Merging sorts by start and removes overlaps")
    func mergedSortsAndDeduplicates() {
        let existing = [programme("B", at: 60)]
        let adding = [programme("C", at: 120), programme("A", at: 0), programme("A again", at: 10)]
        #expect(titles(GuideProgrammeIndexing.merged(existing, adding: adding)) == ["A", "B", "C"])
    }

    @Test("Removing a source leaves the others, and drops channels left empty")
    func removingASource() {
        let index = [
            "c1": [programme("Custom", at: 0), programme("Top-up", source: "xtream", priority: 1, at: 120)],
            "c2": [programme("Only custom", at: 0)],
        ]
        let result = GuideProgrammeIndexing.removing(sourceId: "custom-0", from: index)
        #expect(result.keys.sorted() == ["c1"])
        #expect(titles(result["c1"] ?? []) == ["Top-up"])
        #expect(GuideProgrammeIndexing.removing(sourceId: "nobody", from: index).count == 2)
    }

    @Test("A window query returns exactly what a linear filter would, including at the edges")
    func overlappingWindow() {
        let schedule = [programme("A", at: 0), programme("B", at: 60), programme("C", at: 120, for: 30), programme("D", at: 200)]
        func titles(_ from: Double, _ to: Double) -> [String] {
            GuideProgrammeIndexing.overlapping(schedule, from: base.addingTimeInterval(from * 60), to: base.addingTimeInterval(to * 60)).map(\.title)
        }
        #expect(titles(-100, -10).isEmpty, "before everything")
        #expect(titles(400, 500).isEmpty, "after everything")
        #expect(titles(0, 1) == ["A"])
        #expect(titles(60, 61) == ["B"], "A ends exactly as the window starts")
        #expect(titles(59, 60) == ["A"], "B starts exactly as the window ends")
        #expect(titles(30, 130) == ["A", "B", "C"])
        #expect(titles(155, 195).isEmpty, "a gap")
        #expect(titles(-1000, 1000) == ["A", "B", "C", "D"])
        #expect(GuideProgrammeIndexing.overlapping([], from: base, to: base.addingTimeInterval(60)).isEmpty)
    }

    @Test("On schedules built the way the repository builds them, the window query matches a linear filter")
    func overlappingMatchesLinearFilter() {
        struct Generator: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
        }
        var rng = Generator(state: 7)
        for _ in 0..<300 {
            // Overlapping programmes from sources of different priority, as one channel can get.
            let raw = (0..<Int.random(in: 0...60, using: &rng)).map { index in
                programme("P\(index)", priority: Int.random(in: 0...2, using: &rng),
                          at: Double.random(in: 0...2000, using: &rng), for: Double.random(in: 2...180, using: &rng))
            }
            let schedule = GuideProgrammeIndexing.deduplicated(raw.sorted { $0.start < $1.start })
            #expect(zip(schedule, schedule.dropFirst()).allSatisfy { $0.end <= $1.start }, "deduplicated schedules don't overlap")
            for _ in 0..<20 {
                let from = base.addingTimeInterval(Double.random(in: -100...2100, using: &rng) * 60)
                let to = from.addingTimeInterval(Double.random(in: 1...400, using: &rng) * 60)
                #expect(Array(GuideProgrammeIndexing.overlapping(schedule, from: from, to: to)) == schedule.filter { $0.end > from && $0.start < to })
            }
        }
    }

    @Test("Coverage spans the first start to the last end")
    func coverage() {
        #expect(GuideProgrammeIndexing.coverage(of: [], channelId: "c1") == nil)
        let programmes = [programme("A", at: 0), programme("B", at: 60, for: 120)]
        let coverage = GuideProgrammeIndexing.coverage(of: programmes, channelId: "c1")
        #expect(coverage?.earliestStart == base)
        #expect(coverage?.latestEnd == base.addingTimeInterval(180 * 60))
        #expect(coverage?.programmeCount == 2)
    }

    // MARK: Rebuilding from the store

    @Test("Stored programmes are regrouped by canonical channel, in order, resolving each guide id once")
    func hydrated() {
        let stored = [
            programme("Late", guideId: "g1", at: 60),
            programme("Early", guideId: "g1", at: 0),
            programme("Other feed", guideId: "g2", at: 120),
            programme("Nobody's", guideId: "g3", at: 0),
            programme("Too short", guideId: "g1", at: 200, for: 0),
        ]
        var lookups: [String] = []
        let result = GuideProgrammeIndexing.hydrated(from: stored) { guideId in
            lookups.append(guideId)
            switch guideId {
            case "g1", "g2": return "canonical"
            default: return nil
            }
        }
        #expect(result.keys.sorted() == ["canonical"])
        #expect(titles(result["canonical"] ?? []) == ["Early", "Late", "Other feed"])
        #expect(result["canonical"]?.allSatisfy { $0.canonicalChannelId == "canonical" } == true)
        #expect(lookups.sorted() == ["g1", "g2", "g3"])
    }

    // MARK: Matching a playlist's own guide

    @Test("Guide channels match by tvg-id (any case), then by normalised display name")
    func customMatching() {
        let lookup = CustomEPGLookup(
            tvgIdToProvider: ["espn.us": "p-espn"],
            nameToProvider: ["fs1": "p-fs1", "orphan": "p-orphan"]
        )
        let canonical = ["p-espn": "us-espn", "p-fs1": "us-fs1"]
        let channels = [
            EPGChannel(id: "ESPN.US", displayNames: ["Something else"], iconURL: nil, sourceId: "custom-0"),
            EPGChannel(id: "fox.1", displayNames: ["Unknown", "FS1 HD"], iconURL: nil, sourceId: "custom-0"),
            EPGChannel(id: "nobody", displayNames: ["No such channel"], iconURL: nil, sourceId: "custom-0"),
            EPGChannel(id: "orphan.1", displayNames: ["Orphan"], iconURL: nil, sourceId: "custom-0"),
        ]
        let result = CustomEPGMatcher.match(channels, lookup: lookup, channelToCanonical: canonical) {
            $0.replacingOccurrences(of: " HD", with: "")
        }
        #expect(result["ESPN.US"] == CustomEPGMatch(canonicalChannelId: "us-espn", providerChannelId: "p-espn"))
        #expect(result["fox.1"] == CustomEPGMatch(canonicalChannelId: "us-fs1", providerChannelId: "p-fs1"))
        #expect(result["nobody"] == nil)
        #expect(result["orphan.1"] == nil, "a stream that isn't part of any canonical channel can't take the guide")
    }

    @Test("Each distinct display name is normalised once")
    func normalisationIsCached() {
        let lookup = CustomEPGLookup(nameToProvider: ["fs1": "p-fs1"])
        let channels = (0..<5).map {
            EPGChannel(id: "id\($0)", displayNames: ["FS1 HD"], iconURL: nil, sourceId: "custom-0")
        }
        var calls = 0
        let result = CustomEPGMatcher.match(channels, lookup: lookup, channelToCanonical: ["p-fs1": "us-fs1"]) { name in
            calls += 1
            return name.replacingOccurrences(of: " HD", with: "")
        }
        #expect(result.count == 5)
        #expect(calls == 1)
    }
}

@Suite("Programme store")
struct EPGProgrammeStoreTests {

    @Test("An in-memory store is private to itself and leaves no file behind")
    func inMemoryStoresArePrivate() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let programme = EPGProgramme(
            id: "g1-1", epgChannelId: "g1", canonicalChannelId: nil, title: "Show", subtitle: nil, description: nil, categories: [],
            start: start, end: start.addingTimeInterval(3600), imageURL: nil, season: nil, episode: nil, rating: nil,
            sourceId: "custom-0", sourcePriority: 0, endTimeIsInferred: false
        )
        let first = try EPGProgrammeStore.inMemory()
        let second = try EPGProgrammeStore.inMemory()
        try await first.replaceProgrammes([programme], sourceId: "custom-0")

        let window = start.addingTimeInterval(-3600)...start.addingTimeInterval(7200)
        #expect(try await first.snapshot(from: window.lowerBound, to: window.upperBound).map(\.title) == ["Show"])
        #expect(try await second.snapshot(from: window.lowerBound, to: window.upperBound).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ":memory:"))
    }
}
