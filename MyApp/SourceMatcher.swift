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
    ///
    /// NOTE: "city" and "united" are intentionally NOT stop words — they are identity-bearing
    /// in soccer (Manchester City, Manchester United, DC United) and must not be discarded.
    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "the", "of", "and", "de", "du", "le", "la", "les",
        "club", "hd", "sd", "fhd", "uhd", "4k", "tv", "channel", "live", "sports", "sport",
        "featured", "coverage", "session", "players", "tbd", "early", "weekday", "day", "night", "round", "rounds"
    ]

    static func rank(match: Match, channels: [Channel], preferredLanguages: Set<String> = []) -> [RankedSource] {
        guard match.state != .final else { return [] }
        let participants = ParticipantIdentity(match)
        let broadcasts = match.broadcasts.map(ProviderChannelIdentity.init).filter { !$0.tokens.isEmpty }
        let leagueKeywords = Set((match.league.keywords + eventAliases(for: match)).map(normalize))
        let leagueShort = normalize(match.league.shortName)
        var rightsByCountry: [String: [ProviderChannelIdentity]] = [:]
        var rankedByID: [String: RankedSource] = [:]

        for channel in channels {
            let identity = ProviderChannelIdentity(channel.name)
            let haystack = identity.eventText
            guard isEligible(name: channel.name, normalizedName: haystack, for: match,
                             participants: participants) else { continue }
            let (homeHit, awayHit) = participants.hits(in: haystack, labelledFixture: hasFixtureSeparator(channel.name))
            var score = 0
            var evidence: Set<StreamEvidenceCategory> = []
            if homeHit && awayHit {
                score = 200
                evidence.insert(.teamNameMatch)
            } else if homeHit || awayHit {
                score = 35
            }
            // Team-event titles must prove both participants. Two city words or one full
            // team's name cannot independently confirm the entire fixture.
            if !usesParticipants(match), eventTitleMatches(match, in: haystack) {
                score = max(score, 180)
                evidence.insert(.eventTitleMatch)
            }

            let exactBroadcast = broadcasts.contains { identity.exactlyMatches($0) }
            let countryKey = identity.country ?? ""
            if rightsByCountry[countryKey] == nil {
                rightsByCountry[countryKey] = eventBroadcasterAliases(for: match, country: identity.country)
                    .map(ProviderChannelIdentity.init)
            }
            // An explicit ESPN2/ESPN+ listing outweighs a broad ESPN policy. The sibling
            // may still be a separately evidenced event feed, but earns no rights evidence.
            let contradictsBroadcast = !exactBroadcast && broadcasts.contains { identity.isSibling(of: $0) }
            let rightsHit = !contradictsBroadcast && (rightsByCountry[countryKey] ?? []).contains {
                identity.belongs(to: $0)
            }
            if exactBroadcast {
                score += 65
                evidence.insert(.broadcastRightsMatch)
            } else if rightsHit {
                score += 28
                evidence.insert(.broadcastRightsMatch)
            }

            let padded = " \(haystack) "
            let keywordHit = leagueKeywords.contains { !$0.isEmpty && padded.contains(" \($0) ") }
            let leagueHit = !leagueShort.isEmpty && padded.contains(" \(leagueShort) ")
            if keywordHit || leagueHit {
                score += leagueHit ? 25 : 12
                evidence.insert(.leagueKeyword)
            }
            // Preferences and a generic Sports category are tie-breakers only; they
            // cannot create a candidate without independent event or broadcaster evidence.
            guard score >= minimumScore(for: match) else { continue }
            if isKnownSportsNetwork(haystack) {
                score += 3
                evidence.insert(.networkNameMatch)
            }
            if channel.group?.lowercased().contains("sport") == true { score += 2 }
            if !preferredLanguages.isEmpty {
                let tags = languageTags(in: channel.name)
                if !tags.isEmpty { score += tags.isDisjoint(with: preferredLanguages) ? -8 : 8 }
            }
            var result = RankedSource(channel: channel, score: score)
            result.evidenceCategories = evidence
            // IDs are scoped by playlist: two providers can legitimately use the same number.
            let key = "\(channel.playlistID.uuidString)|\(channel.id)"
            if let old = rankedByID[key], !ranksBefore(result, old) { continue }
            rankedByID[key] = result
        }
        return rankedByID.values.sorted(by: ranksBefore)
    }

    /// Shared hard gates also apply when a guide injects a previously unranked channel.
    static func isEligible(channel: Channel, for match: Match) -> Bool {
        isEligible(name: channel.name, normalizedName: ProviderChannelIdentity(channel.name).eventText,
                   for: match, participants: ParticipantIdentity(match))
    }

    private static func isEligible(name: String, normalizedName: String, for match: Match,
                                   participants: ParticipantIdentity) -> Bool {
        guard match.state != .final else { return false }
        let words = Set(normalizedName.split(separator: " ").map(String.init))
        guard words.isDisjoint(with: nonSportsNameTokens), !hasStaleOrReplayLabel(name, at: match.date),
              !SportsOntology.isIncompatible(candidate: SportsOntology.classifyFeedFamily(from: name),
                                               with: SportsOntology.feedFamily(for: match.league.path)) else { return false }
        if match.league.group == .racing {
            let expected = RacingSessionKind.detect(from: "\(match.name) \(match.shortName)")
            let actual = RacingSessionKind.detect(from: name)
            if expected != .unknown && actual != .unknown && actual != expected { return false }
        }
        if usesParticipants(match), hasFixtureSeparator(name) {
            let (home, away) = participants.hits(in: normalizedName, labelledFixture: true)
            return home && away
        }
        return true
    }

    /// Shared ordering for discovery and both detail screens. Confirmed event evidence
    /// precedes possible broadcasters regardless of accumulated keyword bonuses.
    static func ranksBefore(_ lhs: RankedSource, _ rhs: RankedSource) -> Bool {
        let confirming: Set<StreamEvidenceCategory> = [.guideListsMatch, .teamNameMatch, .eventTitleMatch]
        let leftConfirmed = !lhs.evidenceCategories.isDisjoint(with: confirming)
        let rightConfirmed = !rhs.evidenceCategories.isDisjoint(with: confirming)
        if leftConfirmed != rightConfirmed { return leftConfirmed }
        let leftGuide = lhs.evidenceCategories.contains(.guideListsMatch)
        let rightGuide = rhs.evidenceCategories.contains(.guideListsMatch)
        if leftGuide != rightGuide { return leftGuide }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.channel.name != rhs.channel.name { return lhs.channel.name < rhs.channel.name }
        if lhs.channel.playlistID != rhs.channel.playlistID {
            return lhs.channel.playlistID.uuidString < rhs.channel.playlistID.uuidString
        }
        return lhs.channel.id < rhs.channel.id
    }

    /// A nearby guide entry is a retrieval candidate, not confirmation. Require the
    /// actual fixture/session and substantial overlap with its scheduled window.
    static func confirms(programme: EPGProgramme, for match: Match) -> Bool {
        guard match.state != .final, programme.isValid,
              programme.start <= match.date.addingTimeInterval(30 * 60),
              programme.end >= match.date.addingTimeInterval(15 * 60) else { return false }
        let title = [programme.title, programme.subtitle ?? ""].joined(separator: " ")
        guard !hasStaleOrReplayLabel(title, at: match.date),
              !SportsOntology.isIncompatible(candidate: SportsOntology.classifyFeedFamily(from: title),
                                               with: SportsOntology.feedFamily(for: match.league.path)) else { return false }
        if match.league.group == .racing {
            let expected = RacingSessionKind.detect(from: "\(match.name) \(match.shortName)")
            let actual = RacingSessionKind.detect(from: title)
            if expected != .unknown && actual != .unknown && expected != actual { return false }
        }
        let normalized = normalize(title)
        if usesParticipants(match) {
            let (home, away) = ParticipantIdentity(match).hits(in: normalized, labelledFixture: hasFixtureSeparator(title))
            return home && away
        }
        return eventTitleMatches(match, in: normalized)
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

    private static func usesParticipants(_ match: Match) -> Bool {
        ![SportGroup.racing, .golf, .cycling, .wrestling].contains(match.league.group)
    }

    private struct ParticipantIdentity {
        let home: [String]
        let away: [String]

        init(_ match: Match) {
            let homeAliases = SourceMatcher.teamAliases(for: match.home, league: match.league)
            let awayAliases = SourceMatcher.teamAliases(for: match.away, league: match.league)
            let homeWords = Set(homeAliases.flatMap { SourceMatcher.normalize($0).split(separator: " ").map(String.init) })
            let awayWords = Set(awayAliases.flatMap { SourceMatcher.normalize($0).split(separator: " ").map(String.init) })
            let shared = homeWords.intersection(awayWords)
            func phrases(_ aliases: [String], otherWords: Set<String>) -> [String] {
                var values = Set<String>()
                for alias in aliases {
                    let words = SourceMatcher.normalize(alias).split(separator: " ").map(String.init)
                    guard words.contains(where: { !shared.contains($0) && !SourceMatcher.stopWords.contains($0) }) else { continue }
                    if words.count > 1 || (words.first?.count ?? 0) >= 3 {
                        values.insert(words.joined(separator: " "))
                    }
                    // Common team nickname shorthand, with geographic/club fragments excluded.
                    if words.count > 1, let last = words.last, last.count >= 4,
                       !otherWords.contains(last), !Self.weakWords.contains(last),
                       !SourceMatcher.stopWords.contains(last) {
                        values.insert(last)
                    }
                }
                return values.sorted()
            }
            home = phrases(homeAliases, otherWords: awayWords)
            away = phrases(awayAliases, otherWords: homeWords)
        }

        func hits(in text: String, labelledFixture: Bool = false) -> (Bool, Bool) {
            if labelledFixture {
                // A trailing @ Sep 25 7:05 PM is scheduling metadata, not a third team.
                let fixture = text.replacingOccurrences(
                    of: #" (?:versus|at) (?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?) \d.*$"#,
                    with: "", options: .regularExpression)
                let segments = fixture.components(separatedBy: " versus ")
                    .flatMap { $0.components(separatedBy: " vs ") }
                    .flatMap { $0.components(separatedBy: " at ") }
                    .flatMap { $0.components(separatedBy: " v ") }
                // A listing of several fixtures cannot confirm a synthetic cross-pair.
                guard segments.count == 2 else { return (false, false) }
                let forward = segment(segments[0], matches: home) && segment(segments[1], matches: away)
                let reverse = segment(segments[0], matches: away) && segment(segments[1], matches: home)
                return (forward || reverse, forward || reverse)
            }
            let padded = " \(text) "
            return (home.contains { padded.contains(" \($0) ") }, away.contains { padded.contains(" \($0) ") })
        }

        private func segment(_ text: String, matches aliases: [String]) -> Bool {
            let padded = " \(text) "
            return aliases.contains { alias in
                guard padded.contains(" \(alias) ") else { return false }
                if alias.contains(" ") { return true }
                // A bare nickname/abbreviation is useful, but 'Mississippi State Bulldogs'
                // cannot establish 'Georgia Bulldogs' merely through their shared nickname.
                let remainder = padded.replacingOccurrences(of: " \(alias) ", with: " ")
                    .split(separator: " ").map(String.init)
                return remainder.allSatisfy { Self.fixtureContext.contains($0) || $0.allSatisfy(\.isNumber) }
            }
        }

        private static let fixtureContext: Set<String> = [
            "us", "ca", "uk", "gb", "en", "english", "nba", "wnba", "nfl", "nhl", "mlb", "milb",
            "ncaaf", "ncaab", "ncaa", "epl", "mls", "football", "basketball", "hockey", "baseball",
            "soccer", "tennis", "atp", "wta", "espn", "espnplus", "plus", "dazn", "flo", "flosports",
            "peacock", "tsn", "rds", "sky", "sports", "sport", "live", "hd", "fhd", "uhd", "sd",
            "game", "event", "events", "tv", "feed", "stream", "backup", "bk", "pm", "am"
        ]

        private static let weakWords: Set<String> = [
            "city", "united", "state", "town", "county", "athletic", "national", "international",
            "york", "angeles", "diego", "antonio", "francisco", "jose", "louis", "orleans",
            "north", "south", "east", "west", "central", "university", "college", "football",
            "basketball", "hockey", "baseball", "soccer", "rotterdam", "manchester"
        ]
    }

    private static func eventTitleMatches(_ match: Match, in text: String) -> Bool {
        if match.league.group == .racing {
            let expected = RacingSessionKind.detect(from: "\(match.name) \(match.shortName)")
            let actual = RacingSessionKind.detect(from: text)
            if expected != .unknown && actual != expected { return false }
        }
        let generic = stopWords.union(["at", "vs", "versus", "race", "grand", "prix", "formula", "practice", "qualifying"])
        let wanted = Set(tokens(from: match.name).filter { !generic.contains($0) })
        let actual = Set(text.split(separator: " ").map(String.init))
        // The discriminating venue/event/stage tokens must all be present. Session-only
        // or sport-only text cannot establish a specific race or tournament.
        let distinctive = wanted.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) }
        guard !distinctive.isEmpty, wanted.isSubset(of: actual) else { return false }
        let numbers = Set(normalize(match.name).split(separator: " ").filter { $0.allSatisfy(\.isNumber) }.map(String.init))
        return numbers.isSubset(of: actual)
    }

    private static let fixtureSeparator = try! NSRegularExpression(
        pattern: #"(?i)\s(?:vs[.]?|versus|v[.]|at|@)\s"#)
    private static let dateLabel = try! NSRegularExpression(pattern: #"\b(20\d{2})-(\d{2})-(\d{2})\b"#)
    private static let monthDateLabel = try! NSRegularExpression(
        pattern: #"(?i)\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#)
    private static let replayWords: Set<String> = ["replay", "rerun", "highlights", "classic", "encore"]

    private static func hasFixtureSeparator(_ text: String) -> Bool {
        fixtureSeparator.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func hasStaleOrReplayLabel(_ text: String, at date: Date) -> Bool {
        let words = Set(normalize(text).split(separator: " ").map(String.init))
        if !words.isDisjoint(with: replayWords) { return true }
        // Provider timestamps have no reliable zone. Permit adjacent calendar dates
        // across the international date line, but reject explicitly stale fixtures.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let eventDay = calendar.startOfDay(for: date)
        let raw = text as NSString
        for found in dateLabel.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let components = DateComponents(year: Int(raw.substring(with: found.range(at: 1))),
                                            month: Int(raw.substring(with: found.range(at: 2))),
                                            day: Int(raw.substring(with: found.range(at: 3))))
            guard let labelled = calendar.date(from: components) else { return true }
            if abs(labelled.timeIntervalSince(eventDay)) > 86400 { return true }
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let year = calendar.component(.year, from: date)
        for found in monthDateLabel.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let monthText = String(raw.substring(with: found.range(at: 1)).lowercased().prefix(3))
            guard let monthIndex = months.firstIndex(of: monthText),
                  let day = Int(raw.substring(with: found.range(at: 2))) else { return true }
            let nearbyDates = [year - 1, year, year + 1].compactMap { year in
                calendar.date(from: DateComponents(year: year, month: monthIndex + 1, day: day))
            }
            if !nearbyDates.contains(where: { abs($0.timeIntervalSince(eventDay)) <= 86400 }) { return true }
        }
        return false
    }

    private static func minimumScore(for match: Match) -> Int {
        switch match.league.group {
        case .soccer, .racing, .golf, .tennis:
            return 20
        default:
            return 12
        }
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

    // MARK: - EPG-first backup matching

    /// Returns all channels whose names contain a team name or event/series keyword,
    /// excluding those already confirmed by the EPG guide.
    ///
    /// This is the fallback layer when the guide has no confirmed stream: it casts the
    /// widest reasonable net — any channel that mentions either team (or, for racing/golf,
    /// the series name) — without the scoring algorithm.
    static func teamNameBackups(match: Match, channels: [Channel], excludeIds: Set<String> = []) -> [RankedSource] {
        guard match.state != .final else { return [] }

        var results: [RankedSource] = []
        var seen = excludeIds

        if usesParticipants(match) {
            let participants = ParticipantIdentity(match)
            for channel in channels {
                guard !seen.contains(channel.id) else { continue }
                let identity = ProviderChannelIdentity(channel.name)
                let haystack = identity.eventText
                let (homeHit, awayHit) = participants.hits(in: haystack, labelledFixture: hasFixtureSeparator(channel.name))
                guard homeHit || awayHit else { continue }
                seen.insert(channel.id)
                let score = homeHit && awayHit ? 200 : 35
                var source = RankedSource(channel: channel, score: score)
                if homeHit && awayHit { source.evidenceCategories = [.teamNameMatch] }
                results.append(source)
            }
        } else {
            let tokens = eventSeriesTokens(for: match)
            guard !tokens.isEmpty else { return [] }
            for channel in channels {
                guard !seen.contains(channel.id) else { continue }
                let identity = ProviderChannelIdentity(channel.name)
                let haystack = " \(identity.eventText) "
                guard tokens.contains(where: { !$0.isEmpty && haystack.contains(" \($0) ") }) else { continue }
                seen.insert(channel.id)
                var source = RankedSource(channel: channel, score: 60)
                source.evidenceCategories = [.eventTitleMatch]
                results.append(source)
            }
        }

        return results.sorted(by: ranksBefore)
    }

    /// Tokens to match against channel names for non-participant sports (racing, golf, cycling, wrestling).
    private static func eventSeriesTokens(for match: Match) -> [String] {
        var tokens: [String] = []
        let leagueNorm = normalize(match.league.name + " " + match.league.shortName)
        switch match.league.group {
        case .racing:
            if leagueNorm.contains("formula") || leagueNorm.contains("f1") {
                tokens += ["f1", "formula 1", "formula one"]
            } else if leagueNorm.contains("motogp") {
                tokens += ["motogp", "moto gp"]
            } else if leagueNorm.contains("nascar") {
                tokens += ["nascar"]
            } else if leagueNorm.contains("indycar") {
                tokens += ["indycar"]
            } else {
                let short = normalize(match.league.shortName)
                if !short.isEmpty { tokens.append(short) }
            }
            // Include distinctive race-name tokens (e.g., "british", "monaco")
            let raceTokens = normalize(match.name).split(separator: " ").map(String.init)
                .filter { $0.count >= 4 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            tokens += raceTokens
        case .golf:
            tokens += ["pga", "golf"]
            if leagueNorm.contains("lpga") { tokens.append("lpga") }
            if leagueNorm.contains("european") { tokens += ["dp world", "european tour"] }
            let eventTokens = normalize(match.name).split(separator: " ").map(String.init)
                .filter { $0.count >= 4 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }
            tokens += eventTokens
        case .cycling:
            tokens += ["cycling", "cyclisme"]
            if isTourDeFrance(normalize(match.name + " " + match.league.name)) {
                tokens += ["tour de france", "tdf", "le tour"]
            }
        case .wrestling:
            tokens += ["wwe", "aew", "wrestling"]
            let eventTokens = normalize(match.name).split(separator: " ").map(String.init)
                .filter { $0.count >= 4 && !stopWords.contains($0) }
            tokens += eventTokens
        default:
            break
        }
        return tokens.filter { !$0.isEmpty }
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

    private static func eventBroadcasterAliases(for match: Match, country: String? = nil) -> [String] {
        // For motorsport events, detect the session type so session-specific policies apply.
        // (e.g. ESPN carries F1 qualifying + race but not practice sessions in the US.)
        let session: RacingSessionKind = match.league.group == .racing
            ? RacingSessionKind.detect(from: "\(match.name) \(match.shortName)")
            : .unknown

        let aliases = BroadcastRightsStore.shared.broadcasters(for: match.league.path, at: match.date, session: session, country: country)
        if !aliases.isEmpty { return aliases }

        // Tour de France: not in the ESPN league catalog, detected by event title pattern.
        let title = normalize("\(match.name) \(match.shortName) \(match.league.name)")
        guard isTourDeFrance(title) else { return [] }
        return BroadcastRightsStore.shared.broadcasters(for: "cycling/tour-de-france", at: match.date, country: country)
    }


    private static func isTourDeFrance(_ normalizedTitle: String) -> Bool {
        normalizedTitle.contains("tour") && normalizedTitle.contains("france")
    }

    private static func normalize(_ input: String) -> String {
        ProviderChannelIdentity.text(input)
    }

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
