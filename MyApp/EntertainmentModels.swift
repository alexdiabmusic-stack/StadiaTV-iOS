import Foundation

nonisolated enum EntertainmentKind: String, Codable, Sendable, CaseIterable {
    case movie, series, episode
}

nonisolated enum ContentAvailability: String, Codable, Sendable {
    case available, unavailable, unknown, unreleased
}

nonisolated enum MetadataConfidence: String, Codable, Sendable {
    case verifiedIdentifier, highConfidence, ambiguous, unmatched
}

nonisolated enum MetadataOrigin: String, Codable, Sendable {
    case provider, tmdb, user, local
}

/// Source references are safe to persist. URLs and credentials are resolved at playback time.
nonisolated struct EntertainmentSource: Codable, Hashable, Identifiable, Sendable {
    var sourceID: UUID
    var itemID: String
    var kind: EntertainmentKind
    var container: String?
    var category: String?
    var quality: String?
    var language: String?
    var availability: ContentAvailability = .available
    var checkedAt: Date = Date()
    var id: String { "\(sourceID.uuidString):\(kind.rawValue):\(itemID)" }
}

nonisolated struct EntertainmentCredit: Codable, Hashable, Sendable {
    var name: String
    var role: String?
    var portrait: URL?
}

nonisolated struct EntertainmentRating: Codable, Hashable, Sendable {
    var value: Double
    var scale: Double
    var source: String
}

nonisolated struct EntertainmentMetadata: Codable, Hashable, Sendable {
    var canonicalTitle: String?
    var originalTitle: String?
    var year: Int?
    var overview: String?
    var genres: [String] = []
    var runtimeMinutes: Int?
    var contentRating: String?
    var poster: URL?
    var backdrop: URL?
    var titleLogo: URL?
    var tmdbID: Int?
    var imdbID: String?
    var cast: [EntertainmentCredit] = []
    var director: String?
    var ratings: [EntertainmentRating] = []
    var firstAirDate: String?
    var lastAirDate: String?
    var status: String?
    var confidence: MetadataConfidence = .unmatched
    var provenance: [String: MetadataOrigin] = [:]
}

nonisolated struct EntertainmentItem: Codable, Hashable, Identifiable, Sendable {
    /// Provider-scoped until identity is verified. Never derived from a title alone.
    var id: String
    var kind: EntertainmentKind
    var providerTitle: String
    var metadata = EntertainmentMetadata()
    var sources: [EntertainmentSource] = []
    var addedAt: Date?
    var seriesID: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var airDate: String?
    var title: String { metadata.canonicalTitle ?? providerTitle }
    /// Reliable metadata identity can carry progress between provider variants.
    var progressID: String {
        guard let id = metadata.tmdbID, [.verifiedIdentifier, .highConfidence].contains(metadata.confidence) else { return self.id }
        let version = kind == .movie ? ":" + EntertainmentMatching.normalized(providerTitle) : ""
        return "\(kind.rawValue):tmdb:\(id)\(version)"
    }
    var isPlayable: Bool { kind != .series && sources.contains { $0.availability == .available && $0.container?.isEmpty == false } }
}

nonisolated struct EntertainmentSeason: Codable, Hashable, Identifiable, Sendable {
    var seriesID: String
    var number: Int
    var name: String?
    var overview: String?
    var poster: URL?
    var airDate: String?
    var episodes: [EntertainmentItem]
    var id: String { "\(seriesID):season:\(number)" }
}

nonisolated struct EntertainmentProgress: Codable, Equatable, Sendable {
    var contentID: String
    var sourceVariantID: String
    var position: Double
    var duration: Double?
    var lastWatched: Date
    var completed: Bool

    static func recording(contentID: String, variant: String, position: Double, duration: Double?, at date: Date = Date()) -> Self? {
        guard position.isFinite, position >= 0 else { return nil }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Self(contentID: contentID, sourceVariantID: variant,
                    position: duration.map { min(position, $0) } ?? position,
                    duration: duration, lastWatched: date,
                    completed: duration.map { position >= $0 * 0.95 && position >= 60 } ?? false)
    }
}

/// Tolerant JSON values isolate inconsistent provider number/string/null fields at the boundary.
nonisolated enum EntertainmentJSON: Codable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else if let v = try? c.decode([Self].self) { self = .array(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var array: [Self] { if case .array(let v) = self { return v }; return [] }
    var object: [String: Self] { if case .object(let v) = self { return v }; return [:] }
    var string: String? {
        switch self { case .string(let v): return v.isEmpty ? nil : v
        case .number(let v): return v.isFinite && v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: return nil }
    }
    var int: Int? { string.flatMap(Int.init) }
    var double: Double? { string.flatMap(Double.init) }
}

nonisolated enum EntertainmentMatching {
    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Exact normalized title AND year, with a unique candidate, are required for automatic title matching.
    static func match(title: String, year: Int?, candidates: [EntertainmentMetadata]) -> EntertainmentMetadata? {
        guard let year else { return nil }
        let key = normalized(title)
        let matches = candidates.filter {
            $0.year == year && [ $0.canonicalTitle, $0.originalTitle ].compactMap { $0 }.contains { normalized($0) == key }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    static func episodeNumbers(_ title: String) -> (season: Int, episode: Int)? {
        let pattern = #"(?i)\b(?:S(\d{1,2})E(\d{1,3})|Season\s+(\d{1,2})\s+Episode\s+(\d{1,3}))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        let offset = match.range(at: 1).location == NSNotFound ? 3 : 1
        guard let s = Range(match.range(at: offset), in: title), let e = Range(match.range(at: offset + 1), in: title),
              let season = Int(title[s]), let episode = Int(title[e]) else { return nil }
        // Combined episodes remain unclassified rather than assigning misleading episode identity.
        guard let fullRange = Range(match.range, in: title) else { return nil }
        let tail = String(title[fullRange.upperBound...])
        guard tail.range(of: #"^(?:E\d|[-–]\s*(?:E)?\d)"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return (season, episode)
    }
}

nonisolated protocol EntertainmentInventoryAdapter: Sendable {
    func inventory() async throws -> [EntertainmentItem]
    func seasons(for series: EntertainmentItem) async throws -> [EntertainmentSeason]
}

/// Future authorized addon adapters implement inventory, metadata and playback separately.
nonisolated protocol EntertainmentPlaybackResolver: Sendable {
    func resolve(_ source: EntertainmentSource) async throws -> URL
}

nonisolated enum EntertainmentError: Error, LocalizedError {
    case configuration, authentication, unavailable, malformed, metadataDisabled, rateLimited
    var errorDescription: String? {
        switch self {
        case .configuration: return String(localized: "Check this source's configuration in Settings.")
        case .authentication: return String(localized: "This source could not authenticate. Update its credentials in Settings.")
        case .unavailable: return String(localized: "The source is unavailable. Try again later.")
        case .malformed: return String(localized: "The source returned an unsupported response.")
        case .metadataDisabled: return String(localized: "External metadata is not configured. Provider information remains available.")
        case .rateLimited: return String(localized: "The metadata service is busy. Try again later.")
        }
    }
}
