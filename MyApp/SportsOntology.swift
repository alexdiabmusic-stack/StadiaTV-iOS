import Foundation

// MARK: - FeedFamily

/// Exclusive sport/league feed classification per v3 specification.
/// Applied to channel names using strict word-boundary patterns.
nonisolated enum FeedFamily: String, Hashable, Sendable, CaseIterable {
    // Gridiron football
    case nfl, ncaaf, cfl, ufl
    // Basketball
    case nba, wnba, ncaam, ncaaw
    // Ice hockey
    case nhl, ahl
    // Baseball
    case mlb
    // Soccer / association football
    case mls, epl, eredivisie, laliga, bundesliga, ucl, uel
    // Tennis
    case tennis, atp, wta
    // Motorsport
    case f1, nascar, indycar, motogp
    // Golf
    case golf, pga, lpga
    // Combat sports
    case ufc, boxing
    /// Not classified / general-purpose feed.
    case unknown
}

// MARK: - FeedSpecificity

/// How event-specific a channel is. Higher specificity = stronger event evidence when present.
nonisolated enum FeedSpecificity: String, Hashable, Sendable {
    /// Stable general broadcast channel (ESPN2, Sportsnet Ontario).
    case generalChannel
    /// League-dedicated stable channel (NHL Network, NBA TV).
    case dedicatedLeagueChannel
    /// Numbered bank slot — POSSIBLE only until EPG confirms (NCAAF 37, DAZN 23, NHL GAME 07).
    case numberedEventSlot
    /// Channel whose metadata explicitly names the current event.
    case explicitEventFeed
}

// MARK: - SportsOntology

