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

            if score > 0 {
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
                "tudn", "univision", "tsn", "rds", "one soccer"
            ]
        case "soccer/eng.1":
            return [
                "sky sports", "sky sports premier league", "tnt sports", "tntsports",
                "bt sport", "peacock", "nbc sports", "nbcsn", "optus sport",
                "hub premier", "premier sports"
            ]
        case "soccer/uefa.champions", "soccer/uefa.europa":
            return [
                "cbs sports", "cbs", "paramount", "tnt sports", "tntsports",
                "dazn", "canal plus", "sky sport", "bein sport"
            ]
        case "soccer/esp.1":
            return [
                "dazn", "espn", "abc", "sky sports", "bein sport",
                "movistar", "m sport", "laliga tv", "la liga tv"
            ]
        case "soccer/ita.1":
            return [
                "dazn", "sky sport serie a", "sky sport", "espn",
                "peacock", "bein sport", "paramount"
            ]
        case "soccer/ger.1":
            return [
                "sky sport bundesliga", "sky sport", "dazn", "espn", "bein sport", "sport1"
            ]
        case "soccer/fra.1":
            return ["canal plus", "dazn", "bein sport", "amazon prime", "prime video"]
        case "soccer/ned.1":
            return ["viaplay", "ziggo sport", "espn", "dazn"]
        case "soccer/por.1":
            return ["sport tv", "benfica tv", "eleven sports", "dazn"]
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
            return ["peacock", "nbc", "nbc sports", "fox", "fs1", "sky sports f1", "dazn"]

        // ── Golf ─────────────────────────────────────────────────────────────
        case "golf/pga", "golf/lpga", "golf/champions-tour":
            return [
                "golf channel", "pga tour", "cbs", "nbc", "peacock",
                "sky sports golf", "sky sport golf", "bbc sport"
            ]
        case "golf/eur":
            return ["sky sports golf", "sky sport golf", "eurosport", "golf channel"]

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
        "nfl network", "nba tv", "nhl network", "mlb network", "golf channel",
        "usa network", "btn", "sec", "acc", "nbcsn", "peacock", "paramount", "prime",
        "apple tv", "mls season pass", "willow", "tudn",
        // International
        "sky", "bein", "dazn", "eurosport", "canal plus", "supersport",
        "france tv", "france televisions", "bt sport", "tnt sports", "tntsports",
        "optus sport", "sportsnet", "tsn", "rds", "tva sports",
        "viaplay", "ziggo sport", "sport1", "sport tv", "eleven sports",
        "arena sport", "sportklub", "sport klub", "cosmote sport",
        "setanta", "nova sport",
        // Fighting / niche
        "fightbox", "fight network", "fight sports",
        // Streaming dedicated
        "flo", "flo sports", "f1tv", "motogp", "nfl game", "nhl game"
    ]

    private static func isKnownSportsNetwork(_ haystack: String) -> Bool {
        knownNetworks.contains { haystack.contains($0) }
    }
}
