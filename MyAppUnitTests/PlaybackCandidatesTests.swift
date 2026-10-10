import Foundation
import Testing
@testable import BannerTV

/// Which URLs a channel is tried as, in what order, and the memory of which format worked.
@Suite("Playback candidates")
struct PlaybackCandidatesTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("An Xtream HLS URL is tried as it is, then as its transport stream, which is converted")
    func xtreamHLS() {
        let hls = url("http://panel.example:8080/live/user/pass/123.m3u8")
        let candidates = PlaybackCandidates.candidates(for: hls, prefersTransportStream: false)
        #expect(candidates == [
            PlaybackCandidate(url: hls, source: .direct),
            PlaybackCandidate(url: url("http://panel.example:8080/live/user/pass/123.ts"), source: .convertedTransportStream),
        ])
    }

    @Test("Where the transport stream has worked, it goes first")
    func transportFirst() {
        let hls = url("http://panel.example/live/user/pass/123.m3u8")
        let candidates = PlaybackCandidates.candidates(for: hls, prefersTransportStream: true)
        #expect(candidates.map(\.source) == [.convertedTransportStream, .direct])
        #expect(candidates.map(\.url.absoluteString) == ["http://panel.example/live/user/pass/123.ts", hls.absoluteString])
    }

    @Test("A playlist's .ts or extension-less URL is tried as HLS, then converted as it stands")
    func transportURLs() {
        let ts = url("http://host:8080/live/user/pass/123.ts")
        #expect(PlaybackCandidates.candidates(for: ts, prefersTransportStream: false) == [
            PlaybackCandidate(url: url("http://host:8080/live/user/pass/123.m3u8"), source: .direct),
            PlaybackCandidate(url: ts, source: .convertedTransportStream),
        ])
        let bare = url("http://host/user/pass/42")
        let candidates = PlaybackCandidates.candidates(for: bare, prefersTransportStream: false)
        #expect(candidates.first?.url.absoluteString == "http://host/live/user/pass/42.m3u8")
        #expect(candidates.last == PlaybackCandidate(url: bare, source: .convertedTransportStream))
    }

    @Test("Other URLs: HLS from a CDN is played as it is, and any other .ts is converted, then given to the player as it is")
    func otherURLs() {
        let cdn = url("https://cdn.example/live/master.m3u8")
        #expect(PlaybackCandidates.candidates(for: cdn, prefersTransportStream: false) == [PlaybackCandidate(url: cdn, source: .direct)])
        #expect(PlaybackCandidates.candidates(for: cdn, prefersTransportStream: true) == [PlaybackCandidate(url: cdn, source: .direct)],
                "nothing to prefer")
        // A panel can name an HLS playlist `.ts`: the converter refuses it at once, and the player then gets it as it is.
        let stream = url("http://host/channels/espn.ts")
        let expected = [PlaybackCandidate(url: stream, source: .convertedTransportStream), PlaybackCandidate(url: stream, source: .direct)]
        #expect(PlaybackCandidates.candidates(for: stream, prefersTransportStream: false) == expected)
        #expect(PlaybackCandidates.candidates(for: stream, prefersTransportStream: true) == expected)
        let mp4 = url("http://host/movie.mp4")
        #expect(PlaybackCandidates.candidates(for: mp4, prefersTransportStream: false) == [PlaybackCandidate(url: mp4, source: .direct)])
        let nothing = url("about:blank")
        #expect(PlaybackCandidates.candidates(for: nothing, prefersTransportStream: false) == [PlaybackCandidate(url: nothing, source: .direct)])
    }

    @Test("A username or password with a slash in it keeps its encoding, so the URL still names the same stream")
    func awkwardCredentials() {
        // The adapter encodes `/`, `?` and `%` in credentials; they must not be taken for path separators.
        let hls = url("http://host/live/us%2Fer/p%3Fss/55.m3u8")
        let transport = PlaybackCandidates.xtreamURL(hls, extension: "ts")
        #expect(transport?.absoluteString == "http://host/live/us%2Fer/p%3Fss/55.ts")
        #expect(PlaybackCandidates.xtreamHLSURL(for: url("http://host/us%2Fer/p%3Fss/55"))?.absoluteString == "http://host/live/us%2Fer/p%3Fss/55.m3u8")
    }

    @Test("Only a numeric stream id in an Xtream-shaped path counts")
    func shapes() {
        #expect(PlaybackCandidates.xtreamURL(url("http://host/live/u/p/abc.m3u8"), extension: "ts") == nil)
        #expect(PlaybackCandidates.xtreamURL(url("http://host/live/u/p/12.mp4"), extension: "ts") == nil)
        #expect(PlaybackCandidates.xtreamURL(url("http://host/u/p"), extension: "ts") == nil)
        #expect(PlaybackCandidates.xtreamURL(url("ftp://host/live/u/p/12.m3u8"), extension: "ts") == nil)
        #expect(PlaybackCandidates.xtreamHLSURL(for: url("http://host/live/u/p/12.m3u8")) == nil, "already HLS")
        #expect(PlaybackCandidates.xtreamHLSURL(for: url("http://host:81/live/u/p/12.ts"))?.absoluteString == "http://host:81/live/u/p/12.m3u8")
    }

    @Test("A provider is remembered as needing the converter for two weeks, and HLS working again forgets that")
    func memory() throws {
        let suite = "PlaybackCandidatesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let memory = PlaybackFormatMemory(defaults: defaults, now: { clock.now })
        let channel = url("http://panel.example:8080/live/user/pass/123.m3u8")
        let sibling = url("http://panel.example:8080/live/other/word/999.m3u8")
        let elsewhere = url("http://another.example/live/user/pass/123.m3u8")

        #expect(!memory.prefersTransportStream(for: channel))
        memory.record(.convertedTransportStream, for: channel)
        #expect(memory.prefersTransportStream(for: channel))
        #expect(memory.prefersTransportStream(for: sibling), "the same provider, whatever the channel or account")
        #expect(!memory.prefersTransportStream(for: elsewhere))

        clock.advance(13 * 24 * 3600)
        #expect(memory.prefersTransportStream(for: channel))
        clock.advance(2 * 24 * 3600)
        #expect(!memory.prefersTransportStream(for: channel), "forgotten, so HLS is given another chance")

        memory.record(.convertedTransportStream, for: channel)
        memory.record(.direct, for: channel)
        #expect(!memory.prefersTransportStream(for: channel))
    }

    @Test("A URL with no host is never remembered")
    func noHost() throws {
        let suite = "PlaybackCandidatesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = PlaybackFormatMemory(defaults: defaults)
        memory.record(.convertedTransportStream, for: url("about:blank"))
        #expect(!memory.prefersTransportStream(for: url("about:blank")))
    }
}

/// A clock a test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}
