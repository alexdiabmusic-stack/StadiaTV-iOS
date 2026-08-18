import Foundation

// MARK: - Result type

struct EPGParseResult {
    var channels: [EPGChannel]
    var programmes: [EPGProgramme]
}

// MARK: - Streaming XMLTV parser

final class EPGXMLParser: NSObject, XMLParserDelegate {

    private let sourceId: String
    private let sourcePriority: Int
    private var allowedChannelIds: Set<String>?

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
    private var lastAttributes: [String: String] = [:]

    init(sourceId: String, priority: Int) {
        self.sourceId = sourceId
        self.sourcePriority = priority
    }

    func parse(data: Data, allowedChannelIds: Set<String>? = nil) -> EPGParseResult {
        self.allowedChannelIds = allowedChannelIds
        channels = []; programmes = []
        let parser = XMLParser(data: data)
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
        currentText = ""
        lastAttributes = attributes

        switch elementName {
        case "channel":
            parsingChannelId = attributes["id"]
            channelDisplayNames = []
            channelIconURL = nil

        case "programme":
            guard
                let chId = attributes["channel"],
                let startStr = attributes["start"],
                let stopStr = attributes["stop"],
                let start = parseDate(startStr),
                let stop = parseDate(stopStr),
                start < stop
            else { return }

            if let allowed = allowedChannelIds, !allowed.contains(chId) { return }

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
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        currentText = ""

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
            if parsingChannelId != nil, !text.isEmpty {
                channelDisplayNames.append(text)
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
                sourcePriority: sourcePriority
            )
            if prog.isValid { programmes.append(prog) }
            progActive = false

        case "title":
            if progActive, progTitle == nil, !text.isEmpty {
                progTitle = text
            }

        case "sub-title":
            if progActive, !text.isEmpty { progSubtitle = text }

        case "desc":
            if progActive, !text.isEmpty { progDesc = text }

        case "category":
            if progActive, !text.isEmpty { progCategories.append(text) }

        case "episode-num":
            if progActive { parseEpisodeNum(text, system: progEpisodeSystem) }

        case "value":
            if progActive, progRating == nil, !text.isEmpty { progRating = text }

        default: break
        }
    }

    // MARK: XMLTV date parsing (YYYYMMDDHHMMSS [+/-HHMM])

    private func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let core: String
        var tzSeconds = 0

        if trimmed.count > 14 {
            core = String(trimmed.prefix(14))
            let rest = trimmed.dropFirst(14).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { tzSeconds = parseTZOffset(rest) }
        } else {
            core = trimmed
        }

        guard core.count == 14,
              let year   = Int(core.prefix(4)),
              let month  = Int(core.dropFirst(4).prefix(2)),
              let day    = Int(core.dropFirst(6).prefix(2)),
              let hour   = Int(core.dropFirst(8).prefix(2)),
              let minute = Int(core.dropFirst(10).prefix(2)),
              let second = Int(core.dropFirst(12).prefix(2))
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        guard var date = cal.date(from: comps) else { return nil }
        date = date.addingTimeInterval(TimeInterval(-tzSeconds))
        return date
    }

    private func parseTZOffset(_ s: String) -> Int {
        guard s.count >= 5 else { return 0 }
        let sign = s.hasPrefix("-") ? -1 : 1
        let digits = String(s.dropFirst())
        guard let h = Int(digits.prefix(2)), let m = Int(digits.dropFirst(2).prefix(2)) else { return 0 }
        return sign * (h * 3600 + m * 60)
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
            let pattern = try? NSRegularExpression(pattern: "S(\\d+)E(\\d+)", options: .caseInsensitive)
            let ns = text as NSString
            if let m = pattern?.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                progSeason  = Int(ns.substring(with: m.range(at: 1)))
                progEpisode = Int(ns.substring(with: m.range(at: 2)))
            }
        default: break
        }
    }
}
