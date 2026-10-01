import Foundation

// StreamLinker — links a sports event to the playlist streams that carry it, using only data the
// playlist already provides: its own XMLTV guide, its channel names, and (as support) the
// broadcaster list from the sports-data API.
//
// Foundation-only, no app types, no global mutable state beyond a lock-guarded Unicode cache. Immutable after
// init, so one instance can be shared across tasks. Build it once per playlist or guide refresh, off the main thread.
//
// Every declaration is marked `nonisolated` on purpose: an app target that defaults to MainActor isolation would
// otherwise pull the linker onto the main actor. Internal helpers carry a `Linker` prefix so nothing here can
// shadow SwiftUI's `Text` or an app type. Adapters from the app's `Match` / `Channel` / programme types are a few
// lines each (see README).

// MARK: - Input model

nonisolated public struct LinkerTeam: Sendable {
    public var name: String
    public var short: String?
    public var nick: String?
    public var city: String?
    public var abbr: String?
    public init(name: String, short: String? = nil, nick: String? = nil, city: String? = nil, abbr: String? = nil) {
        self.name = name; self.short = short; self.nick = nick; self.city = city; self.abbr = abbr
    }
}

nonisolated public struct LinkerEvent: Sendable {
    public var id: String
    public var league: String            // e.g. "hockey/nhl", "soccer/uefa.nations"
    public var kickoff: Date
    public var home: LinkerTeam
    public var away: LinkerTeam
    public var broadcasts: [String]      // network names from the sports API ("ESPN", "TNT", "SN"...)
    public var isNational: Bool          // national teams: identity is the country name, matched in every language
    public init(id: String, league: String, kickoff: Date, home: LinkerTeam, away: LinkerTeam, broadcasts: [String] = [], isNational: Bool = false) {
        self.id = id; self.league = league; self.kickoff = kickoff; self.home = home; self.away = away
        self.broadcasts = broadcasts; self.isNational = isNational
    }
}

nonisolated public struct LinkerStream: Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var guideID: String?          // Xtream epg_channel_id / M3U tvg-id
    public init(id: String, name: String, category: String, guideID: String?) {
        self.id = id; self.name = name; self.category = category; self.guideID = guideID
    }
}

nonisolated public struct LinkerProgramme: Sendable {
    public var guideID: String
    public var start: Date
    public var end: Date
    public var title: String
    public var desc: String?
    public init(guideID: String, start: Date, end: Date, title: String, desc: String?) {
        self.guideID = guideID; self.start = start; self.end = end; self.title = title; self.desc = desc
    }
}

// MARK: - Output model

nonisolated public enum LinkTier: String, Sendable {
    case liveListing = "T1"           // guide lists both teams in the title
    case listingByDescription = "T2"  // generic title, description names both teams
    case teamChannel = "T3"           // dedicated team channel / "Next Game" entry naming this fixture
    case eventChannel = "T4"          // event-slot channel whose NAME carries the fixture and kickoff time
    case likelyRights = "T5"          // network named by the sports API; guide does not contradict
    case coverage = "T6"              // studio / in-game coverage show about the game
}

nonisolated public struct LinkedFeed: Sendable {
    public var key: String
    public var tier: LinkTier
    public var confidence: Double
    public var label: String
    public var region: String
    public var language: String
    public var displayName: String
    public var family: String
    public var streamIDs: [String]       // mirrors, best quality first
    public var evidence: String
    public var programmeTitle: String?
}

// MARK: - Text utilities (internal; the Linker prefix keeps these from shadowing SwiftUI.Text)

