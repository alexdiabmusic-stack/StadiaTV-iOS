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

            // Channels whose name marks them as news or finance content never carry live sports.
            guard haystackTokens.isDisjoint(with: Self.nonSportsNameTokens) else { continue }

            let paddedHaystack = " \(haystack) "
            var score = 0
            var evidence: Set<StreamEvidenceCategory> = []

            // Eliminate tokens shared by both teams before matching — "Los Angeles" appearing in both
            // Lakers and Clippers cannot confirm either team from a channel named "ABC Los Angeles".
            let sharedTeamTokens = Set(homeTokens).intersection(Set(awayTokens))
            let distinctHome = sharedTeamTokens.isEmpty ? homeTokens : homeTokens.filter { !sharedTeamTokens.contains($0) }
            let distinctAway = sharedTeamTokens.isEmpty ? awayTokens : awayTokens.filter { !sharedTeamTokens.contains($0) }

            let homeHit = matches(distinctHome.isEmpty ? homeTokens : distinctHome, in: haystack, tokens: haystackTokens) || aliasMatches(homeAliases, padded: paddedHaystack, tokens: haystackTokens)
            let awayHit = matches(distinctAway.isEmpty ? awayTokens : distinctAway, in: haystack, tokens: haystackTokens) || aliasMatches(awayAliases, padded: paddedHaystack, tokens: haystackTokens)

            // Both teams named -> almost certainly the event feed.
            if homeHit && awayHit {
                score += 100
                evidence.insert(.teamNameMatch)
            } else if homeHit || awayHit {
                // Single-team hit: score boost but not enough to claim both teams are listed.
                score += 40
            }

            // Event-title feeds matter for non-team sports and special broadcasts
            // such as Tour de France stages.
            if eventTitleMatches(eventTokens, in: haystack, tokens: haystackTokens) {
                score += 80
                evidence.insert(.eventTitleMatch)
            }

            // Abbreviation matches (whole-token only, 3-char minimum to prevent
            // 2-char country-code prefixes like "US ★" or "DE ★" from scoring
            // against national team abbreviations like "US" or "DE").
            if homeAbbr.count >= 3, haystackTokens.contains(homeAbbr) { score += 15 }
            if awayAbbr.count >= 3, haystackTokens.contains(awayAbbr) { score += 15 }

            // Broadcast network on the channel name — require whole-word (single-word networks)
            // or phrase-boundary (multi-word networks) to avoid "fox" matching "fox news".
            for network in broadcasts where !network.isEmpty {
                let hit = network.contains(" ")
                    ? paddedHaystack.contains(" \(network) ")
                    : haystackTokens.contains(network)
                if hit {
                    score += 35
                    evidence.insert(.broadcastRightsMatch)
                }
            }

            // Known event-specific rights holders, used when ESPN's broadcast
            // payload is sparse for events such as Tour de France stages.
            if eventBroadcasterMatches(eventSpecificBroadcasters, padded: paddedHaystack, tokens: haystackTokens) {
                score += 70
                evidence.insert(.broadcastRightsMatch)
            }

            // League keywords — word-boundary only to prevent "nba" matching inside "wnba".
            var leagueKeywordHit = false
            for keyword in leagueKeywords {
                let hit = keyword.contains(" ")
                    ? paddedHaystack.contains(" \(keyword) ")
                    : haystackTokens.contains(keyword)
                if hit {
                    score += 12
                    leagueKeywordHit = true
                }
            }
            // Dedicated league-branded channel bonus: channels like "NHL GAME 07",
            // "DAZN NBA 1", or "SKY SPORT F1" contain the league's short name as a
            // whole word and deserve a bigger boost than a generic keyword substring hit.
            if haystackTokens.contains(leagueShort) {
                score += 30
                leagueKeywordHit = true
            }
            if leagueKeywordHit { evidence.insert(.leagueKeyword) }

            // Sports group / generic sports network bonus.
            if let group = channel.group?.lowercased(),
               group.contains("sport") || group.contains(match.league.group.rawValue.lowercased()) {
                score += 6
            }
            if isKnownSportsNetwork(haystack) {
                score += 5
                evidence.insert(.networkNameMatch)
            }

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
                var result = RankedSource(channel: channel, score: score)
                result.evidenceCategories = evidence
                ranked.append(result)
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

    private static func eventBroadcasterMatches(_ aliases: [String], padded paddedHaystack: String, tokens haystackTokens: Set<String>) -> Bool {
        aliasMatches(aliases, padded: paddedHaystack, tokens: haystackTokens)
    }

    /// Matches any alias against a channel haystack using whole-word boundaries.
    /// Single-word aliases require a whole token; multi-word phrases require space-padded
    /// containment so "nba tv" does not match inside "wnba tv".
    private static func aliasMatches(_ aliases: [String], padded paddedHaystack: String, tokens haystackTokens: Set<String>) -> Bool {
        aliases.contains { alias in
            guard !alias.isEmpty else { return false }
            if alias.contains(" ") { return paddedHaystack.contains(" \(alias) ") }
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
        // For motorsport events, detect the session type so session-specific policies apply.
        // (e.g. ESPN carries F1 qualifying + race but not practice sessions in the US.)
        let session: RacingSessionKind = match.league.group == .racing
            ? RacingSessionKind.detect(from: "\(match.name) \(match.shortName)")
            : .unknown

        let aliases = BroadcastRightsStore.shared.broadcasters(for: match.league.path, at: match.date, session: session)
        if !aliases.isEmpty { return aliases }

        // Tour de France: not in the ESPN league catalog, detected by event title pattern.
        let title = normalize("\(match.name) \(match.shortName) \(match.league.name)")
        guard isTourDeFrance(title) else { return [] }
        return BroadcastRightsStore.shared.broadcasters(for: "cycling/tour-de-france", at: match.date)
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
        // Preserve "+" as "plus" so ESPN+ stays distinguishable from ESPN after punctuation strip.
        s = s.replacingOccurrences(of: "+", with: "plus")
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
        let padded = " \(haystack) "
        return knownNetworks.contains { padded.contains(" \($0) ") }
    }

    /// Tokens in a channel name that indicate the channel is non-sports content.
    /// Channels with these tokens are excluded before any scoring.
    private static let nonSportsNameTokens: Set<String> = [
        "news", "business", "finance", "financial",
        "weather", "forecast",
        "shopping", "infomercial",
        "cooking", "food",
        "cartoon", "anime",
        "worship", "church", "religious", "faith"
    ]
}
