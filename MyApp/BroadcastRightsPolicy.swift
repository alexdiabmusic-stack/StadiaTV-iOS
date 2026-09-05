import Foundation

// MARK: - Racing session kind

/// Session type within a multi-session motorsport event weekend.
/// Detected from the event name before matching so session-specific broadcaster lists apply.
nonisolated enum RacingSessionKind: String, Hashable, Sendable {
    case practice
    case qualifying
    case sprintQualifying  // F1 sprint shootout / sprint qualifying
    case sprint            // F1 sprint race
    case race
    case unknown

    static func detect(from text: String) -> RacingSessionKind {
        let lower = text.lowercased()
        if lower.contains("practice") || lower.contains(" fp1") || lower.contains(" fp2") || lower.contains(" fp3") {
            return .practice
        }
        if lower.contains("sprint qualifying") || lower.contains("sprint shootout") || lower.contains("shootout") {
            return .sprintQualifying
        }
        if lower.contains("sprint") { return .sprint }
        if lower.contains("qualifying") { return .qualifying }
        // "grand prix" without a session qualifier is the race
        if lower.contains("grand prix") || lower.hasSuffix(" race") || lower.contains(" race ") {
            return .race
        }
        return .unknown
    }
}

// MARK: - Rights broadcaster

/// A broadcast rights record: one or more channel name aliases with optional validity window
/// and optional country / session scope.
nonisolated struct RightsBroadcaster: Sendable {
    /// All names and aliases used to identify this broadcaster in IPTV stream metadata.
    let names: [String]
    /// ISO 3166-1 alpha-2 country codes this deal covers. Empty = worldwide / unspecified.
    let countries: [String]
    /// Rights not valid before this date. Nil = valid from the beginning of time.
    let validFrom: Date?
    /// Rights expired on or after this date. Nil = no known expiry (treat as current).
    let validUntil: Date?
    /// When set, this entry applies only to these racing session types. Nil = all sessions.
    let sessions: Set<RacingSessionKind>?

    init(
        _ names: [String],
        countries: [String] = [],
        from validFrom: Date? = nil,
        until validUntil: Date? = nil,
        sessions: Set<RacingSessionKind>? = nil
    ) {
        self.names = names
        self.countries = countries
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.sessions = sessions
    }
}

// MARK: - Policy

/// Broadcast rights policy for a single league, keyed by `League.path`.
nonisolated struct BroadcastRightsPolicy: Sendable {
    let leaguePath: String
    let broadcasters: [RightsBroadcaster]

    /// Returns all broadcaster alias names currently active.
    ///
    /// - Parameters:
    ///   - date: Evaluate validity at this date.
    ///   - session: Filter to session-specific entries. `.unknown` includes session-agnostic broadcasters.
    func activeBroadcasters(at date: Date = Date(), session: RacingSessionKind = .unknown) -> [String] {
        broadcasters
            .filter { b in
                if let from = b.validFrom, date < from { return false }
                if let until = b.validUntil, date >= until { return false }
                if let sessions = b.sessions {
                    return session == .unknown || sessions.contains(session)
                }
                return true
            }
            .flatMap(\.names)
    }
}

// MARK: - Store

