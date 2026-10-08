import Foundation
import Testing
@testable import BannerTV

@Suite("Stream resolution")
struct StreamResolutionTests {

    @Test("Resolution comes from the markers in a channel name", arguments: [
        ("ESPN HD", StreamResolution.hd), ("ESPN SD", .sd), ("US: ESPN FHD", .fhd), ("Sky Sports 4K", .uhd),
        ("Movies UHD", .uhd), ("News 1080p", .fhd), ("News 720p", .hd), ("FULL HD News", .fhd), ("Plain Name", .unknown), ("", .unknown),
        ("ESPN-HD", .hd), ("HD", .hd), ("SD", .sd), ("hd lowercase", .hd),
    ])
    func detects(name: String, expected: StreamResolution) {
        #expect(StreamResolution.detect(from: name) == expected)
    }

    @Test("HD and SD count only as whole words")
    func wholeWords() {
        for name in ["HDTV", "CHD", "ESPN_HD", "SDX", "XSD", "HD1", "1HD"] {
            #expect(StreamResolution.detect(from: name) == .unknown, "\(name)")
        }
    }

    @Test("Names with non-ASCII characters are read the same way")
    func nonASCII() {
        #expect(StreamResolution.detect(from: "Ünïcödé HD") == .hd)
        #expect(StreamResolution.detect(from: "日本 SD") == .sd)
        #expect(StreamResolution.detect(from: "★ Sports ★ 4K") == .uhd)
    }
}