nonisolated enum LinkerText {
    /// Results of Foundation's Unicode normaliser, memoised per distinct non-ASCII scalar. Playlists use a few hundred
    /// distinct non-ASCII scalars (accents, ★, superscript badges, Cyrillic, Greek…), so each is normalised once, not once per string.
    nonisolated private final class ScalarCache: @unchecked Sendable {
        let lock = NSLock()
        private var clean: [UInt32: [UInt8]] = [:]
        private var compat: [UInt32: [UInt32]] = [:]

        /// NFKD, marks stripped, lower-cased; letters/digits as UTF-8, everything else as a single 0x20 separator.
        func cleanBytes(_ u: Unicode.Scalar) -> [UInt8] {
            if let hit = clean[u.value] { return hit }
            var out: [UInt8] = []
            for d in String(u).decomposedStringWithCompatibilityMapping.unicodeScalars {
                if d.properties.canonicalCombiningClass != .notReordered { continue }
                let lowered: String
                switch d.value {
                case 0x026A: lowered = "i"          // small-capital I left over from the superscript "ᶦ" of the "ᴸᶦᵛᵉ" badge
                case 0x1D00: lowered = "a"
                default: lowered = d.properties.lowercaseMapping
                }
                for l in lowered.unicodeScalars {
                    switch l.properties.generalCategory {
                    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                        out.append(contentsOf: String(l).utf8)
                    default:
                        out.append(0x20)
                    }
                }
            }
            clean[u.value] = out
            return out
        }

        /// NFKD only (case and marks kept): used for display names, where "ᴴᴰ" must become "HD" but "Č" must stay "Č".
        func compatScalars(_ u: Unicode.Scalar) -> [UInt32] {
            if let hit = compat[u.value] { return hit }
            let out = String(u).decomposedStringWithCompatibilityMapping.unicodeScalars.map(\.value)
            compat[u.value] = out
            return out
        }
    }
    private static let cache = ScalarCache()

    @inline(__always) private static func decode(_ buf: UnsafeBufferPointer<UInt8>, _ i: Int) -> (Unicode.Scalar, Int) {
        let b = buf[i]
        var v: UInt32, len: Int
        if b < 0xE0 { v = UInt32(b & 0x1F) << 6 | UInt32(buf[i + 1] & 0x3F); len = 2 }
        else if b < 0xF0 { v = UInt32(b & 0x0F) << 12 | UInt32(buf[i + 1] & 0x3F) << 6 | UInt32(buf[i + 2] & 0x3F); len = 3 }
        else { v = UInt32(b & 0x07) << 18 | UInt32(buf[i + 1] & 0x3F) << 12 | UInt32(buf[i + 2] & 0x3F) << 6 | UInt32(buf[i + 3] & 0x3F); len = 4 }
        return (Unicode.Scalar(v) ?? "\u{FFFD}", len)
    }

    /// Appends the "clean" form of `s` — lower-case, diacritics and compatibility forms folded (superscript badges ᴸᶦᵛᵉ → "live"),
    /// every run of non-letters/digits collapsed to one space — to `out`. One pass over the UTF-8 bytes; ASCII never leaves the loop.
    static func appendClean(_ s: String, limit: Int = .max, to out: inout [UInt8]) {
        if let last = out.last, last != 0x20 { out.append(0x20) }
        var sep = true
        var str = s
        str.withUTF8 { buf in
            let n = min(buf.count, limit)
            var i = 0
            var locked = false
            defer { if locked { cache.lock.unlock() } }
            while i < n {
                let b = buf[i]
                if b < 0x80 {
                    if (b >= 97 && b <= 122) || (b >= 48 && b <= 57) { out.append(b); sep = false }
                    else if b >= 65 && b <= 90 { out.append(b | 0x20); sep = false }
                    else if !sep { out.append(0x20); sep = true }
                    i += 1
                } else {
                    let (u, len) = decode(buf, i)
                    i += len
                    if !locked { cache.lock.lock(); locked = true }
                    for c in cache.cleanBytes(u) {
                        if c == 0x20 { if !sep { out.append(0x20); sep = true } } else { out.append(c); sep = false }
                    }
                }
            }
        }
        if out.last == 0x20 { out.removeLast() }
    }

    /// NFKD scalars of `s` (case preserved).
    static func appendCompat(_ s: String, to out: inout [UInt32]) {
        var str = s
        str.withUTF8 { buf in
            var i = 0
            var locked = false
            defer { if locked { cache.lock.unlock() } }
            while i < buf.count {
                let b = buf[i]
                if b < 0x80 { out.append(UInt32(b)); i += 1 }
                else {
                    let (u, len) = decode(buf, i)
                    i += len
                    if !locked { cache.lock.lock(); locked = true }
                    out.append(contentsOf: cache.compatScalars(u))
                }
            }
        }
    }

    static func clean(_ s: String) -> String {
        var b: [UInt8] = []
        appendClean(s, to: &b)
        return String(decoding: b, as: UTF8.self)
    }

    static func words(_ s: String) -> [String] {
        var b: [UInt8] = []
        appendClean(s, to: &b)
        return b.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whole-word phrase test on cleaned strings. Byte-level: Foundation's `String.contains` walks grapheme clusters and dominated the profile.
    static func hasPhrase(_ text: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        var t = text, p = phrase
        return t.withUTF8 { tb in p.withUTF8 { pb in bytesHavePhrase(tb, pb) } }
    }

    static func bytesHavePhrase(_ t: UnsafeBufferPointer<UInt8>, _ p: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = t.count, m = p.count
        guard m > 0, n >= m, let tb = t.baseAddress, let pb = p.baseAddress else { return false }
        var i = 0
        let first = pb[0]
        while i <= n - m {
            guard let hit = memchr(tb + i, Int32(first), n - m - i + 1) else { return false }
            i = tb.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            let startOK = i == 0 || tb[i - 1] == 0x20
            let endOK = i + m == n || tb[i + m] == 0x20
            if startOK && endOK && memcmp(tb + i, pb, m) == 0 { return true }
            i += 1
        }
        return false
    }

    /// Connector words that clubs and guides drop or add ("Atlético de San Luis" vs "Atlético San Luis"). Both spellings are tried.
    static let connectors: Set<Substring> = ["de", "del", "di", "da", "do", "dos", "das", "du", "of", "the", "van", "von", "der", "den", "af"]

    /// `cleaned` without connector words.
    static func withoutConnectors(_ cleaned: String) -> String {
        cleaned.split(separator: " ").filter { !connectors.contains($0) }.joined(separator: " ")
    }

    /// The cleaned text, plus its connector-free form when that differs.
    static func variants(_ cleaned: String) -> [String] {
        let k = withoutConnectors(cleaned)
        return k == cleaned ? [cleaned] : [cleaned, k]
    }

    static func hasAny(_ texts: [String], _ aliases: Set<String>) -> Bool {
        aliases.contains { alias in texts.contains { hasPhrase($0, alias) } }
    }

    /// Splits the provider's trailing badge ("ᴸᶦᵛᵉ", "ᴺᵉʷ") from a programme title. `live` is true for a "Live" badge.
    static func splitBadge(_ title: String) -> (head: String, live: Bool) {
        var ascii = true
        for b in title.utf8.reversed() { if b == 0x20 { continue }; ascii = b < 0x80; break }     // last visible byte ASCII => no badge
        if ascii { return (title.trimmingCharacters(in: .whitespaces), false) }
        let scalars = Array(title.unicodeScalars)
        var i = scalars.count
        while i > 0, scalars[i - 1] == " " || scalars[i - 1].properties.generalCategory == .modifierLetter { i -= 1 }
        let tail = scalars[i...]
        guard tail.contains(where: { $0.properties.generalCategory == .modifierLetter }) else { return (title.trimmingCharacters(in: .whitespaces), false) }
        let head = String(String.UnicodeScalarView(scalars[..<i])).trimmingCharacters(in: .whitespaces)
        return (head, clean(String(String.UnicodeScalarView(tail))).contains("live"))
    }

    // ---- token hashing (FNV-1a over the clean UTF-8 of one word)

    static func hash(_ word: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in word.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }

    /// Calls `body` with the hash of every word of at least `minBytes` bytes in cleaned bytes (duplicates included).
    static func forEachWord(_ bytes: [UInt8], minBytes: Int, _ body: (UInt32) -> Void) {
        bytes.withUnsafeBufferPointer { p in
            let n = p.count
            var i = 0
            while i < n {
                while i < n && p[i] == 0x20 { i += 1 }
                let start = i
                var h: UInt32 = 2166136261
                while i < n && p[i] != 0x20 { h = (h ^ UInt32(p[i])) &* 16777619; i += 1 }
                if i - start >= minBytes { body(h) }
            }
        }
    }

    static let bucketBits = 20
    static let bucketCount = 1 << bucketBits
    @inline(__always) static func bucket(_ h: UInt32) -> Int { Int((h &* 2654435761) >> UInt32(32 - bucketBits)) }
}

// MARK: - Country names in every language (built from the OS locale database)

nonisolated enum LinkerCountryNames {
    static let locales = ["en", "de", "fr", "es", "it", "pt", "nl", "tr", "sv", "pl", "da", "nb", "fi", "cs", "hu", "ro", "sk", "hr", "sl", "sq", "bg",
                          "sr-Latn", "lt", "lv", "et", "id", "ms", "vi", "ru", "uk", "ar", "fa", "he", "el", "zh-Hans", "ja", "ko", "th", "hi", "ka", "hy"]
    private static let stop: Set<String> = ["and", "the", "of", "de", "la", "el", "republic"]

    static func core(_ s: String) -> String {
        var c = LinkerText.clean(s)
        c = c.replacingOccurrences(of: "u s ", with: "us ").replacingOccurrences(of: "st ", with: "saint ")
        return c.split(separator: " ").filter { !stop.contains(String($0)) }.joined(separator: " ")
    }

    /// core name (any language) -> region code, and region code -> all cleaned names. Built once, on first national-team event.
    static let table: (byCore: [String: String], names: [String: Set<String>]) = {
        var byCore: [String: String] = [:]
        var names: [String: Set<String>] = [:]
        func add(_ code: String, _ n: String) {
            let c = core(n); if c.isEmpty { return }
            byCore[c] = code; names[code, default: []].insert(LinkerText.clean(n))
        }
        let locs = locales.map { Locale(identifier: $0) }
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            for l in locs { if let n = l.localizedString(forRegionCode: region.identifier) { add(region.identifier, n) } }
        }
        for n in ["England", "Inglaterra", "Angleterre", "Inghilterra", "Engeland", "Anglia", "Engelska"] { add("GB-ENG", n) }
        for n in ["Scotland", "Escocia", "Ecosse", "Écosse", "Schottland", "Schotland", "Scozia", "Skotland", "Skottland", "Skotsko"] { add("GB-SCT", n) }
        for n in ["Wales", "Gales", "Pays de Galles", "Galles", "Walia", "Wallis"] { add("GB-WLS", n) }
        for n in ["Northern Ireland", "Irlanda del Norte", "Irlande du Nord", "Nordirland", "Irlanda del Nord", "Noord-Ierland"] { add("GB-NIR", n) }
        add("PF", "Tahiti")
        for n in ["USA", "US", "United States of America"] { add("US", n) }
        add("CZ", "Czech Republic"); add("MK", "Macedonia")
        return (byCore, names)
    }()
}