/// Central registry of broadcast rights policies for all supported leagues.
/// Replaces the hardcoded broadcaster switch in SourceMatcher, adding date-validity and session filtering.
nonisolated struct BroadcastRightsStore: Sendable {
    static let shared = BroadcastRightsStore()

    private let policies: [String: BroadcastRightsPolicy]

    private init() {
        var p: [String: BroadcastRightsPolicy] = [:]
        for policy in Self.allPolicies { p[policy.leaguePath] = policy }
        policies = p
    }

    /// Returns active broadcaster aliases for a league, filtered by validity date and session type.
    func broadcasters(
        for leaguePath: String,
        at date: Date = Date(),
        session: RacingSessionKind = .unknown
    ) -> [String] {
        policies[leaguePath]?.activeBroadcasters(at: date, session: session) ?? []
    }

    // MARK: - Policy definitions

    // swiftlint:disable function_body_length
    private static let allPolicies: [BroadcastRightsPolicy] = [

        // ── Soccer ──────────────────────────────────────────────────────────────

        .init(leaguePath: "soccer/usa.1", broadcasters: [
            .init(["mls season pass", "season pass", "mls 360", "mls wrap up"]),
            .init(["tudn", "univision"]),
            .init(["tsn", "rds"], countries: ["CA"]),
            .init(["onesoccer", "one soccer"], countries: ["CA"]),
            // "apple tv" excluded: Apple TV+ SERIES numbered event slots are entertainment channels
            // and false-positive on this pattern.
        ]),

        .init(leaguePath: "soccer/eng.1", broadcasters: [
            .init(["sky sports", "sky sports premier league"]),
            .init(["tnt sports", "tntsports"]),
            // BT Sport rebranded to TNT Sports in July 2023; IPTV providers may still use the old name
            .init(["bt sport"], until: date("2024-01-01")),
            .init(["peacock", "nbc sports"], countries: ["US"]),
            .init(["optus sport"], countries: ["AU"]),
            .init(["hub premier", "premier sports"]),
            .init(["fubo"], countries: ["US", "CA"]),
        ]),

        .init(leaguePath: "soccer/eng.2", broadcasters: [
            .init(["sky sports"]),
            .init(["tnt sports", "tntsports"]),
            .init(["bt sport"], until: date("2024-01-01")),
            .init(["bein sport"]),
            .init(["espn"]),
        ]),

        .init(leaguePath: "soccer/eng.3", broadcasters: [
            .init(["sky sports"]),
            .init(["tnt sports", "tntsports"]),
            .init(["bein sport"]),
            .init(["espn"]),
        ]),

        .init(leaguePath: "soccer/eng.4", broadcasters: [
            .init(["sky sports"]),
            .init(["tnt sports", "tntsports"]),
            .init(["bein sport"]),
            .init(["espn"]),
        ]),

        .init(leaguePath: "soccer/eng.fa_cup", broadcasters: [
            .init(["bbc"]),
            .init(["itv"]),
            .init(["tnt sports", "tntsports"]),
            .init(["bt sport"], until: date("2024-01-01")),
            .init(["espn"]),
        ]),

        .init(leaguePath: "soccer/uefa.champions", broadcasters: [
            .init(["cbs sports", "cbs", "paramount"], countries: ["US"]),
            .init(["tnt sports", "tntsports"]),
            .init(["dazn"]),
            .init(["canal plus"]),
            .init(["sky sport"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "soccer/uefa.europa", broadcasters: [
            .init(["cbs sports", "cbs", "paramount"], countries: ["US"]),
            .init(["tnt sports", "tntsports"]),
            .init(["dazn"]),
            .init(["canal plus"]),
            .init(["sky sport"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "soccer/esp.1", broadcasters: [
            .init(["dazn"]),
            .init(["espn", "abc"], countries: ["US"]),
            .init(["sky sports"], countries: ["GB"]),
            .init(["bein sport"]),
            .init(["movistar", "m sport", "laliga tv", "la liga tv"], countries: ["ES"]),
            .init(["tsn", "rds"], countries: ["CA"]),
        ]),

        .init(leaguePath: "soccer/ita.1", broadcasters: [
            .init(["dazn"]),
            .init(["sky sport serie a", "sky sport"], countries: ["IT"]),
            .init(["espn", "peacock", "paramount", "cbs sports", "fubo"], countries: ["US"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "soccer/ger.1", broadcasters: [
            .init(["sky sport bundesliga", "sky sport"], countries: ["DE"]),
            .init(["dazn"]),
            .init(["espn", "bein sport"]),
            .init(["sport1"], countries: ["DE"]),
            .init(["rtl"], countries: ["DE"]),
            .init(["onesoccer", "one soccer"], countries: ["CA"]),
            .init(["telemundo"], countries: ["US"]),
        ]),

        .init(leaguePath: "soccer/fra.1", broadcasters: [
            .init(["canal plus"], countries: ["FR"]),
            .init(["dazn"]),
            .init(["bein sport"]),
            .init(["amazon prime", "prime video"]),
            .init(["ligue 1", "ligue1"]),
        ]),

        .init(leaguePath: "soccer/ned.1", broadcasters: [
            .init(["espn", "espn nl", "espn netherlands", "espn eredivisie"], countries: ["NL"]),
            .init(["viaplay"]),
            .init(["ziggo sport"], countries: ["NL"]),
            .init(["dazn"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "soccer/por.1", broadcasters: [
            .init(["sport tv", "btv", "benfica tv"], countries: ["PT"]),
            .init(["eleven sports"]),
            .init(["dazn"]),
        ]),

        .init(leaguePath: "soccer/sco.1", broadcasters: [
            .init(["sky sports"]),
            .init(["premier sports"]),
            .init(["bein sport"]),
            .init(["espn"]),
        ]),

        .init(leaguePath: "soccer/bel.1", broadcasters: [
            .init(["dazn"]),
            .init(["bein sport"]),
            .init(["eleven sports"]),
            .init(["proximus sports"], countries: ["BE"]),
        ]),

        .init(leaguePath: "soccer/tur.1", broadcasters: [
            .init(["bein sport", "bein sports", "beinsports"]),
            .init(["s sport", "ssport"], countries: ["TR"]),
        ]),

        .init(leaguePath: "soccer/gre.1", broadcasters: [
            .init(["cosmote sport", "cosmote"], countries: ["GR"]),
            .init(["novasports", "nova sport"], countries: ["GR"]),
            .init(["ert sports"], countries: ["GR"]),
        ]),

        .init(leaguePath: "soccer/aut.1", broadcasters: [
            .init(["sky sport austria", "sky sport"], countries: ["AT"]),
            .init(["puls 4", "puls4"], countries: ["AT"]),
        ]),

        .init(leaguePath: "soccer/sui.1", broadcasters: [
            .init(["blue sport", "bluesport"], countries: ["CH"]),
            .init(["rsi", "srf", "rts"], countries: ["CH"]),
            .init(["mysports"], countries: ["CH"]),
        ]),

        .init(leaguePath: "soccer/den.1", broadcasters: [
            .init(["tv2 sport", "tv 2 sport"], countries: ["DK"]),
            .init(["discovery plus", "discovery+"]),
            .init(["viaplay"]),
        ]),

        .init(leaguePath: "soccer/swe.1", broadcasters: [
            .init(["tv4 sport", "tv4"], countries: ["SE"]),
            .init(["telia", "viaplay", "c more"], countries: ["SE"]),
        ]),

        .init(leaguePath: "soccer/pol.1", broadcasters: [
            .init(["canal plus"], countries: ["PL"]),
            .init(["polsat sport"], countries: ["PL"]),
            .init(["tvp sport"], countries: ["PL"]),
        ]),

        .init(leaguePath: "soccer/nor.1", broadcasters: [
            .init(["tv2 sport", "tv 2 sport"], countries: ["NO"]),
            .init(["viaplay"]),
            .init(["max sport"]),
        ]),

        .init(leaguePath: "soccer/rom.1", broadcasters: [
            .init(["digi sport"], countries: ["RO"]),
            .init(["prima sport", "primasport"], countries: ["RO"]),
            .init(["orange sport"], countries: ["RO"]),
        ]),

        .init(leaguePath: "soccer/ksa.1", broadcasters: [
            .init(["ssc"], countries: ["SA"]),
            .init(["thmanyah"], countries: ["SA"]),
            .init(["bein sport", "bein sports", "beinsports"]),
        ]),

        .init(leaguePath: "soccer/qat.1", broadcasters: [
            .init(["al kass", "alkass"], countries: ["QA"]),
            .init(["bein sport"]),
            .init(["qatar tv"], countries: ["QA"]),
        ]),

        .init(leaguePath: "soccer/jpn.1", broadcasters: [
            .init(["dazn"], countries: ["JP"]),
            .init(["nhk", "fuji tv", "j sports"], countries: ["JP"]),
        ]),

        .init(leaguePath: "soccer/kor.1", broadcasters: [
            .init(["coupang", "coupang play"], countries: ["KR"]),
            .init(["spotv", "jtbc"], countries: ["KR"]),
        ]),

        .init(leaguePath: "soccer/kor.2", broadcasters: [
            .init(["coupang", "coupang play"], countries: ["KR"]),
            .init(["spotv"], countries: ["KR"]),
        ]),

        .init(leaguePath: "soccer/aus.1", broadcasters: [
            .init(["paramount plus", "paramount+", "10 play", "ten play", "paramount"], countries: ["AU"]),
        ]),

        .init(leaguePath: "soccer/aus.nwsl", broadcasters: [
            .init(["paramount plus", "paramount+", "10 play", "ten play", "paramount"], countries: ["AU"]),
        ]),

        .init(leaguePath: "soccer/rsa.1", broadcasters: [
            .init(["supersport", "super sport"], countries: ["ZA"]),
            .init(["canal plus", "dstv"]),
        ]),

        .init(leaguePath: "soccer/can.1", broadcasters: [
            .init(["onesoccer", "one soccer"], countries: ["CA"]),
            .init(["cbcsports", "cbc sports"], countries: ["CA"]),
        ]),

        .init(leaguePath: "soccer/mex.1", broadcasters: [
            .init(["canal 5", "tudn", "las estrellas", "azteca", "azteca 7"], countries: ["MX"]),
            .init(["fox sports", "fox deportes"]),
            .init(["prime video", "amazon prime"]),
            .init(["tdn", "claro sports", "claro video"]),
        ]),

        .init(leaguePath: "soccer/bra.1", broadcasters: [
            .init(["premiere", "globo", "sportv", "spor tv"], countries: ["BR"]),
            .init(["amazon prime", "prime video"]),
            .init(["record", "cazé tv", "caze tv", "cazetv", "ge tv", "getv"], countries: ["BR"]),
        ]),

        .init(leaguePath: "soccer/bra.2", broadcasters: [
            .init(["premiere", "globo", "sportv", "spor tv"], countries: ["BR"]),
            .init(["amazon prime", "prime video"]),
        ]),

        .init(leaguePath: "soccer/arg.1", broadcasters: [
            .init(["tnt sports", "tntsports"], countries: ["AR"]),
            .init(["espn"]),
            .init(["directv sports", "dsports"], countries: ["AR"]),
        ]),

        .init(leaguePath: "soccer/col.1", broadcasters: [
            .init(["win sports", "winsports"], countries: ["CO"]),
            .init(["espn"]),
            .init(["rcn", "caracol"], countries: ["CO"]),
        ]),

        .init(leaguePath: "soccer/chi.1", broadcasters: [
            .init(["tnt sports", "tntsports"], countries: ["CL"]),
            .init(["canal 13", "chilevisión", "chilevision"], countries: ["CL"]),
        ]),

        .init(leaguePath: "soccer/per.1", broadcasters: [
            .init(["l1 max", "l1max", "liga 1 max"], countries: ["PE"]),
            .init(["america tv", "gol peru"], countries: ["PE"]),
        ]),

        .init(leaguePath: "soccer/ecu.1", broadcasters: [
            .init(["zapping"], countries: ["EC"]),
            .init(["gol tv", "tc sports", "tcs"], countries: ["EC"]),
        ]),

        .init(leaguePath: "soccer/mor.1", broadcasters: [
            .init(["arryadia", "2m", "snrt"], countries: ["MA"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "soccer/concacaf.champions", broadcasters: [
            .init(["onesoccer", "one soccer"], countries: ["CA"]),
            .init(["fox sports", "fox deportes", "tudn"]),
            .init(["televisa"], countries: ["MX"]),
            .init(["cbs sports", "paramount"]),
        ]),

        .init(leaguePath: "soccer/fifa.world", broadcasters: [
            .init(["fox", "fs1"]),
            .init(["telemundo", "peacock"], countries: ["US"]),
            .init(["tnt sports"]),
            .init(["bbc", "itv"], countries: ["GB"]),
            .init(["bein sport"]),
            .init(["fifa wc"]),
        ]),

        .init(leaguePath: "soccer/fifa.wwc", broadcasters: [
            .init(["fox", "fs1"]),
            .init(["telemundo", "peacock"], countries: ["US"]),
            .init(["tnt sports"]),
            .init(["bbc", "itv"], countries: ["GB"]),
            .init(["bein sport"]),
        ]),

        // ── Football ────────────────────────────────────────────────────────────

        .init(leaguePath: "football/nfl", broadcasters: [
            .init(["cbs", "fox", "nbc", "abc", "espn"], countries: ["US"]),
            .init(["nfl network"]),
            .init(["prime", "amazon"], countries: ["US"]),
            .init(["peacock", "paramount"], countries: ["US"]),
            .init(["dazn nfl"], countries: ["CA", "DE", "AT", "CH", "IT", "ES", "FR", "JP", "MX"]),
        ]),

        // ── Hockey ───────────────────────────────────────────────────────────────

        .init(leaguePath: "hockey/nhl", broadcasters: [
            .init(["espn", "abc", "tnt", "tbs"], countries: ["US"]),
            .init(["sportsnet", "tsn", "rds", "tva sports"], countries: ["CA"]),
            .init(["nhl network", "nhln"]),
            .init(["peacock"], countries: ["US"]),
            // NBC Sports shut down January 1, 2024; rights moved to ESPN/TNT/Peacock
            .init(["nbcsn", "nbc sports"], until: date("2024-01-01")),
        ]),

        // ── Basketball ──────────────────────────────────────────────────────────

        .init(leaguePath: "basketball/nba", broadcasters: [
            .init(["abc", "espn"], countries: ["US"]),
            // Turner deal expired after 2024–25; NBC/Universal + Amazon started 2025–26
            .init(["tnt", "tbs"], countries: ["US"], until: date("2025-10-01")),
            .init(["nbc", "peacock"], countries: ["US"], from: date("2025-10-01")),
            .init(["prime", "amazon"], countries: ["US"], from: date("2025-10-01")),
            .init(["nba tv", "nbatv"]),
            .init(["dazn nba"]),
            .init(["bein sports"]),
        ]),

        // ── Baseball ─────────────────────────────────────────────────────────────

        .init(leaguePath: "baseball/mlb", broadcasters: [
            .init(["fox", "fs1", "espn"], countries: ["US"]),
            .init(["apple tv", "apple"]),
            .init(["peacock"], countries: ["US"]),
            .init(["mlb network", "mlbn"]),
            .init(["tbs"], countries: ["US"]),
        ]),

        // ── Racing ───────────────────────────────────────────────────────────────

        .init(leaguePath: "racing/f1", broadcasters: [
            // Sky Sports F1 and F1 TV Pro broadcast all sessions globally
            .init(["sky sport f1", "sky sports f1", "sky f1"]),
            .init(["dazn f1"], countries: ["ES", "IT", "DE", "AT", "CH", "JP"]),
            .init(["f1tv", "f1 tv", "formula 1 tv", "alwan f1", "f1 tv pro"]),
            // ESPN had US rights through 2025; Apple TV+ exclusive in US from 2026
            .init(["espn f1", "espn"], until: date("2026-01-01"), sessions: [.qualifying, .sprintQualifying, .sprint, .race]),
            // Apple TV+ carries all F1 sessions in the US exclusively from the 2026 season
            .init(["apple tv", "apple tv plus", "apple"], countries: ["US"], from: date("2026-01-01")),
            // TSN carries F1 in Canada
            .init(["tsn"], countries: ["CA"]),
            // Channel 4 UK: free-to-air qualifying highlights and select races
            .init(["channel 4"], countries: ["GB"], sessions: [.qualifying, .race]),
        ]),

        .init(leaguePath: "racing/nascar-premier", broadcasters: [
            .init(["fox", "fs1"], countries: ["US"]),
            .init(["nbc", "usa network"], countries: ["US"]),
            .init(["tntsports", "tnt sports"], countries: ["US"]),
            .init(["peacock"], countries: ["US"]),
            // NBC Sports shut down January 1, 2024
            .init(["nbcsn"], until: date("2024-01-01")),
        ]),

        .init(leaguePath: "racing/nascar-truck", broadcasters: [
            .init(["fox", "fs1", "fs2"], countries: ["US"]),
            .init(["nbc", "usa network"], countries: ["US"]),
            .init(["peacock"], countries: ["US"]),
        ]),

        .init(leaguePath: "racing/irl", broadcasters: [
            .init(["fox", "fox sports", "fs1", "fs2"], countries: ["US"]),
            .init(["indycar", "indy car", "ntt indycar"]),
            .init(["peacock", "nbc"], countries: ["US"]),
            // NBC Sports shut down January 1, 2024
            .init(["nbc sports"], until: date("2024-01-01")),
            .init(["sky sports f1", "dazn"]),
        ]),

        // ── Golf ─────────────────────────────────────────────────────────────────

        .init(leaguePath: "golf/pga", broadcasters: [
            .init(["golf channel"]),
            .init(["pga tour"]),
            .init(["cbs", "nbc", "peacock"], countries: ["US"]),
            .init(["sky sports golf", "sky sport golf"]),
            .init(["bbc sport"], countries: ["GB"]),
        ]),

        .init(leaguePath: "golf/lpga", broadcasters: [
            .init(["golf channel"]),
            .init(["cbs", "nbc", "peacock"], countries: ["US"]),
            .init(["sky sports golf", "sky sport golf"]),
        ]),

        .init(leaguePath: "golf/champions-tour", broadcasters: [
            .init(["golf channel"]),
            .init(["cbs"], countries: ["US"]),
        ]),

        .init(leaguePath: "golf/eur", broadcasters: [
            .init(["sky sports golf", "sky sport golf"]),
            .init(["eurosport"]),
            .init(["golf channel"]),
        ]),

        // ── Tennis ───────────────────────────────────────────────────────────────

        .init(leaguePath: "tennis/atp", broadcasters: [
            .init(["tennis channel"]),
            .init(["espn", "espn2"], countries: ["US"]),
            .init(["bein sport", "bein sports"]),
            .init(["eurosport"]),
            .init(["amazon prime", "prime video"]),
            .init(["sky sports", "sky sport"]),
            .init(["wowow"], countries: ["JP"]),
            .init(["supertennis"], countries: ["IT"]),
        ]),

        .init(leaguePath: "tennis/wta", broadcasters: [
            .init(["tennis channel"]),
            .init(["espn", "espn2"], countries: ["US"]),
            .init(["bein sport", "bein sports"]),
            .init(["eurosport"]),
            .init(["sky sports", "sky sport"]),
        ]),

        // ── MMA / Combat ─────────────────────────────────────────────────────────

        .init(leaguePath: "fighting/ufc", broadcasters: [
            .init(["espn", "espn+", "espn plus", "abc"], countries: ["US"]),
            .init(["tnt sports", "tntsports"], countries: ["GB"]),
            .init(["bt sport"], countries: ["GB"], until: date("2024-01-01")),
            .init(["bein sport", "bein sports"]),
            .init(["ufc fight pass", "ufc"]),
        ]),

        .init(leaguePath: "fighting/boxing", broadcasters: [
            .init(["dazn"]),
            .init(["sky sports box office", "sky sports boxing", "sky box office"], countries: ["GB"]),
            .init(["espn", "espn+"], countries: ["US"]),
            .init(["amazon prime", "prime video"]),
            .init(["showtime", "paramount"], countries: ["US"]),
            .init(["fightbox", "fight network", "fight sports"]),
        ]),

        // ── Rugby ─────────────────────────────────────────────────────────────────

        .init(leaguePath: "rugby/six-nations", broadcasters: [
            .init(["bbc", "itv"], countries: ["GB", "IE"]),
            .init(["s4c"], countries: ["GB"]),
            .init(["france tv", "france televisions", "france 2", "france 3"], countries: ["FR"]),
            .init(["rai sport", "rai"], countries: ["IT"]),
            .init(["rtve"], countries: ["ES"]),
            .init(["rte"], countries: ["IE"]),
            .init(["sky sports"]),
            .init(["bein sport"]),
        ]),

        .init(leaguePath: "rugby/world-cup", broadcasters: [
            .init(["itv", "bbc"], countries: ["GB"]),
            .init(["france tv", "tf1", "france 2"], countries: ["FR"]),
            .init(["sky sports"]),
            .init(["espn"], countries: ["US"]),
            .init(["bein sport"]),
            .init(["sky sport nz", "tvnz"], countries: ["NZ"]),
            .init(["ch9", "foxtel", "stan sport"], countries: ["AU"]),
        ]),

        .init(leaguePath: "rugby/premiership", broadcasters: [
            .init(["sky sports"]),
            .init(["tnt sports", "tntsports"]),
            .init(["bt sport"], until: date("2024-01-01")),
            .init(["premier sports"]),
        ]),

        .init(leaguePath: "rugby/pro14", broadcasters: [
            .init(["sky sports"]),
            .init(["premier sports"]),
            .init(["s4c"], countries: ["GB"]),
            .init(["eir sport"], countries: ["IE"]),
        ]),

        .init(leaguePath: "rugby/top14", broadcasters: [
            .init(["canal plus", "canal sport"], countries: ["FR"]),
            .init(["sky sports"]),
        ]),

        .init(leaguePath: "rugby/super-rugby", broadcasters: [
            .init(["sky sport nz", "sky nz"], countries: ["NZ"]),
            .init(["foxtel", "kayo sports", "stan sport"], countries: ["AU"]),
            .init(["sky sports"]),
        ]),

        .init(leaguePath: "rugby-league/super-league", broadcasters: [
            .init(["sky sports"]),
            .init(["premier sports"]),
            .init(["bbc"], countries: ["GB"]),
        ]),

        .init(leaguePath: "rugby-league/nrl", broadcasters: [
            .init(["foxtel", "kayo sports", "nine"], countries: ["AU"]),
            .init(["sky sports"]),
        ]),

        // ── Cricket ───────────────────────────────────────────────────────────────

        .init(leaguePath: "cricket/test-championship", broadcasters: [
            .init(["sky sports cricket", "sky sports"]),
            .init(["star sports", "star cricket"], countries: ["IN", "PK", "BD"]),
            .init(["sony sports", "sony six"], countries: ["IN"]),
            .init(["ch7", "fox sports", "foxtel"], countries: ["AU"]),
            .init(["sky sport nz"], countries: ["NZ"]),
            .init(["supersport"], countries: ["ZA"]),
            .init(["willow"], countries: ["US", "CA"]),
        ]),

        .init(leaguePath: "cricket/ashes", broadcasters: [
            .init(["sky sports cricket", "sky sports"]),
            .init(["ch7", "fox sports", "foxtel", "kayo sports"], countries: ["AU"]),
            .init(["willow"], countries: ["US", "CA"]),
            .init(["star sports"], countries: ["IN"]),
        ]),

        .init(leaguePath: "cricket/icc-world-cup", broadcasters: [
            .init(["star sports", "hotstar"], countries: ["IN"]),
            .init(["sky sports cricket", "sky sports"]),
            .init(["ch7", "fox sports", "foxtel"], countries: ["AU"]),
            .init(["sky sport nz"], countries: ["NZ"]),
            .init(["willow"], countries: ["US", "CA"]),
            .init(["supersport"], countries: ["ZA"]),
            .init(["ten sports", "ptv sports"], countries: ["PK"]),
        ]),

        .init(leaguePath: "cricket/ipl", broadcasters: [
            .init(["star sports", "hotstar", "jiocinema", "jio cinema"], countries: ["IN"]),
            .init(["sky sports"]),
            .init(["willow"], countries: ["US", "CA"]),
            .init(["foxtel", "kayo sports"], countries: ["AU"]),
        ]),

        // ── Aussie Rules ──────────────────────────────────────────────────────────

        .init(leaguePath: "aussie-football/afl", broadcasters: [
            .init(["foxtel", "fox footy", "kayo sports"], countries: ["AU"]),
            .init(["ch7", "7 plus", "7mate", "seven"], countries: ["AU"]),
            .init(["ch9", "nine"], countries: ["AU"]),
            .init(["abc", "abc iview"], countries: ["AU"]),
        ]),

        // ── Tour de France (not in ESPN league catalog; matched by event title) ──
        // Access via BroadcastRightsStore.shared.broadcasters(for: "cycling/tour-de-france")
        .init(leaguePath: "cycling/tour-de-france", broadcasters: [
            // France: France Télévisions (trailing space on "france 2 " / "france 3 " avoids
            // matching "france 24", which is a news channel).
            .init(["france 2 ", "france 3 ", "france televisions", "france tv sport"], countries: ["FR"]),
            .init(["eurosport", "eurosport extra"]),
            .init(["ard"], countries: ["DE"]),
            .init(["servus tv", "servus"], countries: ["AT", "DE"]),
            .init(["rtbf"], countries: ["BE"]),
            .init(["vrt"], countries: ["BE"]),
            .init(["czech tv", "ct sport"], countries: ["CZ"]),
            .init(["tv2 norway", "tv2"], countries: ["NO"]),
            .init(["rtve"], countries: ["ES"]),
            .init(["tg4"], countries: ["IE"]),
            .init(["rai sports", "rai sport", "rai"], countries: ["IT"]),
            .init(["rtl"], countries: ["LU", "NL", "DE"]),
            .init(["nos"], countries: ["NL"]),
            .init(["tnt sports"]),
            .init(["eitb"], countries: ["ES"]),
            .init(["rtp"], countries: ["PT"]),
            .init(["stvr", "rtv slovenija", "rtv slo"], countries: ["SI"]),
            .init(["srg ssr"], countries: ["CH"]),
            .init(["mtva"], countries: ["HU"]),
            .init(["okko"], countries: ["RU"]),
            .init(["s4c"], countries: ["GB"]),
            .init(["abu dhabi sports"], countries: ["AE"]),
            .init(["supersport"], countries: ["ZA"]),
            .init(["bein sport asia", "bein sports asia", "bein sport"]),
            .init(["zhubo tv", "cctv"], countries: ["CN"]),
            .init(["j sports", "wowow"], countries: ["JP"]),
            .init(["elta"], countries: ["GR"]),
            .init(["coupang", "sbs"], countries: ["KR"]),
            .init(["sky sport"]),
            .init(["espn", "flosports", "peacock"], countries: ["US"]),
            // NBC Sports shut down January 1, 2024
            .init(["nbc sports"], until: date("2024-01-01")),
            .init(["caracol tv", "caracol", "canal rcn", "rcn"], countries: ["CO"]),
            .init(["tv5monde"]),
        ]),
    ]
    // swiftlint:enable function_body_length

    // MARK: - Date helper

    private static func date(_ iso: String) -> Date? {
        let cal = ISO8601DateFormatter()
        cal.formatOptions = [.withFullDate]
        cal.timeZone = TimeZone(identifier: "UTC")
        return cal.date(from: iso)
    }
}
