import Foundation

/// Channel-name identity for event discovery. Decoration is disposable; network numbers,
/// regional feeds and plus services are not. This does not infer current programming.
nonisolated struct ProviderChannelIdentity: Sendable {
    let tokens: [String]
    let country: String?
    let eventText: String
    var key: String { tokens.joined(separator: " ") }

    private static let countryCodes: [String: String] = [
        "CAF": "CA", "CA": "CA", "CAN": "CA", "US": "US", "USA": "US",
        "UK": "GB", "GB": "GB", "AU": "AU", "NZ": "NZ", "FR": "FR", "DE": "DE",
        "BE": "BE", "NL": "NL", "ES": "ES", "IT": "IT", "PT": "PT", "TR": "TR",
        "PL": "PL", "IN": "IN", "AR": "AR", "MX": "MX", "BR": "BR", "CL": "CL",
        "CO": "CO", "PE": "PE", "EC": "EC", "GR": "GR", "AT": "AT", "CH": "CH",
        "DK": "DK", "SE": "SE", "NO": "NO", "FI": "FI", "IE": "IE", "RO": "RO",
        "ZA": "ZA", "JP": "JP", "KR": "KR", "CN": "CN", "SA": "SA", "QA": "QA",
    ]
    private static let prefix = try! NSRegularExpression(
        pattern: #"^\s*\[?([A-Z]{2,3})\]?\s*(?:[★⭐*|:]|\s+-)\s*"#, options: .caseInsensitive)
    private static let quality = try! NSRegularExpression(
        pattern:
            #"(?i)(?<![\p{L}\p{N}])(?:FULL\s*HD|FHD|UHD|HD|SD|4K|8K|1080[PI]?|720P?|2160P?|HEVC|H[.]?26[45]|X26[45]|50FPS|60FPS)[²³]?(?![\p{L}\p{N}])"#
    )
    private static let noise: Set<String> = ["backup", "bk", "bckp", "vip", "raw"]

    init(_ name: String) {
        var value = name
        var hint: String?
        if let match = Self.prefix.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let codeRange = Range(match.range(at: 1), in: value),
            let prefixRange = Range(match.range, in: value)
        {
            let code = String(value[codeRange]).uppercased()
            if let country = Self.countryCodes[code] {
                hint = country
                value.removeSubrange(prefixRange)
            }
        }
        country = hint
        // Remove superscript quality replicas before folding; HD² must never become network 2.
        value = Self.quality.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        value = Self.text(value)
        eventText = value
        value = value.replacingOccurrences(
            of: #"([a-z])(\d)|(?<=\d)(?=[a-z])"#,
            with: "$1 $2", options: .regularExpression)
        var words = value.split(separator: " ").map(String.init).filter { !Self.noise.contains($0) }
        // Documented spelling aliases, not edit-distance guesses between sibling channels.
        let aliases: [([String], [String])] = [
            (["fox", "sports", "1"], ["fs", "1"]), (["fox", "sports", "2"], ["fs", "2"]),
            (["espn", "u"], ["espnu"]), (["espn", "news"], ["espnews"]),
            (["espn", "acc", "network"], ["acc", "network"]),
            (["espn", "sec", "network"], ["sec", "network"]),
            (["bein", "sport"], ["bein", "sports"]),
            (["tntsports"], ["tnt", "sports"]), (["nbatv"], ["nba", "tv"]),
        ]
        for (from, to) in aliases where words.starts(with: from) {
            words = to + words.dropFirst(from.count)
            break
        }
        tokens = words
    }

    /// Text tokenization keeps sport labels and participant words, unlike provider cleanup.
    static func text(_ input: String) -> String {
        let folded = input.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
            .replacingOccurrences(of: "+", with: " plus ")
            .replacingOccurrences(of: "@", with: " versus ")
        return String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    func exactlyMatches(_ other: Self) -> Bool {
        !tokens.isEmpty && tokens == other.tokens && countriesAgree(with: other)
    }

    func countriesAgree(with other: Self) -> Bool {
        country == nil || other.country == nil || country == other.country
    }

    /// A policy may name a network family (TSN) instead of TSN1. Such evidence is only
    /// a possible rights-holder, never proof of a particular programme or stream.
    func belongs(to family: Self) -> Bool {
        guard countriesAgree(with: family), !family.tokens.isEmpty,
            tokens.starts(with: family.tokens)
        else { return false }
        if tokens.contains("plus") != family.tokens.contains("plus") { return false }
        if family.tokens.last?.allSatisfy(\.isNumber) == true { return tokens == family.tokens }
        return true
    }

    func isSibling(of other: Self) -> Bool {
        guard let first = tokens.first, first == other.tokens.first else { return false }
        return tokens != other.tokens
    }
}