// MARK: - Team aliases

nonisolated enum LinkerAliases {
    static let generic: Set<String> = Set("fc cf sc afc ac as cd ca club deportivo real sporting athletic atletico united city town county state university st saint los las new de del la el the of and sk fk bk if ik islands island".split(separator: " ").map(String.init))

    static func allGeneric(_ a: String) -> Bool { a.split(separator: " ").allSatisfy { generic.contains(String($0)) } }

    /// `fullOnly` is used for description matching, where short names are too ambiguous.
    static func of(_ team: LinkerTeam, national: Bool, fullOnly: Bool = false) -> Set<String> {
        let full = LinkerText.clean(team.name)
        let short = LinkerText.clean(team.short ?? "")
        let nick = LinkerText.clean(team.nick ?? "")
        let city = LinkerText.clean(team.city ?? "")
        var al: Set<String> = [full]
        if !fullOnly {
            for x in [short, nick] where x.count >= 4 && !allGeneric(x) { al.insert(x) }
            if !city.isEmpty, !nick.isEmpty, !allGeneric(nick) { al.insert(city + " " + nick) }
        }
        if national {
            let code = LinkerCountryNames.table.byCore[LinkerCountryNames.core(team.name)] ?? LinkerCountryNames.table.byCore[LinkerCountryNames.core(team.short ?? "")]
            if let code, let names = LinkerCountryNames.table.names[code] { al.formUnion(names) }
        }
        for a in al { let k = LinkerText.withoutConnectors(a); if k != a { al.insert(k) } }
        return al.filter { $0.count >= 3 && !allGeneric($0) }
    }
}

// MARK: - Patterns (used on the handful of candidates per event, never per programme or per stream)

