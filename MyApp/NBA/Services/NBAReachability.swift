import Foundation

#if DEBUG
/// Manual, opt-in connectivity check — never runs automatically and is not on any
/// production code path. From the development machine, `cdn.nba.com/static/**`
/// returned an Akamai 403 and `stats.nba.com/stats/*` silently dropped the
/// connection, while `cdn.nba.com/logos/*` and `www.nba.com` were reachable —
/// consistent with datacenter-IP reputation filtering. This probe exists to get
/// a real answer from a residential/cellular network instead of guessing.
nonisolated enum NBAReachability {
    struct ProbeResult: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let status: String
    }

    static func probe() async -> [ProbeResult] {
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BannerTV/1.0"
        let targets: [(String, URL)] = [
            ("CDN scoreboard (data path)", URL(string: "https://cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json")!),
            ("CDN static schedule (data path)", URL(string: "https://cdn.nba.com/static/json/staticData/scheduleLeagueV2_1.json")!),
            ("CDN logos (control — non-data path)", URL(string: "https://cdn.nba.com/logos/nba/1610612747/primary/L/logo.svg")!),
            ("stats.nba.com standings", URL(string: "https://stats.nba.com/stats/leaguestandingsv3?LeagueID=00&Season=\(NBASeason.current())&SeasonType=Regular+Season&SeasonYear=")!)
        ]

        var results: [ProbeResult] = []
        for (label, url) in targets {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.nba.com/", forHTTPHeaderField: "Referer")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                results.append(ProbeResult(label: label, status: "HTTP \(code)"))
            } catch {
                results.append(ProbeResult(label: label, status: "Failed: \(error.localizedDescription)"))
            }
        }
        return results
    }
}
#endif
