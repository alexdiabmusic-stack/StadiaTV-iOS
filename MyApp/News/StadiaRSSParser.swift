import Foundation

// MARK: - Production RSS 2.0 + Atom parser

final class StadiaRSSParser: NSObject, XMLParserDelegate {
    struct ParsedItem {
        var title: String?
        var link: String?
        var guid: String?
        var description: String?
        var content: String?
        var publishedRaw: String?
        var imageURL: String?
        var author: String?
        var categories: [String]
    }

    // nonisolated(unsafe): All access is synchronous within a single parse() call on one thread.
    nonisolated(unsafe) private var items: [ParsedItem] = []
    nonisolated(unsafe) private var current: ParsedItem?
    nonisolated(unsafe) private var currentElement = ""
    nonisolated(unsafe) private var buffer = ""
    nonisolated(unsafe) private var insideItem = false
    nonisolated(unsafe) private var insideChannel = false
    nonisolated(unsafe) private var depth = 0
    nonisolated(unsafe) private var namespaces: [String: String] = [:]

    nonisolated override init() { super.init() }

    // MARK: - Entry point

    nonisolated static func parse(_ data: Data) -> [ParsedItem] {
        let delegate = StadiaRSSParser()
        let parser = XMLParser(data: data)
        // Prevent XXE: disable external entity resolution
        parser.shouldResolveExternalEntities = false
        // XMLParser.parse() is synchronous; all XMLParserDelegate callbacks fire on the calling thread.
        // @MainActor inference on NSObject subclasses in Xcode 26 causes a Swift 6 warning here —
        // safe to suppress with assumeIsolated because there is no concurrent access.
        MainActor.assumeIsolated {
            parser.delegate = delegate
        }
        parser.parse()
        return delegate.items
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        depth += 1
        currentElement = name
        buffer = ""

        if name == "channel" || name == "feed" {
            insideChannel = true
        }

        if name == "item" || name == "entry" {
            insideItem = true
            current = ParsedItem(categories: [])
            return
        }

        guard insideItem else { return }

        // Enclosure image
        if name == "enclosure",
           let type = attributeDict["type"],
           type.hasPrefix("image/"),
           let url = attributeDict["url"] {
            current?.imageURL = url
        }

        // media:content / media:thumbnail
        if name == "media:content" || name == "content" && namespaceURI?.contains("media") == true,
           let url = attributeDict["url"] {
            if current?.imageURL == nil { current?.imageURL = url }
        }
        if name == "media:thumbnail" || name == "thumbnail" && namespaceURI?.contains("media") == true,
           let url = attributeDict["url"] {
            if current?.imageURL == nil { current?.imageURL = url }
        }

        // Atom <link href="..."> — rel=alternate is the canonical article link
        if name == "link" {
            let rel = attributeDict["rel"]
            if let href = attributeDict["href"], (rel == nil || rel == "alternate") {
                if current?.link == nil { current?.link = href }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buffer += s }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        defer {
            depth -= 1
            buffer = ""
        }
        guard insideItem else {
            if name == "item" || name == "entry" { insideItem = false }
            return
        }

        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "title":
            if current?.title == nil, !text.isEmpty {
                current?.title = stripHTML(text)
            }

        case "link":
            // Text content form (RSS 2.0): <link>URL</link>
            if current?.link == nil, !text.isEmpty, text.hasPrefix("http") {
                current?.link = text
            }

        case "guid", "id":
            if !text.isEmpty { current?.guid = text }

        case "description", "summary":
            if current?.description == nil, !text.isEmpty {
                current?.description = stripHTML(text)
            }

        case "content:encoded", "encoded":
            // Full content — use as description if no shorter description yet, strip HTML
            if current?.content == nil, !text.isEmpty {
                current?.content = stripHTML(text)
            }

        case "content":
            // Atom <content> element
            if current?.content == nil, !text.isEmpty {
                current?.content = stripHTML(text)
            }

        case "pubDate", "published", "updated", "dc:date", "date":
            if current?.publishedRaw == nil, !text.isEmpty {
                current?.publishedRaw = text
            }

        case "author":
            if current?.author == nil, !text.isEmpty {
                current?.author = stripHTML(text)
            }

        case "name":
            // Atom <author><name>…</name></author>
            if current?.author == nil, !text.isEmpty {
                current?.author = text
            }

        case "category", "dc:subject":
            if !text.isEmpty { current?.categories.append(text) }

        case "item", "entry":
            if var item = current {
                // Prefer shorter description over stripped full content for summary
                if item.description == nil, let c = item.content {
                    item.description = String(c.prefix(300))
                }
                items.append(item)
            }
            current = nil
            insideItem = false

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        // Silent — partial results still usable
    }

    // MARK: - HTML stripping

    private func stripHTML(_ text: String) -> String {
        var result = text
        // Decode common entities before stripping tags
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"),
            ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Strip HTML tags
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Collapse whitespace
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Date parsing

    nonisolated static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // ISO 8601 (Atom/BBC/NBC)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        // RFC 822 (RSS 2.0 pubDate)
        let rfc822Formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm Z",
        ]
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        for format in rfc822Formats {
            fmt.dateFormat = format
            if let d = fmt.date(from: trimmed) { return d }
        }
        return nil
    }
}
