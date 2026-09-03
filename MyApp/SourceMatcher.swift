import Foundation

/// Ranks playlist channels by how likely they are to be carrying a given match.
///
/// The score combines several signals:
///  - an event-specific channel mentioning both teams or the event title is the strongest hit
///  - each team name / abbreviation match
///  - the ESPN broadcast network (e.g. "ESPN", "TNT") appearing in the channel name
///  - league / sport keywords
///  - a small bonus for channels sitting in a "sports" group
nonisolated enum SourceMatcher {

    /// Words that carry no discriminating value when matching team/channel names.
    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "the", "of", "and", "de", "du", "le", "la", "les",
        "city", "united", "club", "hd", "sd", "fhd", "uhd", "4k", "tv", "channel", "live", "sports", "sport",
        "featured", "coverage", "session", "players", "tbd", "early", "weekday", "day", "night", "round", "rounds"
    ]

    static func rank(match: Match, channels: [Channel], preferredLanguages: Set<String> = []) -> [RankedSource] {
        let homeTokens = teamTokens(for: match.home, league: match.league)
        let awayTokens = teamTokens(for: match.away, league: match.league)
        let homeAliases = teamAliases(for: match.home, league: match.league).map { normalize($0) }
        let awayAliases = teamAliases(for: match.away, league: match.league).map { normalize($0) }
        let eventTokens = eventTokens(from: match)
        let homeAbbr = match.home.abbreviation.lowercased()
        let awayAbbr = match.away.abbreviation.lowercased()
        let broadcasts = match.broadcasts.map { normalize($0) }
        let eventSpecificBroadcasters = eventBroadcasterAliases(for: match).map { normalize($0) }
        let leagueKeywords = (match.league.keywords + eventAliases(for: match)).map { normalize($0) }
        let leagueShort = normalize(match.league.shortName)

        var ranked: [RankedSource] = []

        for channel in channels {
            let haystack = normalize([channel.name, channel.group ?? "", channel.playlistName].joined(separator: " "))
            let haystackTokens = Set(haystack.split(separator: " ").map(String.init))
            var score = 0

            let homeHit = matches(homeTokens, in: haystack, tokens: haystackTokens) || aliasMatches(homeAliases, in: haystack, tokens: haystackTokens)
            let awayHit = matches(awayTokens, in: haystack, tokens: haystackTokens) || aliasMatches(awayAliases, in: haystack, tokens: haystackTokens)

            // Both teams named -> almost certainly the event feed.
            if homeHit && awayHit { score += 100 }
            else if homeHit || awayHit { score += 40 }

            // Event-title feeds matter for non-team sports and special broadcasts
            // such as Tour de France stages.
            if eventTitleMatches(eventTokens, in: haystack, tokens: haystackTokens) {
                score += 80
            }

            // Abbreviation matches (whole-token only, 3-char minimum to prevent
            // 2-char country-code prefixes like "US ★" or "DE ★" from scoring
            // against national team abbreviations like "US" or "DE").
            if homeAbbr.count >= 3, haystackTokens.contains(homeAbbr) { score += 15 }
            if awayAbbr.count >= 3, haystackTokens.contains(awayAbbr) { score += 15 }

            // Broadcast network on the channel name.
            for network in broadcasts where !network.isEmpty {
                if haystack.contains(network) { score += 35 }
            }

            // Known event-specific rights holders, used when ESPN's broadcast
            // payload is sparse for events such as Tour de France stages.
            if eventBroadcasterMatches(eventSpecificBroadcasters, in: haystack, tokens: haystackTokens) {
                score += 70
            }

            // League keywords.
            for keyword in leagueKeywords where haystack.contains(keyword) {
                score += 12
            }
            // Dedicated league-branded channel bonus: channels like "NHL GAME 07",
            // "DAZN NBA 1", or "SKY SPORT F1" contain the league's short name as a
            // whole word and deserve a bigger boost than a generic keyword substring hit.
            if haystackTokens.contains(leagueShort) {
                score += 30
            } else if !leagueShort.isEmpty && haystack.contains(leagueShort) {
                score += 12
            }

            // Sports group / generic sports network bonus.
            if let group = channel.group?.lowercased(),
               group.contains("sport") || group.contains(match.league.group.rawValue.lowercased()) {
                score += 6
            }
            if isKnownSportsNetwork(haystack) { score += 5 }

            // Language preference: boost streams tagged with a preferred
            // language (e.g. "EN:" means an English stream), deprioritize
            // streams tagged with a different one. Untagged streams stay neutral.
            if !preferredLanguages.isEmpty {
                let tags = languageTags(in: channel.name)
                if !tags.isEmpty {
                    score += tags.isDisjoint(with: preferredLanguages) ? -25 : 25
                }
            }

            if score >= minimumScore(for: match) {
                ranked.append(RankedSource(channel: channel, score: score))
            }
        }

        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.channel.name.localizedCaseInsensitiveCompare($1.channel.name) == .orderedAscending
        }
    }

    /// Language tags detected on a channel name, from whole-word tokens such as
    /// "EN:", "[ES]" or "English". `normalize` would strip the leading country/
    /// language prefix, so this scans the name with the prefix kept.
    static func languageTags(in channelName: String) -> Set<String> {
        let cleaned = channelName
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        let tokens = Set(String(cleaned).split(separator: " ").map(String.init))

        var tags: Set<String> = []
        for language in StreamLanguage.all {
            if tokens.contains(language.code) || language.aliases.contains(where: tokens.contains) {
                tags.insert(language.code)
            }
        }
        return tags
    }

    // MARK: - Helpers

    private static func matches(_ needleTokens: [String], in haystack: String, tokens haystackTokens: Set<String>) -> Bool {
        guard !needleTokens.isEmpty else { return false }
        // A team matches if any of its significant tokens appears as a whole word.
        for token in needleTokens where token.count >= 3 {
            if haystackTokens.contains(token) { return true }
            // City/nickname often appears joined, allow substring for longer tokens.
            if token.count >= 5 && haystack.contains(token) { return true }
        }
        return false
    }

    private static func eventTitleMatches(_ eventTokens: [String], in haystack: String, tokens haystackTokens: Set<String>) -> Bool {
        guard !eventTokens.isEmpty else { return false }
        let phrase = eventTokens.joined(separator: " ")
        if eventTokens.count >= 2, haystack.contains(phrase) { return true }

        let matchedTokenCount = eventTokens.reduce(0) { count, token in
            count + (haystackTokens.contains(token) ? 1 : 0)
        }
        return eventTokens.count == 1 ? matchedTokenCount == 1 : matchedTokenCount >= 2
    }

    private static func minimumScore(for match: Match) -> Int {
        switch match.league.group {
        case .soccer, .racing, .golf, .tennis:
            return 20
        default:
            return 12
        }
    }

    private static func eventBroadcasterMatches(_ aliases: [String], in haystack: String, tokens haystackTokens: Set<String>) -> Bool {
        aliasMatches(aliases, in: haystack, tokens: haystackTokens)
    }

    private static func aliasMatches(_ aliases: [String], in haystack: String, tokens haystackTokens: Set<String>) -> Bool {
        aliases.contains { alias in
            guard !alias.isEmpty else { return false }
            if alias.contains(" ") { return haystack.contains(alias) }
            return haystackTokens.contains(alias)
        }
    }

    private static func teamTokens(for team: TeamSide, league: League) -> [String] {
        let names = [team.displayName, team.shortName, team.abbreviation]
        var seen: Set<String> = []
        return names.flatMap(tokens(from:))
            .filter { token in
                if league.group == .soccer {
                    return true
                }
                return !soccerClubWords.contains(token)
            }
            .filter { seen.insert($0).inserted }
    }

    private static func teamAliases(for team: TeamSide, league: League) -> [String] {
        var aliases = [team.displayName, team.shortName, team.abbreviation]
        guard league.path == "soccer/usa.1" || league.path == "soccer/usa.nwsl" else { return aliases }

        let normalizedNames = Set(aliases.map(normalize))
        for (key, values) in mlsTeamAliases {
            let normalizedValues = values.map(normalize)
            if normalizedNames.contains(key) || !normalizedNames.isDisjoint(with: normalizedValues) {
                aliases.append(contentsOf: values)
            }
        }
        return aliases
    }

    private static func tokens(from name: String) -> [String] {
        normalize(name)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    private static func eventTokens(from match: Match) -> [String] {
        var seen: Set<String> = []
        return tokens(from: "\(match.name) \(match.shortName)")
            .filter { $0.count >= 3 }
            .filter { seen.insert($0).inserted }
    }

    private static func eventAliases(for match: Match) -> [String] {
        let title = normalize("\(match.name) \(match.shortName) \(match.league.name)")
        var aliases: [String] = []
        if isTourDeFrance(title) {
            aliases += ["tour de france", "le tour", "tdf", "cycling", "cyclisme", "velo"]
        }
        if match.league.group == .tennis {
            aliases += ["tennis", "atp", "wta", "grand slam", "wimbledon", "us open", "french open", "roland garros", "australian open"]
        }
        return aliases
    }

    private static func eventBroadcasterAliases(for match: Match) -> [String] {
        let title = normalize("\(match.name) \(match.shortName) \(match.league.name)")

        switch match.league.path {

        // ── Soccer ──────────────────────────────────────────────────────────
        case "soccer/usa.1":
            // "apple tv" and "apple" are intentionally excluded: Apple TV+ SERIES numbered
            // slots are entertainment channels and would false-positive here.
            // "fox"/"fs1"/"fs2" are covered by the broadcasts[] array from ESPN data.
            return [
                "mls season pass", "season pass", "mls 360", "mls wrap up",
                "tudn", "univision", "tsn", "rds", "one soccer", "onesoccer"
            ]
        case "soccer/eng.1":
            // UK: Sky Sports, TNT Sports. Canada: Fubo. USA: NBC Sports/Peacock.
            return [
                "sky sports", "sky sports premier league", "tnt sports", "tntsports",
                "bt sport", "peacock", "nbc sports", "nbcsn", "optus sport",
                "hub premier", "premier sports", "fubo"
            ]
        case "soccer/eng.2", "soccer/eng.3", "soccer/eng.4":
            // EFL Championship / League One / Two: Sky Sports, TNT Sports in UK; beIN internationally
            return [
                "sky sports", "tnt sports", "tntsports", "bein sport", "espn"
            ]
        case "soccer/eng.fa_cup":
            return ["bbc", "itv", "tnt sports", "tntsports", "bt sport", "espn"]
        case "soccer/uefa.champions", "soccer/uefa.europa":
            return [
                "cbs sports", "cbs", "paramount", "tnt sports", "tntsports",
                "dazn", "canal plus", "sky sport", "bein sport"
            ]
        case "soccer/esp.1":
            // Spain: DAZN. USA: ESPN. Canada: TSN/RDS. International: beIN Sports.
            return [
                "dazn", "espn", "abc", "sky sports", "bein sport",
                "movistar", "m sport", "laliga tv", "la liga tv",
                "tsn", "rds"
            ]
        case "soccer/ita.1":
            // Italy: DAZN, Sky. USA: CBS/Paramount+. Canada: Fubo.
            return [
                "dazn", "sky sport serie a", "sky sport", "espn",
                "peacock", "bein sport", "paramount", "cbs sports", "fubo"
            ]
        case "soccer/ger.1":
            // Germany: Sky, DAZN, RTL. Canada: OneSoccer/DAZN. USA: USA Sports/Telemundo.
            return [
                "sky sport bundesliga", "sky sport", "dazn", "espn", "bein sport", "sport1",
                "rtl", "onesoccer", "one soccer", "telemundo"
            ]
        case "soccer/fra.1":
            // France: Ligue 1+, Canal+, DAZN, beIN Sports.
            return [
                "canal plus", "dazn", "bein sport", "amazon prime", "prime video",
                "ligue 1", "ligue1"
            ]
        case "soccer/ned.1":
            // Netherlands: ESPN. International: Viaplay, beIN Sports.
            return [
                "viaplay", "ziggo sport", "espn", "espn nl", "espn netherlands",
                "espn eredivisie", "dazn", "bein sport"
            ]
        case "soccer/por.1":
            // Portugal: SPORT TV, BTV (Benfica home), Eleven Sports.
            return ["sport tv", "benfica tv", "eleven sports", "dazn", "btv"]
        case "soccer/sco.1":
            // Scottish Premiership: Sky Sports UK, Premier Sports.
            return ["sky sports", "premier sports", "bein sport", "espn"]
        case "soccer/bel.1":
            // Belgian Pro League: DAZN (domestic), beIN Sports (international).
            return ["dazn", "bein sport", "eleven sports", "proximus sports"]
        case "soccer/tur.1":
            // Turkish Süper Lig: beIN Sports worldwide.
            return ["bein sport", "bein sports", "beinsports", "s sport", "ssport"]
        case "soccer/gre.1":
            // Greek Super League: COSMOTE Sport, Novasports.
            return ["cosmote sport", "cosmote", "novasports", "nova sport", "ert sports"]
        case "soccer/aut.1":
            // Austrian Bundesliga: Sky Austria.
            return ["sky sport austria", "sky sport", "puls 4", "puls4"]
        case "soccer/sui.1":
            // Swiss Super League: RSI, SRF, RTS, Blue Sport.
            return ["blue sport", "bluesport", "rsi", "srf", "rts", "mysports"]
        case "soccer/den.1":
            // Danish Superliga: TV2 Denmark.
            return ["tv2 sport", "tv 2 sport", "discovery plus", "discovery+", "viaplay"]
        case "soccer/swe.1":
            // Allsvenskan: TV4, Telia.
            return ["tv4 sport", "tv4", "telia", "viaplay", "c more"]
        case "soccer/pol.1":
            // Ekstraklasa: Canal+ Poland.
            return ["canal plus", "polsat sport", "tvp sport"]
        case "soccer/nor.1":
            // Eliteserien: TV2 Norway.
            return ["tv2 sport", "tv 2 sport", "viaplay", "max sport"]
        case "soccer/rom.1":
            // Romanian SuperLiga: Digi Sport, Prima Sport, Orange Sport.
            return ["digi sport", "prima sport", "orange sport", "primasport"]
        case "soccer/sau.1":
            // Saudi Pro League: Thmanyah, SSC, beIN Sports.
            return ["ssc", "thmanyah", "bein sport", "bein sports", "beinsports"]
        case "soccer/qat.1":
            // Qatar Stars League: Al Kass.
            return ["al kass", "alkass", "bein sport", "qatar tv"]
        case "soccer/jpn.1":
            // J1 League: DAZN Japan.
            return ["dazn", "nhk", "fuji tv", "j sports"]
        case "soccer/kor.1", "soccer/kor.2":
            // K League: Coupang Play.
            return ["coupang", "coupang play", "spotv", "jtbc"]
        case "soccer/aus.1", "soccer/aus.nwsl":
            // A-League: Paramount+ (Australia).
            return ["paramount plus", "paramount+", "10 play", "ten play", "paramount"]
        case "soccer/rsa.1":
            // South African Premiership: SuperSport, Canal+.
            return ["supersport", "super sport", "canal plus", "dstv"]
        case "soccer/can.1":
            // Canadian Premier League: OneSoccer.
            return ["onesoccer", "one soccer", "cbcsports", "cbc sports"]
        case "soccer/mex.1":
            // Liga MX: Televisa channels, TV Azteca, Fox Sports Mexico, Prime Video (Chivas).
            return [
                "canal 5", "tudn", "las estrellas", "azteca", "azteca 7",
                "fox sports", "fox deportes", "prime video", "amazon prime",
                "tdn", "claro sports", "claro video"
            ]
        case "soccer/bra.1", "soccer/bra.2":
            // Brazilian Série A/B: Globo, Premiere, Amazon Prime Video, SporTV, Record, CazéTV.
            return [
                "premiere", "globo", "sportv", "spor tv", "amazon prime", "prime video",
                "record", "cazé tv", "caze tv", "cazetv", "ge tv", "getv"
            ]
        case "soccer/arg.1":
            // Argentine LPF: TNT Sports Argentina, ESPN.
            return ["tnt sports", "tntsports", "espn", "directv sports", "dsports"]
        case "soccer/col.1":
            // Colombian Liga BetPlay: Win Sports.
            return ["win sports", "winsports", "espn", "rcn", "caracol"]
        case "soccer/chi.1":
            // Chilean Liga de Primera: TNT Sports Chile.
            return ["tnt sports", "tntsports", "canal 13", "chilevisión", "chilevision"]
        case "soccer/per.1":
            // Peruvian Liga 1: L1 MAX.
            return ["l1 max", "l1max", "liga 1 max", "america tv", "gol peru"]
        case "soccer/ecu.1":
            // Ecuadorian LigaPro: Zapping.
            return ["zapping", "gol tv", "tc sports", "tcs"]
        case "soccer/mor.1":
            // Moroccan Botola Pro: Arryadia, 2M.
            return ["arryadia", "2m", "snrt", "bein sport"]
        case "soccer/concacaf.champions":
            // Concacaf Champions Cup: OneSoccer (Canada), Fox Sports (USA), Televisa (Mexico).
            return [
                "onesoccer", "one soccer", "fox sports", "fox deportes", "tudn",
                "televisa", "cbs sports", "paramount"
            ]
        case "soccer/fifa.world", "soccer/fifa.wwc":
            return [
                "fox", "fs1", "telemundo", "peacock", "tnt sports", "bbc", "itv", "bein sport",
                "fifa wc"
            ]

        // ── Football ────────────────────────────────────────────────────────
        case "football/nfl":
            return [
                "cbs", "fox", "nbc", "abc", "espn", "nfl network", "prime",
                "amazon", "peacock", "paramount", "dazn nfl"
            ]

        // ── Hockey ───────────────────────────────────────────────────────────
        case "hockey/nhl":
            return [
                "espn", "abc", "tnt", "tbs", "sportsnet", "tsn", "rds",
                "nhl network", "nhln", "peacock", "tva sports"
            ]

        // ── Basketball ──────────────────────────────────────────────────────
        case "basketball/nba":
            return ["tnt", "abc", "espn", "nba tv", "nbatv", "dazn nba", "bein sports"]

        // ── Baseball ─────────────────────────────────────────────────────────
        case "baseball/mlb":
            return [
                "fox", "fs1", "espn", "apple tv", "apple", "peacock",
                "mlb network", "mlbn", "tbs"
            ]

        // ── Racing ───────────────────────────────────────────────────────────
        case "racing/f1":
            return [
                "sky sport f1", "sky sports f1", "sky f1", "dazn f1", "f1tv", "f1 tv",
                "formula 1 tv", "alwan f1", "f1 tv pro", "channel 4", "espn f1"
            ]
        case "racing/nascar-premier", "racing/nascar-truck":
            return [
                "fox", "nbc", "nbc sports", "tntsports", "tnt sports",
                "peacock", "fs1", "fs2"
            ]
        case "racing/irl":
            return [
                "fox", "fox sports", "fs1", "fs2", "indycar", "indy car", "ntt indycar",
                "peacock", "nbc", "nbc sports", "sky sports f1", "dazn"
            ]

        // ── Golf ─────────────────────────────────────────────────────────────
        case "golf/pga", "golf/lpga", "golf/champions-tour":
            return [
                "golf channel", "pga tour", "cbs", "nbc", "peacock",
                "sky sports golf", "sky sport golf", "bbc sport"
            ]
        case "golf/eur":
            return ["sky sports golf", "sky sport golf", "eurosport", "golf channel"]

        // ── Tennis ───────────────────────────────────────────────────────────
        case "tennis/atp", "tennis/wta":
            return [
                "tennis channel", "espn", "bein sport", "bein sports",
                "eurosport", "amazon prime", "prime video",
                "sky sports", "sky sport", "wowow", "supertennis"
            ]

        default:
            break
        }

        // ── Tour de France (event-title based) ──────────────────────────────
        guard isTourDeFrance(title) else { return [] }

        return [
            // France Télévisions channels. "france 2 " and "france 3 " use a trailing
            // space so that "france 24" (a news channel) does not false-positive —
            // "france 24" normalises to "france 24" which does not contain "france 2 ".
            "france 2 ", "france 3 ", "france televisions", "france tv sport",
            "eurosport", "eurosport extra",
            "hbo max", "ard", "servus tv", "servus",
            "rtbf", "vrt", "czech tv", "ct sport", "dktv2", "tv2 norway", "tv2", "rtve", "tg4",
            "rai sports", "rai sport", "rai", "rtl", "nos", "tnt sports", "eitb", "rtp", "stvr",
            "rtv slovenija", "rtv slo", "srg ssr", "mtva", "okko", "s4c", "abu dhabi sports",
            "supersport", "bein sport asia", "bein sports asia", "bein sport", "zhubo tv", "cctv",
            "j sports", "wowow", "elta", "coupang", "sbs", "sky sport", "espn", "flosports",
            "caracol tv", "caracol", "canal rcn", "rcn", "nbc sports", "peacock", "tv5monde"
        ]
    }

    private static func isTourDeFrance(_ normalizedTitle: String) -> Bool {
        normalizedTitle.contains("tour") && normalizedTitle.contains("france")
    }

    /// Lowercases, strips diacritics, removes country/group prefixes (e.g. "US:", "UK|",
    /// "US ★ ", "DE ★ ", "MotoGP ★ ") and punctuation, and collapses whitespace.
    private static func normalize(_ input: String) -> String {
        var s = input.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        // Drop a leading "xx:" or "xx|" M3U country/quality prefix.
        if let separatorIndex = s.firstIndex(where: { $0 == ":" || $0 == "|" }),
           s.distance(from: s.startIndex, to: separatorIndex) <= 4 {
            s = String(s[s.index(after: separatorIndex)...])
        }
        // Drop a leading "XX ★ " Xtream/IPTV country-group prefix (e.g. "US ★ ", "SPORT ★ ",
        // "MotoGP ★ "). Threshold of 8 covers prefixes up to 7 chars + space before ★.
        if let starIndex = s.firstIndex(where: { $0 == "\u{2605}" }),
           s.distance(from: s.startIndex, to: starIndex) <= 8 {
            let after = s.index(after: starIndex)
            s = String(s[after...])
        }
        let allowed = s.map { char -> Character in
            char.isLetter || char.isNumber ? char : " "
        }
        return String(allowed)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let soccerClubWords: Set<String> = ["fc", "cf", "sc", "city", "united"]

    private static let mlsTeamAliases: [String: [String]] = [
        "atlanta united": ["atlanta united", "atl utd", "atlanta utd"],
        "austin fc": ["austin fc"],
        "charlotte fc": ["charlotte fc"],
        "chicago fire": ["chicago fire", "chicago fire fc"],
        "colorado rapids": ["colorado rapids"],
        "columbus crew": ["columbus crew"],
        "dc united": ["dc united", "d c united", "dcu"],
        "fc cincinnati": ["fc cincinnati", "cincinnati"],
        "fc dallas": ["fc dallas", "dallas"],
        "houston dynamo": ["houston dynamo", "houston dynamo fc"],
        "inter miami": ["inter miami", "inter miami cf", "miami cf"],
        "inter miami cf": ["inter miami", "inter miami cf", "miami cf"],
        "la galaxy": ["la galaxy", "lagalaxy"],
        "los angeles fc": ["los angeles fc", "lafc", "la fc"],
        "los angeles football club": ["los angeles fc", "los angeles football club", "lafc", "la fc"],
        "minnesota united": ["minnesota united", "mn united", "minnesota utd"],
        "cf montreal": ["cf montreal", "montreal impact", "montreal"],
        "montreal impact": ["cf montreal", "montreal impact", "montreal"],
        "nashville sc": ["nashville sc", "nashville"],
        "new england revolution": ["new england revolution", "new england revs", "revolution"],
        "new york city": ["new york city", "new york city fc", "nycfc", "nyc fc"],
        "new york city fc": ["new york city", "new york city fc", "nycfc", "nyc fc"],
        "new york red bulls": ["new york red bulls", "ny red bulls", "red bulls"],
        "orlando city": ["orlando city", "orlando city sc"],
        "philadelphia union": ["philadelphia union", "phila union"],
        "portland timbers": ["portland timbers"],
        "real salt lake": ["real salt lake", "rsl"],
        "san diego fc": ["san diego fc"],
        "san jose earthquakes": ["san jose earthquakes", "sj earthquakes", "quakes"],
        "seattle sounders": ["seattle sounders", "seattle sounders fc"],
        "sporting kansas city": ["sporting kansas city", "sporting kc", "skc"],
        "st louis city": ["st louis city", "st louis city sc", "stl city"],
        "st louis city sc": ["st louis city", "st louis city sc", "stl city"],
        "toronto fc": ["toronto fc", "tfc"],
        "vancouver whitecaps": ["vancouver whitecaps", "vancouver whitecaps fc"]
    ]

    private static let knownNetworks: Set<String> = [
        // US broadcast / cable
        "espn", "fox", "cbs", "nbc", "abc", "tnt", "tbs", "fs1", "fs2",
        "nfl network", "nba tv", "nhl network", "mlb network", "golf channel", "tennis channel",
        "usa network", "btn", "sec", "acc", "nbcsn", "peacock", "paramount", "prime",
        "apple tv", "mls season pass", "willow", "tudn",
        // International
        "sky", "bein", "dazn", "eurosport", "canal plus", "supersport",
        "france tv", "france televisions", "bt sport", "tnt sports", "tntsports",
        "optus sport", "sportsnet", "tsn", "rds", "tva sports",
        "viaplay", "ziggo sport", "sport1", "sport tv", "eleven sports",
        "arena sport", "sportklub", "sport klub", "cosmote sport",
        "setanta", "nova sport",
        // South American
        "premiere", "sportv", "globo", "win sports", "dsports", "directv sports",
        "l1 max", "l1max", "zapping",
        // Asian / Oceanic
        "coupang play", "j sports", "paramount plus",
        // African / Middle East
        "al kass", "alkass", "arryadia", "thmanyah", "ssc",
        // European regional
        "premier sports", "digi sport", "prima sport", "orange sport",
        "proximus sports", "blue sport", "bluesport", "polsat sport", "tvp sport",
        // Fighting / niche
        "fightbox", "fight network", "fight sports",
        // Streaming dedicated
        "flo", "flo sports", "f1tv", "motogp", "nfl game", "nhl game",
        "onesoccer", "one soccer", "fubo"
    ]

    private static func isKnownSportsNetwork(_ haystack: String) -> Bool {
        knownNetworks.contains { haystack.contains($0) }
    }
}
