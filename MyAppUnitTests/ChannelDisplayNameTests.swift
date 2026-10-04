import Foundation
import Testing
@testable import BannerTV

@Suite("ChannelDisplayName")
struct ChannelDisplayNameTests {

    @Test("Country prefix, quality token and region bracket all clean up together")
    func fullCleanup() {
        let result = ChannelDisplayName.make(from: "US ★ NBC SPORTS HD [CALIFORNIA]")
        #expect(result.title == "Nbc Sports California" || result.title == "NBC Sports California")
        #expect(result.countryCode == "US")
        #expect(result.quality == "HD")
        #expect(result.flag == "🇺🇸")
    }

    @Test("Known broadcaster acronym stays uppercase")
    func acronymStaysUppercase() {
        let result = ChannelDisplayName.make(from: "CAF ★ TSN 2 FHD")
        #expect(result.title.contains("TSN"))
        #expect(result.countryCode == "CA")
        #expect(result.quality == "FHD")
    }

    @Test("Event-slot titles with a slot number are left untouched")
    func eventSlotTitleKeepsRawName() {
        let raw = "PEACOCK 03: Kings @ Sharks"
        let result = ChannelDisplayName.make(from: raw)
        #expect(result.title == raw)
    }

    @Test("A kickoff time in the name is left untouched")
    func kickoffTimeKeepsRawName() {
        let raw = "Kings vs Sharks 10:30PM"
        let result = ChannelDisplayName.make(from: raw)
        #expect(result.title == raw)
    }

    @Test("An ISO event date in the name is left untouched")
    func isoDateKeepsRawName() {
        let raw = "NHL 2025-10-04 Event Feed"
        let result = ChannelDisplayName.make(from: raw)
        #expect(result.title == raw)
    }

    @Test("A 'Team vs Team' title is left untouched")
    func versusTitleKeepsRawName() {
        let raw = "Kings vs. Sharks"
        let result = ChannelDisplayName.make(from: raw)
        #expect(result.title == raw)
    }

    @Test("Empty cleanup result falls back to the raw name")
    func emptyResultFallsBack() {
        let raw = "★★★"
        let result = ChannelDisplayName.make(from: raw)
        #expect(result.title == raw)
    }

    @Test("A plain brand name with no decoration passes through readably")
    func plainBrandName() {
        let result = ChannelDisplayName.make(from: "ESPN2")
        #expect(result.title == "ESPN2" || result.title.uppercased() == "ESPN2")
    }
}
