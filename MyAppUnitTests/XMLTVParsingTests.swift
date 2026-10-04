import Foundation
import Testing
@testable import BannerTV

/// XMLTV parsing, including the pre-filter that strips programmes the parser would reject
/// anyway. Each odd document here is one the filter must leave exactly as the parser alone
/// would have read it.
@Suite("XMLTV parsing")
struct XMLTVParsingTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var window: ClosedRange<Date> { now.addingTimeInterval(-6 * 3600)...now.addingTimeInterval(72 * 3600) }

    private func stamp(_ date: Date, offset: String = "+0000") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let digits = String(format: "%04d%02d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return digits + " " + offset
    }

    /// A programme starting `hours` from the fixed "now".
    private func programme(_ title: String, channel: String = "c1", hours: Double, length: Double = 1, extra: String = "") -> String {
        let start = now.addingTimeInterval(hours * 3600)
        let stop = start.addingTimeInterval(length * 3600)
        return #"<programme start="\#(stamp(start))" stop="\#(stamp(stop))" channel="\#(channel)"\#(extra)><title>\#(title)</title></programme>"#
    }

    private func parse(_ body: String, allowed: Set<String>? = nil, window: ClosedRange<Date>? = nil, channelsOnly: Bool = false) -> EPGParseResult {
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><tv>\#(body)</tv>"#
        return EPGXMLParser(sourceId: "test", priority: 0)
            .parse(data: Data(xml.utf8), allowedChannelIds: allowed, programmeWindow: window, channelsOnly: channelsOnly)
    }

    private func titles(_ result: EPGParseResult) -> [String] { result.programmes.map(\.title) }

    // MARK: Window and channel filters

    @Test("Only programmes overlapping the window are kept")
    func windowFilter() {
        let body = [
            programme("Over already", hours: -10),
            programme("Straddles the start", hours: -7, length: 2),
            programme("Inside", hours: 1),
            programme("Too far ahead", hours: 100),
            #"<programme start="not a date" stop="20300101000000 +0000" channel="c1"><title>Bad date</title></programme>"#,
            programme("Reversed", hours: 2, length: -1),
        ].joined()
        #expect(titles(parse(body, window: window)) == ["Straddles the start", "Inside"])
    }

    @Test("Only the requested channels are kept")
    func channelFilter() {
        let body = programme("One", channel: "c1", hours: 1) + programme("Two", channel: "c2", hours: 1)
        #expect(titles(parse(body, allowed: ["c2"], window: window)) == ["Two"])
        #expect(titles(parse(body, allowed: ["c3"], window: window)).isEmpty)
        #expect(titles(parse(body)).sorted() == ["One", "Two"])
    }

    @Test("A channel id written with an entity is compared as the parser decodes it")
    func entityInChannelId() {
        let body = programme("Kept", channel: "A&amp;E", hours: 1)
        #expect(titles(parse(body, allowed: ["A&E"], window: window)) == ["Kept"])
        #expect(titles(parse(body, allowed: ["A&amp;E"], window: window)).isEmpty)
    }

    @Test("Channels-only parsing returns the channel list and no programmes")
    func channelsOnly() {
        let body = #"<channel id="c1"><display-name>One</display-name></channel>"# + programme("Skipped", hours: 1)
        let result = parse(body, channelsOnly: true)
        #expect(result.channels.map(\.id) == ["c1"])
        #expect(result.channels.first?.displayNames == ["One"])
        #expect(result.programmes.isEmpty)
    }

    // MARK: Documents the pre-filter must not misread

    @Test("An end tag inside a comment or CDATA does not end a removed programme early")
    func hiddenEndTags() {
        let oldHours = -30.0
        let withComment = programme("Old", hours: oldHours).replacingOccurrences(of: "</title>", with: "</title><!-- </programme> -->")
        let withCDATA = programme("Old", hours: oldHours).replacingOccurrences(of: "</title>", with: "</title><desc><![CDATA[ </programme> ]]></desc>")
        for old in [withComment, withCDATA] {
            #expect(titles(parse(old + programme("Keep", hours: 1), window: window)) == ["Keep"])
        }
    }

    @Test("Self-closing and unterminated programmes don't disturb their neighbours")
    func selfClosingAndUnterminated() {
        let selfClosing = #"<programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="c1"/>"#
        #expect(titles(parse(selfClosing + programme("Keep", hours: 1), window: window)) == ["Keep"])

        // A document cut off mid-programme: what came before it is still read.
        let unterminated = #"<programme start="20000101000000 +0000" stop="20000101010000 +0000" channel="c1"><title>Cut off"#
        let xml = #"<?xml version="1.0"?><tv>"# + programme("Keep", hours: 1) + unterminated
        let result = EPGXMLParser(sourceId: "test", priority: 0).parse(data: Data(xml.utf8), programmeWindow: window)
        #expect(titles(result) == ["Keep"])
    }

    @Test("Single quotes, reordered attributes, line breaks and a > inside a value")
    func unusualStartTags() {
        let start = now.addingTimeInterval(3600)
        let stop = start.addingTimeInterval(3600)
        let odd = "<programme\n  channel='c1'\n  stop='\(stamp(stop))'\n  note=\"a>b\"\n  start='\(stamp(start))'><title>Odd</title></programme>"
        let oldOdd = "<programme\n  channel='c1'\n  stop='20000101010000 +0000'\n  note=\"a>b\"\n  start='20000101000000 +0000'><title>Old odd</title></programme>"
        #expect(titles(parse(oldOdd + odd, window: window)) == ["Odd"])
    }

    @Test("With nothing to filter on, the data passes through untouched")
    func prefilterIsANoOpWithoutFilters() {
        let data = Data(programme("Any", hours: 1).utf8)
        #expect(XMLTVPrefilter.filter(data, window: nil, allowedChannelIds: nil) == data)
        #expect(XMLTVPrefilter.filter(data, window: window, allowedChannelIds: nil) == data)
        #expect(XMLTVPrefilter.filter(Data(programme("Old", hours: -50).utf8), window: window, allowedChannelIds: nil).isEmpty)
    }

    // MARK: Timestamps

    @Test("XMLTV timestamps resolve to the right instant, with and without an offset")
    func timestamps() {
        #expect(EPGDateParser.parseXMLTV("20240101120000") == Date(timeIntervalSince1970: 1_704_110_400))
        #expect(EPGDateParser.parseXMLTV("20240101120000 +0100") == Date(timeIntervalSince1970: 1_704_106_800))
        #expect(EPGDateParser.parseXMLTV("20240101120000 -0500") == Date(timeIntervalSince1970: 1_704_128_400))
        #expect(EPGDateParser.parseXMLTV("20240101120000 +0530") == Date(timeIntervalSince1970: 1_704_090_600))
        #expect(EPGDateParser.parseXMLTV("  20240101120000   +0100\n") == Date(timeIntervalSince1970: 1_704_106_800))
        #expect(EPGDateParser.parseXMLTV("20240229235959") == Date(timeIntervalSince1970: 1_709_251_199))
        #expect(EPGDateParser.parseXMLTV("") == nil)
        #expect(EPGDateParser.parseXMLTV("garbage") == nil)
        #expect(EPGDateParser.parseXMLTV("2024010112") == nil)
    }

    @Test("The integer fast path agrees with the Calendar-based parser it replaced")
    func fastPathMatchesCalendarPath() {
        let samples = [
            "20240101120000", "20241231235959 +0000", "20000229000000 -0830", "19700101000000", "19691231235959 +0100",
            "21001231120000 +1400", "20240101120000 +01", "20240101120000 0100", "20240231120000", "20241301120000",
            "20240101240000", "20240101126000", "2024010112000x",
        ]
        for sample in samples {
            #expect(EPGDateParser.parseXMLTV(sample) == EPGDateParser.parseXMLTVWithCalendar(sample), "\(sample)")
        }
    }
}
