import Foundation
import Testing
@testable import BannerTV

@Suite("M3U provider headers")
struct M3UHeaderParsingTests {
    private func parse(_ text: String) -> [AdapterChannel] {
        M3UProviderAdapter.parseM3U(text).channels
    }

    @Test func extvlcoptUserAgentAndReferrerApplyToNextURL() {
        let channels = parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="a",Channel A
        #EXTVLCOPT:http-user-agent=VLC/3.0.20
        #EXTVLCOPT:http-referrer=https://example.com/
        #EXTVLCOPT:http-reconnect=true
        http://host/a.m3u8
        #EXTINF:-1,Channel B
        http://host/b.m3u8
        """)
        #expect(channels.count == 2)
        #expect(channels[0].httpHeaders == ["User-Agent": "VLC/3.0.20", "Referer": "https://example.com/"])
        #expect(channels[1].httpHeaders == nil)
    }

    @Test func extvlcoptOrigin() {
        let channels = parse("""
        #EXTINF:-1,A
        #EXTVLCOPT:http-origin=https://origin.example
        http://host/a.m3u8
        """)
        #expect(channels.first?.httpHeaders?["Origin"] == "https://origin.example")
    }

    @Test func kodipropStreamHeadersAreURLDecoded() {
        let channels = parse("""
        #EXTINF:-1,A
        #KODIPROP:inputstream.adaptive.stream_headers=User-Agent=Mozilla%2F5.0&Referer=https%3A%2F%2Fsite.tv%2F
        http://host/a.m3u8
        """)
        #expect(channels.first?.httpHeaders == ["User-Agent": "Mozilla/5.0", "Referer": "https://site.tv/"])
    }

    @Test func extinfAttributes() {
        let channels = parse("""
        #EXTINF:-1 tvg-id="x" user-agent="Agent/1" referer="https://r.example/",A
        http://host/a.m3u8
        #EXTINF:-1 http-user-agent="Agent/2",B
        http://host/b.m3u8
        """)
        #expect(channels[0].httpHeaders == ["User-Agent": "Agent/1", "Referer": "https://r.example/"])
        #expect(channels[1].httpHeaders == ["User-Agent": "Agent/2"])
    }

    @Test func pipeSuffixIsStrippedFromURL() {
        let channels = parse("""
        #EXTINF:-1,A
        http://host/a.m3u8|User-Agent=Kodi%2F20&Referer=https://k.example/
        """)
        #expect(channels.first?.streamURL.absoluteString == "http://host/a.m3u8")
        #expect(channels.first?.httpHeaders == ["User-Agent": "Kodi/20", "Referer": "https://k.example/"])
    }

    @Test func exthttpJSON() {
        let channels = parse("""
        #EXTINF:-1,A
        #EXTHTTP:{"User-Agent":"Json/1","Cookie":"a=b"}
        http://host/a.m3u8
        """)
        #expect(channels.first?.httpHeaders == ["User-Agent": "Json/1", "Cookie": "a=b"])
    }

    @Test func playlistUserAgentIsDefaultOnly() {
        #expect(StreamHTTPHeaders.merged(nil, defaultUserAgent: "Default/1") == ["User-Agent": "Default/1"])
        #expect(StreamHTTPHeaders.merged(["User-Agent": "Own/1"], defaultUserAgent: "Default/1") == ["User-Agent": "Own/1"])
        #expect(StreamHTTPHeaders.merged(nil, defaultUserAgent: "  ") == nil)
    }
}

@Suite("Playback URL candidates")
struct PlaybackURLCandidateTests {
    @Test func xtreamTSIsTriedAsHLSFirst() {
        let url = URL(string: "http://host:8080/live/user/pass/123.ts")!
        let candidates = PlaybackItemFactory.playbackURLCandidates(for: url)
        #expect(candidates.map(\.absoluteString) == ["http://host:8080/live/user/pass/123.m3u8", url.absoluteString])
    }

    @Test func extensionlessXtreamURL() {
        let url = URL(string: "http://host/user/pass/42")!
        #expect(PlaybackItemFactory.playbackURLCandidates(for: url).first?.absoluteString == "http://host/live/user/pass/42.m3u8")
    }

    @Test func regularHLSIsUnchanged() {
        let url = URL(string: "https://cdn.example/live/master.m3u8")!
        #expect(PlaybackItemFactory.playbackURLCandidates(for: url) == [url])
    }
}

@MainActor
@Suite("Stream ranking and selection")
struct StreamSelectionTests {
    private func channel(_ id: String, _ name: String) -> Channel {
        Channel(id: id, name: name, streamURL: URL(string: "http://host/\(id).m3u8")!, logoURL: nil,
                group: nil, playlistID: UUID(), playlistName: "Test")
    }

    private func stream(_ id: String, _ name: String) -> ChannelStream {
        ChannelStream(id: id, providerChannelId: id, originalName: name, normalizedName: name.lowercased(),
                      streamURL: URL(string: "http://host/\(id).m3u8")!, tvgId: nil, tvgName: nil,
                      tvgLogoURL: nil, groupTitle: nil, resolution: StreamResolution.detect(from: name),
                      playlistID: UUID(), playlistName: "Test")
    }

    @Test func autoPrefersFHDOverUHDByDefault() {
        let streams = [stream("uhd", "ESPN 4K"), stream("hd", "ESPN HD"), stream("fhd", "ESPN FHD")]
        let ranked = StreamRanker.ranked(streams: streams, preferUHD: false).map(\.stream.id)
        #expect(ranked == ["fhd", "hd", "uhd"])
        #expect(StreamRanker.ranked(streams: streams, preferUHD: true).first?.stream.id == "uhd")
    }

    @Test func h264BeatsHEVCAndBackupsGoLast() {
        let streams = [stream("backup", "ESPN FHD BACKUP"), stream("hevc", "ESPN FHD HEVC"), stream("avc", "ESPN FHD H264")]
        #expect(StreamRanker.ranked(streams: streams, preferUHD: false).map(\.stream.id) == ["avc", "hevc", "backup"])
    }

    @Test func lastKnownGoodStartsFirst() {
        let streams = [stream("fhd", "ESPN FHD"), stream("sd", "ESPN SD")]
        let health = ["sd": StreamHealthStore.Record(lastSuccess: Date(), lastTTFFMs: 900, lastFailure: nil)]
        #expect(StreamRanker.ranked(streams: streams, health: health, preferUHD: false).first?.stream.id == "sd")
    }

    @Test func matchCandidatesFailOverInGivenOrder() {
        let primary = channel("a", "TSN 1")
        let state = StreamSelectionState(channel: primary, candidates: [primary, channel("b", "TSN 2"), channel("c", "TSN 3")])
        #expect(state.hasSelectableStreams)
        #expect(state.activeChannel.id == "a")
        let token = state.loadToken
        state.handlePlaybackFailure()
        #expect(state.activeChannel.id == "b")
        #expect(state.loadToken != token)
        state.handlePlaybackFailure()
        state.handlePlaybackFailure()
        #expect(state.switchState == .failed("Couldn't play this stream."))
    }

    @Test func singleChannelHasNoPicker() {
        let state = StreamSelectionState(channel: channel("a", "News"))
        #expect(!state.hasSelectableStreams)
        state.handlePlaybackFailure()
        #expect(state.switchState == .failed("Couldn't play this stream."))
    }

    @Test func resetSwitchesChannelAndBumpsToken() {
        let state = StreamSelectionState(channel: channel("a", "One"))
        let token = state.loadToken
        state.reset(to: channel("b", "Two"), canonicalChannel: nil)
        #expect(state.activeChannel.id == "b")
        #expect(state.loadToken == token + 1)
        #expect(state.switchState == .idle)
    }
}
