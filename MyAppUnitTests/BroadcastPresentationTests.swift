import Foundation
import Testing
@testable import BannerTV

@Suite("Broadcast presentation")
struct BroadcastPresentationTests {
    @Test("Playlist decoration is removed without changing channel acronyms")
    func displayNames() {
        #expect(BroadcastPresentation.name("  TSN | HD ★ ") == "TSN HD")
        #expect(BroadcastPresentation.category("AF ❖ CAMEROON") == "Cameroon")
        #expect(BroadcastPresentation.category("NFL") == "NFL")
    }

    @Test("Network labels retain order and remove case-insensitive duplicates")
    func networks() {
        #expect(BroadcastPresentation.networks(["TSN", "tsn", "Sportsnet"]) == "TSN · Sportsnet")
    }

    @Test("Quality selection uses whole tokens, not substrings in channel names")
    func hdQuality() {
        #expect(BroadcastPresentation.isHD("Sports FHD"))
        #expect(BroadcastPresentation.isHD("Sports 1080p"))
        #expect(!BroadcastPresentation.isHD("HDO Network"))
        #expect(!BroadcastPresentation.isHD("Sports SD"))
    }

    @Test("Sport-specific clocks survive presentation cleanup")
    func gameStatus() {
        #expect(BroadcastPresentation.status("  Q4 · 8:29 ") == "Q4 · 8:29")
        #expect(BroadcastPresentation.status("Bottom 9") == "Bottom 9")
    }
}
