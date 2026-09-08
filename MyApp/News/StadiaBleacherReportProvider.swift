import Foundation

// MARK: - Bleacher Report provider
// All known Bleacher Report legacy endpoints verified dead (HTTP 404) as of 2026-09-07:
//   GET https://bleacherreport.com/api/front/lead_articles.json       → 404
//   GET https://bleacherreport.com/api/article/article.json           → 404
//   GET https://bleacherreport.com/api/stream/first.json              → 404
// Provider is registered but permanently disabled until a live endpoint is confirmed.
// isBleacherReportNewsProviderEnabled defaults to false in AppConfiguration.

struct BleacherReportNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .bleacherReport,
            name: "Bleacher Report",
            supportLevel: .experimental,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            // Explicitly disabled: all legacy endpoints are 404.
            // Enable via AppConfiguration.isBleacherReportNewsProviderEnabled = true
            // only after a live endpoint and schema are confirmed.
            isEnabled: AppConfiguration.isBleacherReportNewsProviderEnabled,
            requestTimeout: 10
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] {
        // Guard at the top so even if someone flips the flag we have a documented
        // explanation of why this throws — not a programming error.
        guard metadata.isEnabled else {
            throw SportsDataError.providerDisabled(.bleacherReport)
        }
        // If somehow enabled in future, report as unavailable until a real endpoint
        // is confirmed and implemented here.
        throw SportsDataError.unavailable
    }
}
