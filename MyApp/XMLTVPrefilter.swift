import Foundation

/// Cuts an XMLTV document down before it reaches `XMLParser`.
///
/// A provider's feed typically spans many days and every channel, while the guide keeps a
/// window of a few days and (for generic feeds) only the channels it matched. `XMLParser`
/// still tokenizes every rejected `<programme>` before `EPGXMLParser` throws it away. This
/// removes whole `<programme>…</programme>` elements whose own attributes already prove they
/// would be rejected — so the parser never sees them.
///
/// It is deliberately conservative: it only removes an element when it can read `channel`,
/// `start` and `stop` plainly and they fail the same tests `EPGXMLParser` applies. Anything it
/// can't be sure about (entities in an id, an unparseable date, a self-closing tag, a missing
/// `</programme>`) is left in for the parser to decide, so the parsed result is identical.
nonisolated enum XMLTVPrefilter {

    static func filter(_ data: Data, window: ClosedRange<Date>?, allowedChannelIds: Set<String>?) -> Data {
        guard window != nil || allowedChannelIds != nil else { return data }
        return data.withUnsafeBytes { raw -> Data in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return data }
            let bytes = UnsafeBufferPointer(start: base, count: raw.count)
            return filter(bytes, original: data, window: window, allowedChannelIds: allowedChannelIds)
        }
    }

    private static let openTag = Array("<programme".utf8)
    private static let closeTag = Array("</programme>".utf8)
    private static let markupDeclaration = Array("<!".utf8)

    private static func filter(
        _ bytes: UnsafeBufferPointer<UInt8>,
        original: Data,
        window: ClosedRange<Date>?,
        allowedChannelIds: Set<String>?
    ) -> Data {
        let count = bytes.count
        var output = Data()
        var copiedUpTo = 0
        var removedAny = false
        var index = 0

        while index < count {
            guard let lt = nextByte(UInt8(ascii: "<"), in: bytes, from: index) else { break }
            guard matches(openTag, in: bytes, at: lt),
                  lt + openTag.count < count,
                  isXMLSpace(bytes[lt + openTag.count]) else {
                index = lt + 1
                continue
            }
            guard let tagEnd = endOfStartTag(in: bytes, from: lt + openTag.count) else { break }
            index = tagEnd + 1
            // `<programme .../>` has no body to remove; leave it to the parser.
            guard bytes[tagEnd - 1] != UInt8(ascii: "/") else { continue }

            guard shouldRemove(bytes, tagStart: lt + openTag.count, tagEnd: tagEnd, window: window, allowed: allowedChannelIds),
                  let closeStart = find(closeTag, in: bytes, from: index),
                  // A comment or CDATA section in the body could hide the real end tag.
                  find(markupDeclaration, in: bytes, from: index, before: closeStart) == nil else { continue }

            let removeEnd = closeStart + closeTag.count
            if !removedAny {
                output.reserveCapacity(count / 2)
                removedAny = true
            }
            output.append(UnsafeBufferPointer(rebasing: bytes[copiedUpTo..<lt]))
            copiedUpTo = removeEnd
            index = removeEnd
        }

        guard removedAny else { return original }
        output.append(UnsafeBufferPointer(rebasing: bytes[copiedUpTo..<count]))
        return output
    }

    // MARK: Deciding

    private static func shouldRemove(
        _ bytes: UnsafeBufferPointer<UInt8>,
        tagStart: Int,
        tagEnd: Int,
        window: ClosedRange<Date>?,
        allowed: Set<String>?
    ) -> Bool {
        var channel: Range<Int>?
        var start: Range<Int>?
        var stop: Range<Int>?
        var cursor = tagStart
        while cursor < tagEnd {
            while cursor < tagEnd, isXMLSpace(bytes[cursor]) { cursor += 1 }
            let nameStart = cursor
            while cursor < tagEnd, bytes[cursor] != UInt8(ascii: "="), !isXMLSpace(bytes[cursor]) { cursor += 1 }
            let name = nameStart..<cursor
            while cursor < tagEnd, isXMLSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < tagEnd, bytes[cursor] == UInt8(ascii: "=") else { break }
            cursor += 1
            while cursor < tagEnd, isXMLSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < tagEnd, bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") else { break }
            let quote = bytes[cursor]
            cursor += 1
            let valueStart = cursor
            while cursor < tagEnd, bytes[cursor] != quote { cursor += 1 }
            guard cursor < tagEnd else { break }
            let value = valueStart..<cursor
            cursor += 1

            if equals("channel", bytes, name) { channel = value }
            else if equals("start", bytes, name) { start = value }
            else if equals("stop", bytes, name) { stop = value }
        }

        // Same order of tests as EPGXMLParser.didStartElement.
        if let allowed, let channel {
            // An entity (`&amp;`) means the decoded id differs from these raw bytes.
            guard !bytes[channel].contains(UInt8(ascii: "&")) else { return false }
            let id = String(decoding: bytes[channel], as: UTF8.self)
            if !allowed.contains(id) { return true }
        }
        guard let window else { return false }
        guard let start, let startDate = EPGDateParser.parseXMLTV(utf8: UnsafeBufferPointer(rebasing: bytes[start])) else { return false }
        if startDate > window.upperBound { return true }
        guard let stop, let stopDate = EPGDateParser.parseXMLTV(utf8: UnsafeBufferPointer(rebasing: bytes[stop])),
              startDate < stopDate else { return false }
        return stopDate < window.lowerBound
    }

    // MARK: Scanning helpers

    private static func isXMLSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    private static func nextByte(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard from < bytes.count, let base = bytes.baseAddress else { return nil }
        guard let found = memchr(base + from, Int32(byte), bytes.count - from) else { return nil }
        return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
    }

    private static func matches(_ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for i in 0..<pattern.count where bytes[index + i] != pattern[i] { return false }
        return true
    }

    private static func find(_ pattern: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from: Int, before limit: Int? = nil) -> Int? {
        let end = limit ?? bytes.count
        var index = from
        while let hit = nextByte(pattern[0], in: bytes, from: index), hit + pattern.count <= end {
            if matches(pattern, in: bytes, at: hit) { return hit }
            index = hit + 1
        }
        return nil
    }

    /// Index of the `>` that ends the start tag, skipping any `>` inside a quoted value.
    private static func endOfStartTag(in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        var index = from
        var quote: UInt8?
        while index < bytes.count {
            let b = bytes[index]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: ">") {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func equals(_ name: StaticString, _ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Bool {
        guard range.count == name.utf8CodeUnitCount else { return false }
        let expected = name.utf8Start
        for i in 0..<range.count where bytes[range.lowerBound + i] != expected[i] { return false }
        return true
    }
}
