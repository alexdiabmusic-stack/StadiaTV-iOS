import Foundation
import Testing
@testable import BannerTV

/// Regression coverage for two bugs found in an independent re-audit of Prompt 3
/// (MatchLinker/PROMPTS.md) after the prior session's commit claimed it done:
///
/// - The retention window used for the real guide import was still -14h/+36h (the exact
///   window Prompt 2's "Why" names as a cause of missed games), not the -6h/+72h Prompt 3
///   step 2 specifies — a programme 36-72h out was silently discarded.
/// - `EPGRepository.importIfChanged`'s import task called `rebuildChannelToCanonicalMap()`
///   before assigning `unresolvedStreams`, so an unresolved stream's own guide id never made
///   it into `channelToCanonicalMap` for that import cycle, and `forceRefresh()` never set
///   `importProgress.state` back to `.ready` after the first scheduled refresh — both fixed in
///   the same pass as the retention window.
///
/// This exercises the real import pipeline end to end (a stubbed `URLProtocol` isn't needed
/// here — `customEPGURLs` accepts any URL `URLSession.download` can fetch, including a local
/// `file://` one) rather than unit-testing the now-private pieces individually.
@MainActor
@Suite("EPGRepository guide import (Prompt 3 regressions)")
struct EPGRepositoryGuideImportTests {

    @Test("A programme 36-72h out is retained, and importProgress.state settles back to .ready")
    func widenedRetentionWindowAndStableReadyState() async throws {
        let repository = EPGRepository()
        let playlistID = UUID()

        // A name/tvg-id pair virtually guaranteed not to match the curated catalog, so this
        // exercises the "unresolved stream" path `rebuildChannelToCanonicalMap()`'s ordering
        // bug affected.
        let channel = Channel(
            id: "test-channel-zzz", name: "ZZZ Unmatched Test Channel 48219",
            streamURL: URL(string: "https://example.com/s.m3u8")!, logoURL: nil, group: "Sports",
            playlistID: playlistID, playlistName: "Test", tvgId: "zzz.test.48219"
        )

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMddHHmmss Z"
        // Beyond the old +36h window; inside the new +72h one.
        let start = Date().addingTimeInterval(48 * 3600)
        let end = start.addingTimeInterval(3 * 3600)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="zzz.test.48219"><display-name>ZZZ Unmatched Test Channel 48219</display-name></channel>
          <programme start="\(fmt.string(from: start))" stop="\(fmt.string(from: end))" channel="zzz.test.48219">
            <title>Distant Game</title>
          </programme>
        </tv>
        """
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        repository.setupWithChannels([channel], customEPGURLs: [fileURL])

        let deadline = Date().addingTimeInterval(20)
        var found = false
        while Date() < deadline {
            if repository.nextProgramme(for: "test-channel-zzz") != nil { found = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(found, "a programme 48h out was not retained — retention window regression")

        // Give the scheduled refresh (which is what actually parses customEPGURLs) a moment
        // to fully settle, then confirm state didn't get stuck at .loadingEPG.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(repository.importProgress.state == .ready, "importProgress.state got stuck instead of returning to .ready")
    }
}