/// Classification and compatibility engine for sports feed families.
///
/// Provides:
/// - Channel name → FeedFamily classification using strict word-boundary patterns
/// - League path → FeedFamily mapping
/// - Hard incompatibility check between candidate and event feed families
/// - Numbered event bank slot detection
nonisolated enum SportsOntology {

    // MARK: League Path → FeedFamily

    /// Map a `League.path` to its canonical `FeedFamily`.
    static func feedFamily(for leaguePath: String) -> FeedFamily {
        switch leaguePath {
        case "football/nfl":                                      return .nfl
        case "football/college-football":                         return .ncaaf
        case "football/cfl":                                      return .cfl
        case "football/ufl":                                      return .ufl
        case "basketball/nba", "basketball/nba-development",
             "basketball/nbl":                                    return .nba
        case "basketball/wnba":                                   return .wnba
        case "basketball/mens-college-basketball":                return .ncaam
        case "basketball/womens-college-basketball":              return .ncaaw
        case "hockey/nhl", "hockey/mens-college-hockey",
             "hockey/womens-college-hockey":                      return .nhl
        case "baseball/mlb", "baseball/college-baseball",
             "baseball/world-baseball-classic":                   return .mlb
        case "soccer/usa.1":                                      return .mls
        case "soccer/eng.1":                                      return .epl
        case "soccer/ned.1":                                      return .eredivisie
        case "soccer/esp.1":                                      return .laliga
        case "soccer/ger.1":                                      return .bundesliga
        case "soccer/uefa.champions":                             return .ucl
        case "soccer/uefa.europa":                                return .uel
        case "tennis/atp":                                        return .atp
        case "tennis/wta":                                        return .wta
        case "racing/f1":                                         return .f1
        case "racing/nascar-premier", "racing/nascar-truck",
             "racing/nhra":                                       return .nascar
        case "racing/irl":                                        return .indycar
        case "golf/pga", "golf/champions-tour", "golf/eur":      return .pga
        case "golf/lpga":                                         return .lpga
        default:                                                  return .unknown
        }
    }

    // MARK: Channel Name → FeedFamily

    private static let feedFamilyPatterns: [(FeedFamily, NSRegularExpression)] = {
        // Ordered: check more-specific patterns before more-generic ones so that
        // WNBA is caught before NBA, etc.
        let defs: [(FeedFamily, String)] = [
            (.wnba,       #"\bWNBA\b"#),
            (.nba,        #"\bNBA\b"#),
            (.ncaaf,      #"\bNCAAF\b"#),
            (.ncaam,      #"\bNCAAM\b"#),
            (.ncaaw,      #"\bNCAAW\b"#),
            (.nfl,        #"\bNFL\b"#),
            (.cfl,        #"\bCFL\b"#),
            (.ufl,        #"\bUFL\b"#),
            (.nhl,        #"\bNHL\b"#),
            (.ahl,        #"\bAHL\b"#),
            (.mlb,        #"\bMLB\b"#),
            (.mls,        #"\bMLS\b"#),
            (.epl,        #"\bEPL\b|\bPREMIER\s+LEAGUE\b"#),
            (.eredivisie, #"\bEREDIVISIE\b"#),
            (.laliga,     #"\bLA\s?LIGA\b"#),
            (.bundesliga, #"\bBUNDESLIGA\b"#),
            (.ucl,        #"\bUCL\b|\bCHAMPIONS\s+LEAGUE\b"#),
            (.uel,        #"\bUEL\b|\bEUROPA\s+LEAGUE\b"#),
            (.atp,        #"\bATP\b"#),
            (.wta,        #"\bWTA\b"#),
            (.tennis,     #"\bTENNIS\b"#),
            (.f1,         #"\bF1\b|\bFORMULA\s+1\b|\bFORMULA\s+ONE\b"#),
            (.nascar,     #"\bNASCAR\b"#),
            (.indycar,    #"\bINDY\s?CAR\b"#),
            (.motogp,     #"\bMOTO\s?GP\b"#),
            (.pga,        #"\bPGA\b"#),
            (.lpga,       #"\bLPGA\b"#),
            (.golf,       #"\bGOLF\b"#),
            (.ufc,        #"\bUFC\b"#),
            (.boxing,     #"\bBOXING\b"#),
        ]
        return defs.compactMap { (family, pattern) in
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                return nil
            }
            return (family, re)
        }
    }()

    /// Classify a channel name into a `FeedFamily` using strict word-boundary patterns.
    /// Returns `.unknown` if no sport-exclusive keyword is found.
    static func classifyFeedFamily(from channelName: String) -> FeedFamily {
        let range = NSRange(channelName.startIndex..., in: channelName)
        for (family, re) in feedFamilyPatterns {
            if re.firstMatch(in: channelName, range: range) != nil {
                return family
            }
        }
        return .unknown
    }

    // MARK: Incompatibility Matrix

    // Logical sport groups used only for incompatibility evaluation —
    // not exposed as a public type since `SportGroup` in Models.swift serves display.
    private enum OntologyGroup: Equatable {
        case gridiron, basketball, hockey, baseball, soccer, tennis, motorsport, golf, combat, other
    }

    private static func group(for family: FeedFamily) -> OntologyGroup {
        switch family {
        case .nfl, .ncaaf, .cfl, .ufl:               return .gridiron
        case .nba, .wnba, .ncaam, .ncaaw:             return .basketball
        case .nhl, .ahl:                              return .hockey
        case .mlb:                                    return .baseball
        case .mls, .epl, .eredivisie, .laliga,
             .bundesliga, .ucl, .uel:                 return .soccer
        case .tennis, .atp, .wta:                     return .tennis
        case .f1, .nascar, .indycar, .motogp:         return .motorsport
        case .golf, .pga, .lpga:                      return .golf
        case .ufc, .boxing:                           return .combat
        case .unknown:                                return .other
        }
    }

    /// Returns `true` when `candidate` is a hard incompatibility with `eventFamily`.
    ///
    /// Two `.unknown` values are never considered incompatible. Incompatibilities:
    /// - Different sport groups (basketball channel for hockey event)
    /// - Within basketball: NBA / WNBA / NCAAM / NCAAW are separate competitions
    /// - Within gridiron: NFL / CFL / NCAAF / UFL are separate competitions
    /// - Within hockey: AHL ≠ NHL (affiliate vs top flight)
    static func isIncompatible(candidate: FeedFamily, with eventFamily: FeedFamily) -> Bool {
        guard candidate != .unknown, eventFamily != .unknown else { return false }
        guard candidate != eventFamily else { return false }

        // Different sport groups → hard incompatibility
        if group(for: candidate) != group(for: eventFamily) { return true }

        // Same sport group but dedicated sub-league channel — each sub-league has its own
        // branded channels that should never cross-match another competition in the group.
        let basketballSubLeagues: Set<FeedFamily> = [.nba, .wnba, .ncaam, .ncaaw]
        if basketballSubLeagues.contains(candidate) && basketballSubLeagues.contains(eventFamily) { return true }

        let gridironSubLeagues: Set<FeedFamily> = [.nfl, .cfl, .ncaaf, .ufl]
        if gridironSubLeagues.contains(candidate) && gridironSubLeagues.contains(eventFamily) { return true }

        // AHL ≠ NHL — affiliate league vs top flight (same hockey group).
        let hockeySubLeagues: Set<FeedFamily> = [.nhl, .ahl]
        if hockeySubLeagues.contains(candidate) && hockeySubLeagues.contains(eventFamily) { return true }

        return false
    }

    // MARK: Numbered Event Slot Detection

    // Patterns: league-prefix + optional "GAME" + 1–3 digit number
    // e.g. "NCAAF 37", "NBA 14", "NHL GAME 07", "DAZN 23", "ESPN+ 449"
    private static let numberedSlotPattern: NSRegularExpression = try! NSRegularExpression(
        pattern: #"\b(NCAAF|NCAAM|NCAAW|NFL|CFL|UFL|NBA|WNBA|NHL|AHL|MLB|MLS|TENNIS|ATP|WTA|F1|NASCAR|INDYCAR|GOLF|PGA|LPGA|UFC|BOXING|DAZN|ESPN\s*\+?|FLO)\s*(GAME\s+)?\d{1,3}\b"#,
        options: .caseInsensitive
    )

    /// Returns `true` when `channelName` is a numbered event bank slot.
    /// Numbered slots are POSSIBLE candidates only — they cannot be confirmed
    /// without current EPG or dynamic event metadata.
    static func isNumberedEventSlot(_ channelName: String) -> Bool {
        let range = NSRange(channelName.startIndex..., in: channelName)
        return numberedSlotPattern.firstMatch(in: channelName, range: range) != nil
    }
}
