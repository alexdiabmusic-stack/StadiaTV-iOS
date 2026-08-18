import Foundation

// MARK: - EPG Source definition

struct EPGSource: Identifiable, Hashable {
    let id: String
    let displayName: String
    let url: URL
    let categoryIds: [String]   // guide category IDs this source covers
    let priority: Int           // lower = higher priority
    let cacheTTL: TimeInterval
    var isEnabled: Bool

    static func == (lhs: EPGSource, rhs: EPGSource) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Registry

enum EPGSourceRegistry {

    // swiftlint:disable force_unwrapping
    static let canadian = EPGSource(
        id: "ca2",
        displayName: "Canada EPG",
        url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_CA2.xml.gz")!,
        categoryIds: [
            "ca_broadcast_en", "ca_broadcast_fr",
            "ca_specialty_en", "ca_specialty_fr",
            "sports_ca", "news_ca", "premium_ca", "kids_ca"
        ],
        priority: 1,
        cacheTTL: 6 * 3600,
        isEnabled: true
    )

    static let usNational = EPGSource(
        id: "us2",
        displayName: "US National EPG",
        url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz")!,
        categoryIds: [
            "us_entertainment", "us_factual_lifestyle",
            "us_classic_specialty", "news_us", "news_international",
            "premium_us", "kids_us",
            "music_optional", "uk_optional",
            "international_optional", "fast_optional"
        ],
        priority: 2,
        cacheTTL: 6 * 3600,
        isEnabled: true
    )

    static let usLocals = EPGSource(
        id: "us_locals1",
        displayName: "US Local Affiliates EPG",
        url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US_LOCALS1.xml.gz")!,
        categoryIds: ["us_broadcast_major_markets"],
        priority: 3,
        cacheTTL: 6 * 3600,
        isEnabled: true
    )

    static let usSports = EPGSource(
        id: "us_sports1",
        displayName: "US Sports EPG",
        url: URL(string: "https://epgshare01.online/epgshare01/epg_ripper_US_SPORTS1.xml.gz")!,
        categoryIds: [
            "sports_us_national", "sports_us_regional",
            "sports_us_college_optional"
        ],
        priority: 1,
        cacheTTL: 4 * 3600,
        isEnabled: true
    )
    // swiftlint:enable force_unwrapping

    static let all: [EPGSource] = [canadian, usNational, usLocals, usSports]

    /// Returns only the sources relevant to the given category IDs.
    static func sources(for categoryIds: Set<String>) -> [EPGSource] {
        all.filter { source in
            source.isEnabled && !Set(source.categoryIds).isDisjoint(with: categoryIds)
        }.sorted { $0.priority < $1.priority }
    }
}