nonisolated enum LinkerPatterns {
    static func re(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    static let separator = re(#"\s(?:vs\.?|v\.?|versus|at|@|c\.|x|contre|gegen|contra|-|–|—)\s"#)
    static let placeholder = re(#"^\s*(?:no\s+(?:game|match|event)s?(?:\s+today|\s+scheduled)?|next\s+(?:game|match)|teams?\s+tba|to\s+be\s+announced|tbd|off\s+air|programming\s+resumes|sign\s*off|check\s+local)"#)
    static let replay = re(#"\b(?:replay|re-?run|re-?air|encore|classics?|highlights?|condensed|recap|recorded|tape[- ]delay(?:ed)?|delayed|throwback|archive|best\s+of|resumen|zusammenfassung|magazine|melhores\s+momentos)\b"#)
    static let coverage = re(#"\b(?:in-?game|pre-?game|post-?game|pre-?show|post-?show|preview|countdown|analysis|studio|scoreboard|tonight|whip|betting|odds|picks|fantasy|talk|weekly|report|daily|live\s+look|coverage\s+of)\b"#)
    static let nextGame = re(#"next\s+(?:game|match)\s*:?\s*(.+?)\s+on\s+(\d{4})-(\d{2})-(\d{2})"#)
    static let time = re(#"\b(\d{1,2})(?::(\d{2}))?\s*(AM|PM)\s*(ET|EST|EDT|CT|CST|CDT|MT|PT|PST|PDT|UK|GMT|BST|CET|CEST)?\b"#)
    static let iso = re(#"\b(20\d{2})-(\d{2})-(\d{2})(?:\s+(\d{2}):(\d{2}))?"#)
    static let bracketQuality = re(#"\[(?:HD|FHD|UHD|SD|4K|BACKUP|BK)\]"#)
    static let sportsCategory = re(#"\b(teams?|nhl|nba|mlb|nfl|mls|sports?|wnba)\b"#)

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
    }
}

// MARK: - The linker

/// Build once per playlist/guide refresh (off the main thread), then call `link` for every event. Immutable afterwards, so it can be shared freely.
///
/// Cost model (22k streams, 115k programmes): the index stores no per-programme strings — it keeps the caller's programme array, sorted positions,
/// and a hashed word→positions index (CSR arrays). `link` binary-searches the postings of each team's rarest word inside the kickoff window and only
/// runs the (regex-based) fixture readers on those few dozen candidates.
nonisolated public final class StreamLinker: Sendable {

    // ---- playlist model (compact: names and ids stay in the caller's arrays)
    nonisolated struct S: Sendable {
        var chan: Int32          // guide-channel index, -1 when the stream has no guide id
        var sports: Bool         // category looks like a sports / team category
        var isEvent: Bool        // name reads like a fixture ("A vs B", "A @ B", "A - B")
    }
    nonisolated struct Channel: Sendable {
        var id: String           // lower-cased guide id
        var streams: [Int32]     // every stream (mirror) that uses this guide id
        var progs: [Int32]       // sorted positions of its programmes
    }
    nonisolated struct EventName { var head: String; var times: [(h: Int, m: Int, tz: String)]; var iso: (y: Int, mo: Int, d: Int)? }

    let input: [LinkerStream]
    let streams: [S]
    let channels: [Channel]
    let eventWordIndex: [UInt32: [Int32]]   // word hash -> fixture-named streams
    let teamWordIndex: [String: [Int32]]    // word -> sports-category streams named like a team
    let netIndex: [String: [Int32]]         // network key -> streams

    // ---- guide model, sorted by start time
    let source: [LinkerProgramme]
    let order: [Int32]                      // sorted position -> index in `source`
    let starts: [Double]
    let ends: [Double]
    let chanOfPos: [Int32]                  // sorted position -> channel index
    let postingOffsets: [Int32]             // CSR over hash buckets: bucket b owns postingData[offsets[b]..<offsets[b+1]]
    let postingData: [Int32]                // ascending sorted positions (title + first 300 chars of description)

    public init(streams inStreams: [LinkerStream], programmes inProgs: [LinkerProgramme]) {
        // ---- streams
        var ss: [S] = []; ss.reserveCapacity(inStreams.count)
        var chanOf: [String: Int32] = [:]
        var chans: [Channel] = []
        var eventWords: [UInt32: [Int32]] = [:]
        var teamWords: [String: [Int32]] = [:]
        var netIdx: [String: [Int32]] = [:]
        var sportsCache: [String: Bool] = [:]
        var buf: [UInt8] = []
        for (i, s) in inStreams.enumerated() {
            let g = StreamLinker.normalizedGuide(s.guideID)
            var chan: Int32 = -1
            if !g.isEmpty {
                if let c = chanOf[g] { chan = c } else { chan = Int32(chans.count); chanOf[g] = chan; chans.append(Channel(id: g, streams: [], progs: [])) }
                chans[Int(chan)].streams.append(Int32(i))
            }
            let sports: Bool
            if let hit = sportsCache[s.category] { sports = hit } else { sports = LinkerPatterns.matches(LinkerPatterns.sportsCategory, LinkerText.clean(s.category)); sportsCache[s.category] = sports }
            let display = StreamLinker.displayName(s.name)
            buf.removeAll(keepingCapacity: true)
            LinkerText.appendClean(display, to: &buf)
            let isEvent = StreamLinker.hasEventHint(display: display, clean: buf)
            if isEvent {
                var seen = Set<UInt32>()
                LinkerText.forEachWord(buf, minBytes: 3) { if seen.insert($0).inserted { eventWords[$0, default: []].append(Int32(i)) } }
            } else if sports {
                let ws = buf.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }
                if ws.count <= 7 { for w in Set(ws) { teamWords[w, default: []].append(Int32(i)) } }
            }
            let nk = StreamLinker.netKey(buf)
            if StreamLinker.networkKeys.contains(nk) { netIdx[nk, default: []].append(Int32(i)) }
            ss.append(S(chan: chan, sports: sports, isEvent: isEvent))
        }
        input = inStreams; streams = ss; eventWordIndex = eventWords; teamWordIndex = teamWords; netIndex = netIdx

        // ---- programmes: keep only those whose guide id has a stream, sorted by start
        var keys: [UInt64] = []; keys.reserveCapacity(inProgs.count)
        var chanOfSource = [Int32](repeating: -1, count: inProgs.count)
        var lastRaw = "", lastChan: Int32 = -1
        precondition(inProgs.count < (1 << 24), "StreamLinker supports up to 16M programmes")
        for (i, p) in inProgs.enumerated() {
            let c: Int32
            if p.guideID == lastRaw { c = lastChan } else { c = chanOf[StreamLinker.normalizedGuide(p.guideID)] ?? -1; lastRaw = p.guideID; lastChan = c }
            guard c >= 0 else { continue }
            chanOfSource[i] = c
            keys.append(UInt64(max(0, p.start.timeIntervalSince1970)) << 24 | UInt64(i))
        }
        keys.sort()

        let n = keys.count
        var ord = [Int32](); ord.reserveCapacity(n)
        var pc = [Int32](); pc.reserveCapacity(n)
        var st = [Double](); st.reserveCapacity(n)
        var en = [Double](); en.reserveCapacity(n)
        var tokStart = [Int32](repeating: 0, count: n + 1)
        var tokens: [UInt32] = []; tokens.reserveCapacity(n * 24)
        var cursor = [Int32](repeating: 0, count: LinkerText.bucketCount + 1)      // counts first, then write cursors
        var hs: [UInt32] = []
        for (pos, key) in keys.enumerated() {
            let orig = Int(key & 0xFF_FFFF)
            let p = inProgs[orig]
            ord.append(Int32(orig)); pc.append(chanOfSource[orig])
            st.append(p.start.timeIntervalSince1970); en.append(p.end.timeIntervalSince1970)
            chans[Int(chanOfSource[orig])].progs.append(Int32(pos))
            buf.removeAll(keepingCapacity: true)
            LinkerText.appendClean(p.title, to: &buf)
            if let d = p.desc { LinkerText.appendClean(d, limit: 300, to: &buf) }
            hs.removeAll(keepingCapacity: true)
            LinkerText.forEachWord(buf, minBytes: 3) { hs.append($0) }
            hs.sort()
            var prev: UInt32? = nil
            for h in hs where h != prev { tokens.append(h); cursor[LinkerText.bucket(h)] += 1; prev = h }
            tokStart[pos + 1] = Int32(tokens.count)
        }
        var offsets = [Int32](repeating: 0, count: LinkerText.bucketCount + 1)
        var run: Int32 = 0
        for b in 0..<LinkerText.bucketCount { offsets[b] = run; run += cursor[b]; cursor[b] = offsets[b] }
        offsets[LinkerText.bucketCount] = run
        var data = [Int32](repeating: 0, count: Int(run))
        for pos in 0..<n {
            for t in Int(tokStart[pos])..<Int(tokStart[pos + 1]) {
                let b = LinkerText.bucket(tokens[t])
                data[Int(cursor[b])] = Int32(pos); cursor[b] += 1
            }
        }
        channels = chans; source = inProgs; order = ord; starts = st; ends = en; chanOfPos = pc; postingOffsets = offsets; postingData = data
    }

    /// Sizes of what the index holds, for logging and budgets.
    nonisolated public struct Stats: Sendable {
        public var streams: Int
        public var guideChannels: Int
        public var programmes: Int
        public var postings: Int
        public var approximateBytes: Int
    }
    public var stats: Stats {
        let bytes = postingData.count * 4 + postingOffsets.count * 4 + (starts.count + ends.count) * 8 + (order.count + chanOfPos.count) * 4
            + streams.count * MemoryLayout<S>.stride + channels.reduce(0) { $0 + ($1.streams.count + $1.progs.count) * 4 + $1.id.utf8.count + 48 }
        return Stats(streams: streams.count, guideChannels: channels.count, programmes: order.count, postings: postingData.count, approximateBytes: bytes)
    }

    // MARK: stream-name helpers

    static func normalizedGuide(_ g: String?) -> String {
        guard let g, !g.isEmpty else { return "" }
        let t = (g.utf8.first == 0x20 || g.utf8.last == 0x20) ? g.trimmingCharacters(in: .whitespaces) : g
        return t.lowercased()
    }

    @inline(__always) static func isSpace(_ u: UInt32) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0xA0 || (u > 0x7F && (Unicode.Scalar(u)?.properties.isWhitespace ?? false))
    }
    @inline(__always) static func isMarker(_ u: UInt32) -> Bool { u == 0x2605 || u == 0x2B50 || u == 0x2A || u == 0x7C || u == 0x3A }     // ★ ⭐ * | :
    static func isWordScalar(_ u: UInt32) -> Bool {
        if u < 0x80 { return (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
        guard let s = Unicode.Scalar(u) else { return false }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark: return true
        default: return false
        }
    }

    /// Skips the provider's channel-name prefix ("US ★ ", "UK | ", "CA: "): returns the index after the last complete group and the first group's letters.
    static func prefixScan(_ sc: [UInt32]) -> (end: Int, code: String?) {
        var i = 0, end = 0
        var code: String? = nil
        let n = sc.count
        while true {
            var j = i
            while j < n && isSpace(sc[j]) { j += 1 }
            var k = j
            while k < n, k - j < 4, sc[k] >= 65, sc[k] <= 90 { k += 1 }
            guard k - j >= 2 else { break }
            var m = k
            while m < n && isSpace(sc[m]) { m += 1 }
            guard m < n, isMarker(sc[m]) else { break }
            if code == nil { code = String(String.UnicodeScalarView(sc[j..<k].compactMap(Unicode.Scalar.init))) }
            while m < n && isMarker(sc[m]) { m += 1 }
            while m < n && isSpace(sc[m]) { m += 1 }
            i = m; end = m
        }
        return (end, code)
    }

    /// "US ★ ESPN2 HD" -> "ESPN2": region prefix, ◉ ● ★ and standalone quality words removed, whitespace collapsed.
    static func displayName(_ name: String) -> String {
        var sc: [UInt32] = []; sc.reserveCapacity(name.utf8.count)
        LinkerText.appendCompat(name, to: &sc)
        var i = prefixScan(sc).end
        let n = sc.count
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        func put(_ u: UInt32) {
            guard let s = Unicode.Scalar(u) else { return }
            if pendingSpace { if !out.isEmpty { out.append(" ") }; pendingSpace = false }
            out.append(s)
        }
        while i < n {
            let u = sc[i]
            if isWordScalar(u) {
                var j = i
                while j < n && isWordScalar(sc[j]) { j += 1 }
                if isQualityWord(sc, i, j) { pendingSpace = true } else { for k in i..<j { put(sc[k]) } }
                i = j
            } else {
                if u == 0x25C9 || u == 0x25CF || u == 0x2605 || isSpace(u) { pendingSpace = true } else { put(u) }
                i += 1
            }
        }
        var s = String(out)
        while let f = s.unicodeScalars.first, f == " " || f == ":" || f == "-" { s.unicodeScalars.removeFirst() }
        while let l = s.unicodeScalars.last, l == " " || l == ":" || l == "-" { s.unicodeScalars.removeLast() }
        return s
    }

    /// HD / FHD / UHD / SD / 4K (any case), as a whole word.
    static func isQualityWord(_ sc: [UInt32], _ from: Int, _ to: Int) -> Bool {
        let len = to - from
        guard len == 2 || len == 3 else { return false }
        var w = ""
        for k in from..<to { guard sc[k] < 0x80 else { return false }; w.unicodeScalars.append(Unicode.Scalar(sc[k] | 0x20)!) }     // | 0x20 lowercases ASCII letters
        return w == "hd" || w == "sd" || w == "fhd" || w == "uhd" || w == "4k"
    }

    static func regionOf(name: String, guide: String) -> String {
        var sc: [UInt32] = []
        LinkerText.appendCompat(name, to: &sc)
        if let code = prefixScan(sc).code { return code }
        if let dot = guide.lastIndex(of: "."), guide.distance(from: dot, to: guide.endIndex) > 1 { return String(guide[guide.index(after: dot)...]).uppercased() }
        return ""
    }

    static func family(_ display: String, region: String) -> String {
        let stop: Set<String> = ["hd", "fhd", "uhd", "sd", "east", "west", "pacific", "central", "feed", "channel", "tv"]
        let toks = LinkerText.words(display).filter { !stop.contains($0) && Int($0) == nil }
        return (region.isEmpty ? "?" : region) + ":" + (toks.first ?? "?")
    }

    static let netDrop: Set<Substring> = ["east", "west", "pacific", "central", "mountain", "hd", "fhd", "uhd", "sd", "4k", "feed", "live", "plus"]
    /// Clean bytes of a display name -> network key ("espn 2 hd east" -> "espn2").
    static func netKey(_ clean: [UInt8]) -> String {
        String(decoding: clean, as: UTF8.self).split(separator: " ").filter { !netDrop.contains($0) }.joined()
    }

    static let qualityTable: [(String, Int)] = [("4k", 9), ("uhd", 9), ("fhd", 8), ("1080", 8), ("hd", 6), ("720", 5), ("sd", 2)]
    static func quality(_ name: String) -> Int {
        let c = LinkerText.clean(name)
        var q = 4, found = false
        for (k, v) in qualityTable where LinkerText.hasPhrase(c, k) { q = found ? max(q, v) : v; found = true }
        if c.split(separator: " ").contains(where: { $0 == "backup" || $0 == "bk" || $0 == "bckp" }) { q -= 3 }
        return q
    }

    /// Does the name read like a fixture? ("vs", "v", "at", "@", " - ")
    static func hasEventHint(display: String, clean: [UInt8]) -> Bool {
        var d = display
        let punct = d.withUTF8 { p -> Bool in
            for i in 0..<p.count {
                if p[i] == 0x40 { return true }                                                                   // @
                if p[i] == 0x2D, i > 0, i + 1 < p.count, p[i - 1] == 0x20, p[i + 1] == 0x20 { return true }        // " - "
            }
            return false
        }
        if punct { return true }
        var i = 0
        let n = clean.count
        while i < n {
            var j = i
            while j < n && clean[j] != 0x20 { j += 1 }
            let len = j - i
            if len == 1, clean[i] == 0x76 { return true }                                                          // v
            if len == 2, (clean[i] == 0x76 && clean[i + 1] == 0x73) || (clean[i] == 0x61 && clean[i + 1] == 0x74) { return true }   // vs, at
            i = j + 1
        }
        return false
    }

    static func parseEventName(_ name: String) -> EventName {
        var sc: [UInt32] = []
        LinkerText.appendCompat(name, to: &sc)
        let start = prefixScan(sc).end
        var view = String.UnicodeScalarView()
        for u in sc[start...] { if let s = Unicode.Scalar(u) { view.append(s) } }
        var n = String(view)
        n = LinkerPatterns.bracketQuality.stringByReplacingMatches(in: n, range: NSRange(location: 0, length: n.utf16.count), withTemplate: " ")
        var times: [(Int, Int, String)] = []
        let ns = n as NSString
        for m in LinkerPatterns.time.matches(in: n, range: NSRange(location: 0, length: ns.length)) {
            var h = (Int(ns.substring(with: m.range(at: 1))) ?? 0) % 12
            if ns.substring(with: m.range(at: 3)).uppercased() == "PM" { h += 12 }
            let mi = m.range(at: 2).location != NSNotFound ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
            let tz = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)).uppercased() : "ET"
            times.append((h, mi, tz))
        }
        var iso: (Int, Int, Int)? = nil
        if let m = LinkerPatterns.iso.firstMatch(in: n, range: NSRange(location: 0, length: ns.length)) {
            iso = (Int(ns.substring(with: m.range(at: 1))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 0, Int(ns.substring(with: m.range(at: 3))) ?? 0)
        }
        return EventName(head: n, times: times.map { (h: $0.0, m: $0.1, tz: $0.2) }, iso: iso.map { (y: $0.0, mo: $0.1, d: $0.2) })
    }

    // MARK: fixture matching

    /// "A <separator> B" (either order); returns (matched, number of separators).
    static func fixtureIn(_ head: String, _ a: Set<String>, _ b: Set<String>) -> (Bool, Int) {
        let h = head.decomposedStringWithCompatibilityMapping
        let ns = h as NSString
        let seps = LinkerPatterns.separator.matches(in: h, range: NSRange(location: 0, length: ns.length))
        guard !seps.isEmpty else { return (false, 0) }
        for m in seps {
            let left = LinkerText.variants(LinkerText.clean(ns.substring(to: m.range.location)))
            let right = LinkerText.variants(LinkerText.clean(ns.substring(from: m.range.location + m.range.length)))
            for (x, y) in [(a, b), (b, a)] {
                if LinkerText.hasAny(left, x) && LinkerText.hasAny(right, y) { return (true, seps.count) }
            }
        }
        return (false, seps.count)
    }

    /// Fallback for name variants ("Celta B" vs "RC Celta Fortuna"): each side of a single separator holds a distinctive token of a different team.
    static func fuzzyFixture(_ head: String, _ ta: Set<String>, _ tb: Set<String>) -> Bool {
        let h = head.decomposedStringWithCompatibilityMapping
        let ns = h as NSString
        let seps = LinkerPatterns.separator.matches(in: h, range: NSRange(location: 0, length: ns.length))
        guard seps.count == 1, head.count < 100, let m = seps.first else { return false }
        let left = Set(LinkerText.words(ns.substring(to: m.range.location))), right = Set(LinkerText.words(ns.substring(from: m.range.location + m.range.length)))
        return (!left.isDisjoint(with: ta) && !right.isDisjoint(with: tb)) || (!left.isDisjoint(with: tb) && !right.isDisjoint(with: ta))
    }

    static func namesBoth(_ text: String, _ a: Set<String>, _ b: Set<String>) -> Bool {
        let c = LinkerText.variants(LinkerText.clean(text))
        return LinkerText.hasAny(c, a) && LinkerText.hasAny(c, b)
    }

    static func distinctiveTokens(_ team: LinkerTeam, national: Bool) -> Set<String> {
        var out = Set<String>()
        for a in LinkerAliases.of(team, national: national) { for t in a.split(separator: " ") where t.count >= 5 && !LinkerAliases.generic.contains(String(t)) { out.insert(String(t)) } }
        return out
    }

    static let zones: [String: TimeZone] = {
        let ids = ["ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York", "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
                   "MT": "America/Denver", "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles", "UK": "Europe/London", "GMT": "Europe/London",
                   "BST": "Europe/London", "CET": "Europe/Paris", "CEST": "Europe/Paris"]
        return ids.compactMapValues { TimeZone(identifier: $0) }
    }()

    static func kickoffMatches(_ times: [(h: Int, m: Int, tz: String)], _ kickoff: Date, tolMinutes: Int = 25) -> Bool {
        for t in times {
            var cal = Calendar(identifier: .gregorian); cal.timeZone = zones[t.tz] ?? zones["ET"]!
            let c = cal.dateComponents([.hour, .minute], from: kickoff)
            if abs((c.hour ?? 0) * 60 + (c.minute ?? 0) - (t.h * 60 + t.m)) <= tolMinutes { return true }
        }
        return false
    }

    static func nextGame(_ title: String) -> (String, (Int, Int, Int))? {
        guard title.utf8.count > 10, let m = LinkerPatterns.nextGame.firstMatch(in: title, range: NSRange(location: 0, length: title.utf16.count)) else { return nil }
        let ns = title as NSString
        return (ns.substring(with: m.range(at: 1)), (Int(ns.substring(with: m.range(at: 2))) ?? 0, Int(ns.substring(with: m.range(at: 3))) ?? 0, Int(ns.substring(with: m.range(at: 4))) ?? 0))
    }

    static func dayDelta(_ d: (Int, Int, Int), _ ko: Date) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var c = DateComponents(); c.year = d.0; c.month = d.1; c.day = d.2
        guard let a = cal.date(from: c) else { return 99 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: ko), to: a).day ?? 99
    }

    // MARK: rights (sports-API broadcaster -> playlist network)

    static let networks: [String: [String]] = [
        "espn": ["espn"], "espn2": ["espn2"], "espnu": ["espnu"], "tnt": ["tnt"], "trutv": ["trutv"],
        "sn": ["sportsnet", "sportsnetontario", "sportsnetone", "sportsneteast", "sportsnetpacific", "sportsnetwest", "sportsnet360"],
        "tvas": ["tvasports"], "tvas2": ["tvasports2"], "cnbc": ["cnbc"], "usanet": ["usanetwork"], "fs1": ["foxsports1", "fs1"], "fs2": ["foxsports2", "fs2"],
        "universo": ["nbcuniverso", "universo"], "msgsn": ["msgsportsnet", "msgsn", "msg"], "abc": ["abc"], "cbs": ["cbs"], "nbc": ["nbc"], "fox": ["fox"],
        "tsn": ["tsn", "tsn1", "tsn2", "tsn3", "tsn4", "tsn5"], "nflnetwork": ["nflnetwork"], "mlbnetwork": ["mlbnetwork"], "nhlnetwork": ["nhlnetwork"],
        "goltv": ["goltv"], "univision": ["univision"], "telemundo": ["telemundo"], "cbssn": ["cbssportsnetwork"],
    ]
    static let networkKeys: Set<String> = Set(networks.values.flatMap { $0 })
    static let networkRegion: [String: String] = ["sn": "CA", "tvas": "CA", "tvas2": "CA", "tsn": "CA"]   // everything else defaults to US

    static let languages: [String: String] = ["US": "en", "CA": "en", "UK": "en", "GB": "en", "AU": "en", "NL": "nl", "DE": "de", "AT": "de", "CH": "de", "FR": "fr", "BE": "fr",
                                              "IT": "it", "ES": "es", "AR": "es", "MX": "es", "PT": "pt", "BR": "pt", "PL": "pl", "GR": "el", "TR": "tr", "BI-AR": "ar"]

    // MARK: candidate retrieval

    func postingRange(_ word: String) -> Range<Int> {
        let b = LinkerText.bucket(LinkerText.hash(word))
        return Int(postingOffsets[b])..<Int(postingOffsets[b + 1])
    }

    /// Sorted positions in [lo, hi) whose title/description mention every word of at least one alias (probing only the alias's rarest word — a superset the
    /// fixture readers then verify) or one of the distinctive `extra` tokens.
    func candidatePositions(aliases: Set<String>, extra: Set<String>, lo: Int, hi: Int) -> [Int32] {
        var out: [Int32] = []
        func take(_ r: Range<Int>) {
            var a = r.lowerBound, b = r.upperBound
            while a < b { let m = (a + b) >> 1; if Int(postingData[m]) < lo { a = m + 1 } else { b = m } }
            while a < r.upperBound, Int(postingData[a]) < hi { out.append(postingData[a]); a += 1 }
        }
        for alias in aliases {
            var best: Range<Int>? = nil
            var absent = false
            for w in alias.split(separator: " ") where w.utf8.count >= 3 {
                let r = postingRange(String(w))
                if r.isEmpty { absent = true; break }
                if best == nil || r.count < best!.count { best = r }
            }
            if !absent, let best { take(best) }
        }
        for t in extra { let r = postingRange(t); if !r.isEmpty { take(r) } }
        out.sort()
        var uniq: [Int32] = []; uniq.reserveCapacity(out.count)
        for v in out where uniq.last != v { uniq.append(v) }
        return uniq
    }

    /// Fixture-named streams that contain the rarest word of at least one alias.
    func eventStreamCandidates(_ aliases: Set<String>) -> [Int32] {
        var out = Set<Int32>()
        for alias in aliases {
            var best: [Int32]? = nil
            var absent = false
            for w in alias.split(separator: " ") where w.utf8.count >= 3 {
                guard let l = eventWordIndex[LinkerText.hash(String(w))] else { absent = true; break }
                if best == nil || l.count < best!.count { best = l }
            }
            if !absent, let best { out.formUnion(best) }
        }
        return out.sorted()
    }

    static func intersect(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var out: [Int32] = []
        var i = 0, j = 0
        while i < a.count, j < b.count { if a[i] == b[j] { out.append(a[i]); i += 1; j += 1 } else if a[i] < b[j] { i += 1 } else { j += 1 } }
        return out
    }

    /// Does this guide channel have a normal-length programme on air across [t0, t1]?
    func covers(channel c: Int, from t0: TimeInterval, to t1: TimeInterval) -> Bool {
        let list = channels[c].progs
        var a = 0, b = list.count
        while a < b { let m = (a + b) >> 1; if starts[Int(list[m])] <= t1 { a = m + 1 } else { b = m } }
        var i = a - 1, steps = 0
        while i >= 0, steps < 6 {
            let p = Int(list[i])
            if ends[p] >= t0, ends[p] - starts[p] <= 6 * 3600 { return true }
            i -= 1; steps += 1
        }
        return false
    }

    func lowerBound(_ t: TimeInterval) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi { let mid = (lo + hi) >> 1; if starts[mid] < t { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    nonisolated struct Builder { var idx: [Int32]; var tier: LinkTier = .likelyRights; var conf: Double = 0; var label = ""; var why = ""; var prog: String? }

    // MARK: link

    public func link(_ event: LinkerEvent, preMinutes: Int = 30, postMinutes: Int = 15) -> [LinkedFeed] {
        let ko = event.kickoff
        let kts = ko.timeIntervalSince1970
        let nat = event.isNational
        var A = LinkerAliases.of(event.home, national: nat), B = LinkerAliases.of(event.away, national: nat)
        let FA = LinkerAliases.of(event.home, national: nat, fullOnly: true), FB = LinkerAliases.of(event.away, national: nat, fullOnly: true)
        let shared = A.intersection(B); A.subtract(shared); B.subtract(shared)
        let fullNames: Set<String> = [LinkerText.clean(event.home.name), LinkerText.clean(event.away.name)]
        let dHome = StreamLinker.distinctiveTokens(event.home, national: nat), dAway = StreamLinker.distinctiveTokens(event.away, national: nat)
        let tokA = dHome.subtracting(dAway), tokB = dAway.subtracting(dHome)

        var feeds: [String: Builder] = [:]
        var feedOrder: [String] = []
        func add(_ key: String, _ idx: [Int32], _ tier: LinkTier, _ conf: Double, _ label: String, _ why: String, _ prog: String? = nil) {
            if feeds[key] == nil { feeds[key] = Builder(idx: idx); feedOrder.append(key) }
            if conf > feeds[key]!.conf { feeds[key]!.tier = tier; feeds[key]!.conf = conf; feeds[key]!.label = label; feeds[key]!.why = why; feeds[key]!.prog = prog }
        }

        // ---- guide. Candidates: programmes starting in [kickoff-36h, kickoff+pre] that mention both teams.
        //      "Next Game: A @ B on <date>" on a team channel is read wherever it starts; every other listing must be on air across kickoff.
        let earlyLo = lowerBound(kts - 36 * 3600), lo = lowerBound(kts - 6 * 3600), hi = lowerBound(kts + Double(preMinutes) * 60 + 1)
        let cA = candidatePositions(aliases: A.union(FA), extra: tokA, lo: earlyLo, hi: hi)
        let cB = candidatePositions(aliases: B.union(FB), extra: tokB, lo: earlyLo, hi: hi)
        for pos in StreamLinker.intersect(cA, cB) {
            let i = Int(pos)
            let chan = channels[Int(chanOfPos[i])]
            let src = source[Int(order[i])]
            if let (fx, date) = StreamLinker.nextGame(src.title) {
                if StreamLinker.namesBoth(fx, A, B), abs(StreamLinker.dayDelta(date, ko)) <= 1 {
                    add("g:" + chan.id, chan.streams, .teamChannel, 0.62, "Team channel", "guide \(src.guideID): \(src.title.prefix(70))", src.title)
                }
                continue
            }
            guard i >= lo, ends[i] >= kts + Double(postMinutes) * 60, ends[i] - starts[i] <= 6 * 3600 else { continue }
            let (head, live) = LinkerText.splitBadge(src.title)
            if LinkerPatterns.matches(LinkerPatterns.placeholder, head) || LinkerPatterns.matches(LinkerPatterns.replay, head) { continue }
            let coverage = LinkerPatterns.matches(LinkerPatterns.coverage, head)
            let key = "g:" + chan.id
            let why = "guide \(src.guideID): \(src.title.prefix(70))"
            var matched = false
            let (ok, nseps) = StreamLinker.fixtureIn(head, A, B)
            if ok {
                if coverage { add(key, chan.streams, .coverage, 0.35, "Coverage show", why, src.title) }
                else { add(key, chan.streams, .liveListing, nseps == 1 ? (live ? 0.97 : 0.92) : 0.8, "Live listing", why, src.title) }
                matched = true
            } else if StreamLinker.namesBoth(head, A, B) {
                add(key, chan.streams, coverage ? .coverage : .liveListing, coverage ? 0.3 : 0.7, coverage ? "Coverage show" : "Live listing", why, src.title)
                matched = true
            }
            if !matched {          // generic title ("Hockey sur glace : NHL"): the description may carry the fixture
                let desc = String((src.desc ?? "").prefix(300))
                if !desc.isEmpty, StreamLinker.namesBoth(desc, FA, FB), !LinkerPatterns.matches(LinkerPatterns.replay, String(desc.prefix(200))) {
                    add(key, chan.streams, .listingByDescription, 0.72, "Live listing (description)", "guide \(src.guideID): \(src.title.prefix(60)) || \(desc.prefix(60))", src.title)
                    matched = true
                }
            }
            if !matched, !coverage, StreamLinker.fuzzyFixture(head, tokA, tokB) {
                add(key, chan.streams, .liveListing, 0.75, "Live listing (name variant)", why, src.title)
            }
        }

        // ---- T4: event-slot channels whose NAME carries the fixture
        for i32 in StreamLinker.intersect(eventStreamCandidates(A.union(FA)), eventStreamCandidates(B.union(FB))) {
            let i = Int(i32)
            let name = input[i].name
            let ev = StreamLinker.parseEventName(name)
            guard StreamLinker.fixtureIn(ev.head, A, B).0 else { continue }
            if let iso = ev.iso {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
                let c = cal.dateComponents([.year, .month, .day], from: ko)
                var d = DateComponents(); d.year = iso.y; d.month = iso.mo; d.day = iso.d
                if let a = cal.date(from: d), let b = cal.date(from: c), abs(cal.dateComponents([.day], from: a, to: b).day ?? 99) > 1 { continue }
            }
            if !ev.times.isEmpty {
                if StreamLinker.kickoffMatches(ev.times, ko) { add("n:" + input[i].id, [i32], .eventChannel, 0.85, "Event channel", "channel name: \(name.prefix(70))") }
            } else {
                add("n:" + input[i].id, [i32], .eventChannel, 0.5, "Event channel (no time)", "channel name (no time): \(name.prefix(70))")
            }
        }

        // ---- T3: dedicated team channels named after a participant
        var teamCands = Set<Int32>()
        let fullVariants = fullNames.union(fullNames.map(LinkerText.withoutConnectors))
        for full in fullNames {
            let ws = full.split(separator: " ").map(String.init)
            guard let rare = ws.min(by: { (teamWordIndex[$0]?.count ?? 0) < (teamWordIndex[$1]?.count ?? 0) }), let list = teamWordIndex[rare] else { continue }
            for i in list where LinkerText.hasAny(LinkerText.variants(LinkerText.clean(StreamLinker.displayName(input[Int(i)].name))), fullVariants) { teamCands.insert(i) }
        }
        for i32 in teamCands.sorted() {
            let s = streams[Int(i32)]
            if s.chan >= 0, feeds["g:" + channels[Int(s.chan)].id] != nil { continue }
            add("t:" + input[Int(i32)].id, [i32], .teamChannel, 0.5, "Team channel (unverified)", "team channel: \(input[Int(i32)].name.prefix(60))")
        }

        // ---- T5: broadcast partners named by the sports API, same region, unless their own guide shows something else at kickoff
        var wanted: [String: String] = [:]
        for n in event.broadcasts {
            let k = String(LinkerText.clean(n).filter { $0 != " " })
            for nk in StreamLinker.networks[k] ?? [] { wanted[nk] = StreamLinker.networkRegion[k] ?? "US" }
        }
        var partners: [(stream: Int32, region: String)] = []
        for (nk, region) in wanted { for i in netIndex[nk] ?? [] { partners.append((i, region)) } }
        partners.sort { $0.stream < $1.stream }                       // playlist order: deterministic output
        for (i32, region) in partners {
            let i = Int(i32)
            let s = streams[i]
            var r = StreamLinker.regionOf(name: input[i].name, guide: input[i].guideID ?? "")
            if r == "CAF" { r = "CA" }
            guard r == region else { continue }
            if s.chan >= 0 {
                let c = Int(s.chan)
                if feeds["g:" + channels[c].id] != nil { continue }
                if covers(channel: c, from: kts + Double(postMinutes) * 60, to: kts + Double(preMinutes) * 60) { continue }
                add("r:" + channels[c].id, channels[c].streams, .likelyRights, 0.6, "Likely (broadcast partner)", "sports data lists this network (channel guide ends before kickoff)")
            } else {
                add("r:" + input[i].id, [i32], .likelyRights, 0.6, "Likely (broadcast partner)", "sports data lists this network (channel has no guide)")
            }
        }

        // ---- assemble: mirrors best quality first, feeds by confidence then discovery order
        var out: [LinkedFeed] = []
        out.reserveCapacity(feedOrder.count)
        for key in feedOrder {
            let b = feeds[key]!
            let ranked = b.idx.enumerated().map { (offset: $0.offset, i: Int($0.element), q: StreamLinker.quality(input[Int($0.element)].name)) }
                .sorted { ($0.q, -$0.offset) > ($1.q, -$1.offset) }
            let top = input[ranked[0].i]
            let region = StreamLinker.regionOf(name: top.name, guide: top.guideID ?? "")
            let display = StreamLinker.displayName(top.name)
            out.append(LinkedFeed(key: key, tier: b.tier, confidence: b.conf, label: b.label, region: region, language: StreamLinker.languages[region] ?? "",
                                  displayName: display, family: StreamLinker.family(display, region: region), streamIDs: ranked.map { input[$0.i].id },
                                  evidence: b.why, programmeTitle: b.prog))
        }
        return out.enumerated().sorted { ($0.element.confidence, -$0.offset) > ($1.element.confidence, -$1.offset) }.map(\.element)
    }
}

// MARK: - Grouping helper for the UI (collapses e.g. a dozen Univision local affiliates into one family)

nonisolated public struct LinkedFamily: Sendable {
    public var family: String
    public var best: LinkedFeed
    public var members: [LinkedFeed]
}

nonisolated public extension Array where Element == LinkedFeed {
    func groupedByFamily() -> [LinkedFamily] {
        var order: [String] = []; var map: [String: [LinkedFeed]] = [:]
        for f in self { if map[f.family] == nil { order.append(f.family) }; map[f.family, default: []].append(f) }
        return order.map { LinkedFamily(family: $0, best: map[$0]![0], members: map[$0]!) }
    }
}
