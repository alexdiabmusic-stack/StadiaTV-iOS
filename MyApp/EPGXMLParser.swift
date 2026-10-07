import Foundation

// MARK: - Result type

struct EPGParseResult {
    var channels: [EPGChannel]
    var programmes: [EPGProgramme]
}

// MARK: - Streaming XMLTV parser

nonisolated final class EPGXMLParser: NSObject, XMLParserDelegate {

    private let sourceId: String
    private let sourcePriority: Int
    private var allowedChannelIds: Set<String>?
    private var programmeWindow: ClosedRange<Date>?
    private var channelsOnly = false

    // Parse outputs
    private var channels: [EPGChannel] = []
    private var programmes: [EPGProgramme] = []

    // Channel parse state
    private var parsingChannelId: String?
    private var channelDisplayNames: [String] = []
    private var channelIconURL: URL?

    // Programme parse state
    private var progActive = false
    private var progChannelId: String?
    private var progStart: Date?
    private var progStop: Date?
    private var progTitle: String?
    private var progSubtitle: String?
    private var progDesc: String?
    private var progCategories: [String] = []
    private var progIconURL: URL?
    private var progSeason: Int?
    private var progEpisode: Int?
    private var progRating: String?
    private var progEpisodeSystem: String = ""

    // SAX state
    private var currentText = ""

    /// Text is only needed inside a channel or an in-window programme. Everything else (the bulk
    /// of a multi-day feed, once the window filter has rejected it) is skipped unread.
    private var isCollectingText: Bool { progActive || parsingChannelId != nil }

    private static let onscreenEpisodeRegex = try? NSRegularExpression(pattern: "S(\\d+)E(\\d+)", options: .caseInsensitive)

    init(sourceId: String, priority: Int) {
        self.sourceId = sourceId
        self.sourcePriority = priority
    }

    func parse(
        data: Data,
        allowedChannelIds: Set<String>? = nil,
        programmeWindow: ClosedRange<Date>? = nil,
        channelsOnly: Bool = false
    ) -> EPGParseResult {
        let signpost = GuideMatchingSignposts.beginGuideParse()
        defer { GuideMatchingSignposts.endGuideParse(signpost) }
        self.allowedChannelIds = allowedChannelIds
        self.programmeWindow = programmeWindow
        self.channelsOnly = channelsOnly
        channels = []; programmes = []
        // Programmes the window/channel filters would discard never reach the XML parser at all.
        let input = channelsOnly ? data : XMLTVPrefilter.filter(data, window: programmeWindow, allowedChannelIds: allowedChannelIds)
        let parser = XMLParser(data: input)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return EPGParseResult(channels: channels, programmes: programmes)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText.removeAll(keepingCapacity: true)

        switch elementName {
        case "channel":
            parsingChannelId = attributes["id"]
            channelDisplayNames = []
            channelIconURL = nil

        case "programme":
            guard !channelsOnly else { return }
            // Cheapest rejections first: most programmes in a multi-day feed fall outside the
            // window or belong to a channel nobody asked for, so don't parse a date until needed.
            guard
                let chId = attributes["channel"],
                let startStr = attributes["start"],
                let stopStr = attributes["stop"]
            else { return }
            if let allowed = allowedChannelIds, !allowed.contains(chId) { return }
            guard let start = parseDate(startStr) else { return }
            if let window = programmeWindow, start > window.upperBound { return }
            guard let stop = parseDate(stopStr), start < stop else { return }
            if let window = programmeWindow, stop < window.lowerBound { return }

            progActive = true
            progChannelId = chId
            progStart = start
            progStop = stop
            progTitle = nil; progSubtitle = nil; progDesc = nil
            progCategories = []; progIconURL = nil
            progSeason = nil; progEpisode = nil; progRating = nil
            progEpisodeSystem = ""

        case "icon":
            if let src = attributes["src"], let url = URL(string: src) {
                if progActive { progIconURL = url }
                else if parsingChannelId != nil { channelIconURL = url }
            }

        case "episode-num":
            progEpisodeSystem = attributes["system"] ?? ""

        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollectingText { currentText += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        func trimmedText() -> String { currentText.trimmingCharacters(in: .whitespacesAndNewlines) }
        defer { currentText.removeAll(keepingCapacity: true) }

        switch elementName {
        case "channel":
            if let id = parsingChannelId, !channelDisplayNames.isEmpty {
                channels.append(EPGChannel(
                    id: id,
                    displayNames: channelDisplayNames,
                    iconURL: channelIconURL,
                    sourceId: sourceId
                ))
            }
            parsingChannelId = nil

        case "display-name":
            if parsingChannelId != nil {
                let text = trimmedText()
                if !text.isEmpty { channelDisplayNames.append(text) }
            }

        case "programme":
            guard progActive,
                  let chId = progChannelId,
                  let start = progStart,
                  let stop = progStop,
                  let title = progTitle, !title.isEmpty else {
                progActive = false; return
            }
            let prog = EPGProgramme(
                id: "\(chId)-\(Int(start.timeIntervalSince1970))",
                epgChannelId: chId,
                canonicalChannelId: nil,
                title: title,
                subtitle: progSubtitle,
                description: progDesc,
                categories: progCategories,
                start: start,
                end: stop,
                imageURL: progIconURL,
                season: progSeason,
                episode: progEpisode,
                rating: progRating,
                sourceId: sourceId,
                sourcePriority: sourcePriority,
                endTimeIsInferred: false
            )
            if prog.isValid { programmes.append(prog) }
            progActive = false

        case "title":
            if progActive, progTitle == nil {
                let text = trimmedText()
                if !text.isEmpty { progTitle = text }
            }

        case "sub-title":
            if progActive {
                let text = trimmedText()
                if !text.isEmpty { progSubtitle = text }
            }

        case "desc":
            if progActive {
                let text = trimmedText()
                if !text.isEmpty { progDesc = text }
            }

        case "category":
            if progActive {
                let text = trimmedText()
                if !text.isEmpty { progCategories.append(text) }
            }

        case "episode-num":
            if progActive { parseEpisodeNum(trimmedText(), system: progEpisodeSystem) }

        case "value":
            if progActive, progRating == nil {
                let text = trimmedText()
                if !text.isEmpty { progRating = text }
            }

        default: break
        }
    }

    // MARK: XMLTV date parsing (YYYYMMDDHHMMSS [+/-HHMM])

    private func parseDate(_ s: String) -> Date? {
        EPGDateParser.parseXMLTV(s)
    }

    private func parseEpisodeNum(_ text: String, system: String) {
        switch system {
        case "xmltv_ns":
            let parts = text.split(separator: ".").map(String.init)
            if parts.count >= 1, let rawS = parts[0].split(separator: "/").first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                progSeason = rawS + 1
            }
            if parts.count >= 2, let rawE = parts[1].split(separator: "/").first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                progEpisode = rawE + 1
            }
        case "onscreen":
            let ns = text as NSString
            if let m = Self.onscreenEpisodeRegex?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                progSeason  = Int(ns.substring(with: m.range(at: 1)))
                progEpisode = Int(ns.substring(with: m.range(at: 2)))
            }
        default: break
        }
    }
}
