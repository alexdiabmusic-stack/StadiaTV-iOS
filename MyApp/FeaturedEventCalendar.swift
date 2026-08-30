import Foundation

/// A single featured event from the demand calendar workbook.
struct FeaturedEventPick: Identifiable, Hashable {
    let dateKey: String
    let timeWindow: String
    let sport: String
    let league: String
    let title: String
    let demandScore: Double
    let tier: String
    let confidence: String
    let scheduleStatus: String
    let reason: String
    let backupTime: String
    let backupLeague: String
    let backupTitle: String
    let recheckRule: String
    let source: String

    var id: String { "\(dateKey)-\(timeWindow)-\(league)-\(title)" }
    var torontoTime: String { timeWindow }
    var hasKnownStartTime: Bool { !timeWindow.isEmpty && !timeWindow.localizedCaseInsensitiveContains("TBD") }
    nonisolated var startDate: Date? { FeaturedEventCalendar.dateRange(dateKey: dateKey, timeWindow: timeWindow)?.start }
    nonisolated var endDate: Date? { FeaturedEventCalendar.dateRange(dateKey: dateKey, timeWindow: timeWindow)?.end }

    var isMultiParticipantSport: Bool {
        switch sportGroup {
        case .golf, .racing, .cycling, .tennis, .wrestling, .esports: return true
        default: return false
        }
    }

    var isTeamMatchup: Bool {
        guard !isMultiParticipantSport else { return false }
        let t = title.replacingOccurrences(of: " - ", with: " ")
        return [" at ", " vs ", " v "].contains { sep in
            let parts = t.components(separatedBy: sep)
            guard parts.count == 2 else { return false }
            let a = parts[0].trimmingCharacters(in: .whitespaces)
            let b = parts[1].trimmingCharacters(in: .whitespaces)
            return !a.isEmpty && !b.isEmpty
        }
    }

    var streamMatch: Match {
        let league = matchedLeague ?? fallbackLeague
        let sides = parsedSides
        return Match(
            id: "featured-\(id)",
            league: league,
            date: startDate ?? FeaturedEventCalendar.date(dateKey: dateKey) ?? Date(),
            name: title,
            shortName: league.shortName,
            state: currentState,
            statusDetail: statusDetail,
            home: sides.home,
            away: sides.away,
            broadcasts: [],
            venue: nil
        )
    }

    private var matchedLeague: League? {
        let normalizedLeague = normalized(league)
        return League.all.first { existing in
            normalized(existing.name) == normalizedLeague || normalized(existing.shortName) == normalizedLeague
        }
    }

    private var fallbackLeague: League {
        League(name: league, shortName: league, path: "featured/\(normalized(league).replacingOccurrences(of: " ", with: "-"))", group: sportGroup, keywords: fallbackKeywords)
    }

    private var sportGroup: SportGroup {
        let value = normalized(sport)
        if value.contains("football") { return .football }
        if value.contains("basketball") { return .basketball }
        if value.contains("baseball") { return .baseball }
        if value.contains("hockey") { return .hockey }
        if value.contains("soccer") { return .soccer }
        if value.contains("tennis") { return .tennis }
        if value.contains("golf") { return .golf }
        if value.contains("cycling") { return .cycling }
        if value.contains("wrestling") { return .wrestling }
        if value.contains("esports") { return .esports }
        return .racing
    }

    private var fallbackKeywords: [String] {
        [sport, league]
            .map { normalized($0) }
            .filter { !$0.isEmpty }
    }

    private var parsedSides: (home: TeamSide, away: TeamSide) {
        let separators = [" at ", " vs ", " v "]
        let normalizedTitle = title.replacingOccurrences(of: " - ", with: " ")
        for separator in separators {
            let pieces = normalizedTitle.components(separatedBy: separator)
            guard pieces.count == 2 else { continue }
            let awayName = cleanParticipantName(pieces[0])
            let homeName = cleanParticipantName(pieces[1])
            if !awayName.isEmpty && !homeName.isEmpty {
                return (side(named: homeName, league: matchedLeague ?? fallbackLeague), side(named: awayName, league: matchedLeague ?? fallbackLeague))
            }
        }
        return (side(named: "TBD", league: matchedLeague ?? fallbackLeague), side(named: "TBD", league: matchedLeague ?? fallbackLeague))
    }

    private var currentState: GameState {
        guard startDate != nil else { return .pre }
        let now = Date()
        if let endDate, now >= endDate { return .final }
        return .pre
    }

    private var statusDetail: String {
        switch currentState {
        case .live: return "Live"
        case .final: return "Final"
        case .pre: return hasKnownStartTime ? "\(torontoTime) ET" : scheduleStatus
        }
    }

    private func side(named name: String, league: League) -> TeamSide {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let abbreviation = inferredAbbreviation(for: trimmed, league: league)
        let logoURL = TeamLogoAssetResolver.assetURL(
            leaguePath: league.path,
            abbreviation: abbreviation,
            displayName: trimmed,
            providerTeamID: nil
        )
        return TeamSide(
            displayName: trimmed,
            shortName: shortName(for: trimmed, abbreviation: abbreviation),
            abbreviation: abbreviation ?? "",
            logoURL: logoURL,
            score: nil,
            record: nil,
            isWinner: false,
            teamID: nil,
            canonicalIDString: canonicalTeamID(for: trimmed, league: league)
        )
    }

    private func cleanParticipantName(_ value: String) -> String {
        let dashSeparated = value
            .components(separatedBy: " — ")
            .first?
            .components(separatedBy: " – ")
            .first?
            .components(separatedBy: " - ")
            .first ?? value
        return dashSeparated
            .replacingOccurrences(of: #"(?i)\s+game\s+\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inferredAbbreviation(for displayName: String, league: League) -> String? {
        let key = normalized(displayName)
        switch league.path {
        case "baseball/mlb":
            return Self.mlbTeamAbbreviations[key]
        case "basketball/nba":
            return Self.nbaTeamAbbreviations[key]
        case "football/nfl":
            return Self.nflTeamAbbreviations[key]
        case "hockey/nhl":
            return Self.nhlTeamAbbreviations[key]
        default:
            return nil
        }
    }

    private func shortName(for displayName: String, abbreviation: String?) -> String {
        if let abbreviation, !abbreviation.isEmpty { return abbreviation }
        return displayName
    }

    private func canonicalTeamID(for displayName: String, league: League) -> String {
        let slug = normalized(displayName).replacingOccurrences(of: " ", with: "-")
        return "stadia:\(league.stadiaKey):team:\(slug)"
    }

    private func normalized(_ value: String) -> String {
        String(value
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let mlbTeamAbbreviations: [String: String] = [
        "arizona diamondbacks": "ARI", "athletics": "ATH", "oakland athletics": "OAK",
        "atlanta braves": "ATL", "baltimore orioles": "BAL", "boston red sox": "BOS",
        "chicago cubs": "CHC", "chicago white sox": "CWS", "cincinnati reds": "CIN",
        "cleveland guardians": "CLE", "colorado rockies": "COL", "detroit tigers": "DET",
        "houston astros": "HOU", "kansas city royals": "KC", "los angeles angels": "LAA",
        "los angeles dodgers": "LAD", "miami marlins": "MIA", "milwaukee brewers": "MIL",
        "minnesota twins": "MIN", "new york mets": "NYM", "new york yankees": "NYY",
        "philadelphia phillies": "PHI", "pittsburgh pirates": "PIT", "san diego padres": "SD",
        "san francisco giants": "SF", "seattle mariners": "SEA", "st louis cardinals": "STL",
        "st. louis cardinals": "STL", "tampa bay rays": "TB", "texas rangers": "TEX",
        "toronto blue jays": "TOR", "washington nationals": "WSH"
    ]

    private static let nbaTeamAbbreviations: [String: String] = [
        "atlanta hawks": "ATL", "boston celtics": "BOS", "brooklyn nets": "BKN",
        "charlotte hornets": "CHA", "chicago bulls": "CHI", "cleveland cavaliers": "CLE",
        "dallas mavericks": "DAL", "denver nuggets": "DEN", "detroit pistons": "DET",
        "golden state warriors": "GSW", "houston rockets": "HOU", "indiana pacers": "IND",
        "la clippers": "LAC", "los angeles clippers": "LAC", "los angeles lakers": "LAL",
        "memphis grizzlies": "MEM", "miami heat": "MIA", "milwaukee bucks": "MIL",
        "minnesota timberwolves": "MIN", "new orleans pelicans": "NOP", "new york knicks": "NYK",
        "oklahoma city thunder": "OKC", "orlando magic": "ORL", "philadelphia 76ers": "PHI",
        "phoenix suns": "PHX", "portland trail blazers": "POR", "sacramento kings": "SAC",
        "san antonio spurs": "SAS", "toronto raptors": "TOR", "utah jazz": "UTA",
        "washington wizards": "WAS"
    ]

    private static let nflTeamAbbreviations: [String: String] = [
        "arizona cardinals": "ARI", "atlanta falcons": "ATL", "baltimore ravens": "BAL",
        "buffalo bills": "BUF", "carolina panthers": "CAR", "chicago bears": "CHI",
        "cincinnati bengals": "CIN", "cleveland browns": "CLE", "dallas cowboys": "DAL",
        "denver broncos": "DEN", "detroit lions": "DET", "green bay packers": "GB",
        "houston texans": "HOU", "indianapolis colts": "IND", "jacksonville jaguars": "JAX",
        "kansas city chiefs": "KC", "las vegas raiders": "LV", "los angeles chargers": "LAC",
        "los angeles rams": "LAR", "miami dolphins": "MIA", "minnesota vikings": "MIN",
        "new england patriots": "NE", "new orleans saints": "NO", "new york giants": "NYG",
        "new york jets": "NYJ", "philadelphia eagles": "PHI", "pittsburgh steelers": "PIT",
        "san francisco 49ers": "SF", "seattle seahawks": "SEA", "tampa bay buccaneers": "TB",
        "tennessee titans": "TEN", "washington commanders": "WAS"
    ]

    private static let nhlTeamAbbreviations: [String: String] = [
        "anaheim ducks": "ANA", "boston bruins": "BOS", "buffalo sabres": "BUF",
        "calgary flames": "CGY", "carolina hurricanes": "CAR", "chicago blackhawks": "CHI",
        "colorado avalanche": "COL", "columbus blue jackets": "CBJ", "dallas stars": "DAL",
        "detroit red wings": "DET", "edmonton oilers": "EDM", "florida panthers": "FLA",
        "los angeles kings": "LAK", "minnesota wild": "MIN", "montreal canadiens": "MTL",
        "nashville predators": "NSH", "new jersey devils": "NJD", "new york islanders": "NYI",
        "new york rangers": "NYR", "ottawa senators": "OTT", "philadelphia flyers": "PHI",
        "pittsburgh penguins": "PIT", "san jose sharks": "SJS", "seattle kraken": "SEA",
        "st louis blues": "STL", "st. louis blues": "STL", "tampa bay lightning": "TBL",
        "toronto maple leafs": "TOR", "utah mammoth": "UTA", "utah hockey club": "UTA",
        "vancouver canucks": "VAN", "vegas golden knights": "VGK", "washington capitals": "WSH",
        "winnipeg jets": "WPG"
    ]
}

/// In-app projection of the Daily Picks sheet from the sports demand workbook.
struct FeaturedEventCalendar {
    static let shared = FeaturedEventCalendar()

    private let picksByDate: [String: [FeaturedEventPick]]
    private let orderedPicks: [FeaturedEventPick]

    private init() {
        var parsed: [String: [FeaturedEventPick]] = [:]
        for line in Self.rawData.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 15, let demandScore = Double(fields[5]) else { continue }
            let pick = FeaturedEventPick(
                dateKey: fields[0],
                timeWindow: fields[1],
                sport: fields[2],
                league: fields[3],
                title: fields[4],
                demandScore: demandScore,
                tier: fields[6],
                confidence: fields[7],
                scheduleStatus: fields[8],
                reason: fields[9],
                backupTime: fields[10],
                backupLeague: fields[11],
                backupTitle: fields[12],
                recheckRule: fields[13],
                source: fields[14]
            )
            parsed[pick.dateKey, default: []].append(pick)
        }
        picksByDate = parsed.mapValues(Self.nonOverlapping)
        orderedPicks = picksByDate.values.flatMap { $0 }.sorted { lhs, rhs in
            (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        }
    }

    func pick(for date: Date = Date()) -> FeaturedEventPick? {
        picks(for: date).first
    }

    func picks(for date: Date = Date()) -> [FeaturedEventPick] {
        let dateKey = Self.dateKeyFormatter.string(from: date)
        if let picks = picksByDate[dateKey], !picks.isEmpty {
            return picks
        }
        guard let nextDateKey = picksByDate.keys.sorted().first(where: { $0 >= dateKey }) else { return [] }
        return picksByDate[nextDateKey] ?? []
    }

    func matchingPick(for match: Match) -> FeaturedEventPick? {
        matchingPicks(for: match).first
    }

    func matchingPicks(for match: Match) -> [FeaturedEventPick] {
        let dateKey = Self.dateKeyFormatter.string(from: match.date)
        return (picksByDate[dateKey] ?? []).filter { $0.matches(match) }
    }

    func demandBoost(for match: Match) -> Int {
        let dateKey = Self.dateKeyFormatter.string(from: match.date)
        guard let picks = picksByDate[dateKey] else { return 0 }
        if let exact = picks.first(where: { $0.matches(match) }) {
            return 1_000 + Int(exact.demandScore.rounded())
        }
        if let sameLeague = picks.first(where: { $0.isSameLeague(as: match) }) {
            return Int(sameLeague.demandScore.rounded())
        }
        return 0
    }

    nonisolated static func date(dateKey: String) -> Date? {
        let dateParts = dateKey.split(separator: "-").compactMap { Int(String($0)) }
        guard dateParts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = torontoTimeZone
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        return components.date
    }

    nonisolated static func dateRange(dateKey: String, timeWindow: String) -> (start: Date, end: Date)? {
        let cleaned = timeWindow.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.localizedCaseInsensitiveContains("TBD") else { return nil }
        let parts = cleaned.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let start = parseTime(parts.first ?? cleaned, dateKey: dateKey, fallbackMeridiem: meridiem(in: parts.dropFirst().first)) else { return nil }
        guard parts.count > 1, let end = parseTime(parts[1], dateKey: dateKey, fallbackMeridiem: meridiem(in: parts.first)) else {
            return (start, start.addingTimeInterval(3 * 60 * 60))
        }
        let adjustedEnd = end <= start ? end.addingTimeInterval(24 * 60 * 60) : end
        return (start, adjustedEnd)
    }

    nonisolated private static func nonOverlapping(_ picks: [FeaturedEventPick]) -> [FeaturedEventPick] {
        let sorted = picks.sorted { lhs, rhs in
            (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
        }
        var selected: [FeaturedEventPick] = []
        for pick in sorted {
            guard let range = dateRange(dateKey: pick.dateKey, timeWindow: pick.timeWindow) else {
                selected.append(pick)
                continue
            }
            while let last = selected.last,
                  let lastRange = dateRange(dateKey: last.dateKey, timeWindow: last.timeWindow),
                  range.start < lastRange.end && range.end > lastRange.start {
                if pick.demandScore > last.demandScore {
                    selected.removeLast()
                } else {
                    break
                }
            }
            if let last = selected.last,
               let lastRange = dateRange(dateKey: last.dateKey, timeWindow: last.timeWindow),
               range.start < lastRange.end && range.end > lastRange.start {
                continue
            }
            selected.append(pick)
        }
        return selected
    }

    nonisolated private static func parseTime(_ value: String, dateKey: String, fallbackMeridiem: String?) -> Date? {
        var text = value.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if meridiem(in: text) == nil, let fallbackMeridiem {
            text += " \(fallbackMeridiem)"
        }

        let dateParts = dateKey.split(separator: "-").compactMap { Int(String($0)) }
        let timeParts = text.split(separator: " ")
        guard dateParts.count == 3,
              let clock = timeParts.first,
              let marker = timeParts.last?.uppercased(),
              marker == "AM" || marker == "PM" else { return nil }

        let clockParts = clock.split(separator: ":").compactMap { Int(String($0)) }
        guard clockParts.count == 2 else { return nil }
        var hour = clockParts[0] % 12
        if marker == "PM" { hour += 12 }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        components.year = dateParts[0]
        components.month = dateParts[1]
        components.day = dateParts[2]
        components.hour = hour
        components.minute = clockParts[1]
        return components.date
    }

    nonisolated private static func meridiem(in value: String?) -> String? {
        guard let uppercased = value?.uppercased() else { return nil }
        if uppercased.contains("AM") { return "AM" }
        if uppercased.contains("PM") { return "PM" }
        return nil
    }

    nonisolated static let torontoTimeZone = TimeZone(identifier: "America/Toronto") ?? .current
    private static let defaultDuration: TimeInterval = 3 * 60 * 60

    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = torontoTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = torontoTimeZone
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        return formatter
    }()

    private static let rawData = """
2026-08-05	6:30 AM-9:00 AM	Cricket	The Hundred	Manchester Super Giants vs Welsh Fire — Women	62	C	High	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	8:00 AM-12:00 PM	Tour de France Femmes	Tour de France Femmes — Stage 5	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-05	10:00 AM-12:30 PM	Cricket	The Hundred	Manchester Super Giants vs Welsh Fire — Men	68	C	High	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-05	2:20 PM-5:35 PM	Baseball	MLB	Los Angeles Dodgers at Chicago Cubs	75	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-05	7:30 PM-9:45 PM	Soccer	Leagues Cup	Inter Miami CF vs Atlético de San Luis	84	A	High	Confirmed matchup and kickoff	Inter Miami supplies the competition's strongest demand signal.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session	Confirm star availability near matchday.	https://www.leaguescup.com/schedule/
2026-08-05	10:00 PM-12:15 AM	Soccer	Leagues Cup	Toluca vs Seattle Sounders FC	73	B	High	Confirmed matchup and kickoff	A Liga MX–MLS matchup extends the late-night slate.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session		https://www.leaguescup.com/schedule/
2026-08-06	8:00 AM-12:00 PM	Cycling	Tour de France Femmes	Tour de France Femmes — Stage 6	75	B	Medium	Official race date; Toronto broadcast window estimated	The premier women's stage race supplies a strong morning block.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm daily stage start/finish timetable.	https://www.letourfemmes.fr/en/overall-route
2026-08-06	1:00 PM-6:00 PM	Golf	PGA Tour	Wyndham Championship — featured coverage	72	B	Medium	Tournament dates confirmed; broadcast window estimated	A major PGA Tour stop supplies a long daytime viewing block.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm tee times, weather and final broadcast window.	https://www.pgatour.com/schedule/2026
2026-08-06	7:00 PM-9:15 PM	Basketball	WNBA	Las Vegas Aces at Indiana Fever	78	B	Medium	Matchup reported; verify official game time	A top WNBA matchup gives the slate a high-quality basketball option.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session	Verify the official matchup, start time and player availability.	https://www.wnba.com/schedule
2026-08-06	10:00 PM-12:15 AM	Soccer	Leagues Cup	Club América vs San Diego FC	78	B	High	Confirmed matchup and kickoff	Club América carries one of the competition's largest fanbases.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session		https://www.leaguescup.com/schedule/
2026-08-07	8:00 AM-12:00 PM	Cycling	Tour de France Femmes	Tour de France Femmes — Stage 7	77	B	Medium	Official race date; Toronto broadcast window estimated	The premier women's stage race supplies a strong morning block.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm daily stage start/finish timetable.	https://www.letourfemmes.fr/en/overall-route
2026-08-07	1:00 PM-6:00 PM	Golf	PGA Tour	Wyndham Championship — featured coverage	72	B	Medium	Tournament dates confirmed; broadcast window estimated	A major PGA Tour stop supplies a long daytime viewing block.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm tee times, weather and final broadcast window.	https://www.pgatour.com/schedule/2026
2026-08-07	7:00 PM-9:15 PM	Soccer	NWSL	Houston Dash vs Kansas City Current	70	B	Medium	Official league date; exact selection/time requires final schedule check	Adds a major North American soccer option outside the European and Leagues Cup windows.	7:05 PM-10:20 PM	MLB	Atlanta Braves at New York Yankees	Replace generic row with the highest-demand confirmed fixture.	https://www.nwslsoccer.com/schedule
2026-08-07	10:15 PM-1:30 AM	Baseball	MLB	Detroit Tigers at San Francisco Giants	65	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:05 PM-10:20 PM	MLB	Atlanta Braves at New York Yankees	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-08	6:00 AM-8:30 AM	Cricket	The Hundred	MI London vs Trent Rockets — Women	62	C	High	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	8:00 AM-12:00 PM	Tour de France Femmes	Tour de France Femmes — Stage 8 — mountain stage	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-08	10:00 AM-11:00 AM	Motorsport	MotoGP	British MotoGP Sprint	80	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	8:00 AM-12:00 PM	Tour de France Femmes	Tour de France Femmes — Stage 8 — mountain stage	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-08-08	3:05 PM-6:20 PM	Baseball	MLB	Atlanta Braves at New York Yankees	80	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-08	7:30 PM-9:45 PM	Soccer	Leagues Cup	Inter Miami CF vs Monterrey	87	A	Medium	Matchup confirmed; kickoff to verify	Inter Miami against a major Liga MX club is one of Phase One's clearest demand leaders.	8:00 PM-1:00 AM	UFC	UFC Fight Night: Gamrot vs Salkilld	Confirm exact kickoff and star availability.	https://www.leaguescup.com/schedule/
2026-08-09	8:00 AM-10:00 AM	Motorsport	MotoGP	British MotoGP	85	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	8:00 AM-12:00 PM	Tour de France Femmes	Tour de France Femmes — Final stage	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-08-09	1:00 PM-3:30 PM	Cricket	The Hundred	London Spirit vs Birmingham Phoenix — Men	69	C	High	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	1:35 PM-4:50 PM	MLB	Atlanta Braves at New York Yankees	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-09	4:00 PM-6:30 PM	Motorsport	INDYCAR	Grand Prix of Portland	76	B	High	Confirmed race start; end time estimated	INDYCAR provides a high-quality Sunday afternoon alternative.	1:35 PM-4:50 PM	MLB	Atlanta Braves at New York Yankees	Check for weather and caution-related delays.	https://www.indycar.com/Schedule
2026-08-09	7:00 PM-11:00 PM	Tennis	WTA 1000 Toronto	National Bank Open — featured night session	77	B	Medium	Tournament schedule confirmed; individual matchup/order pending	A top-player night-session match can outrank routine baseball depending on the draw.	8:20 PM-11:35 PM	MLB	Houston Astros at San Diego Padres	Replace with the highest-demand confirmed night match and adjust for actual court duration.	https://nationalbankopen.com/
2026-08-10	5:45 AM-1:00 PM	Cricket	Ireland vs Afghanistan	Ireland vs Afghanistan — ODI	73	B	Medium	Official match date; Toronto duration estimated	An international ODI fills the early-morning through midday window.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm toss/start and weather.	https://www.cricketireland.ie/
2026-08-10	1:30 PM-4:00 PM	Cricket	The Hundred	Trent Rockets vs Southern Brave — Men	70	B	High	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-10	7:00 PM-11:00 PM	Tennis	WTA 1000 Toronto	National Bank Open — featured night session	77	B	Medium	Tournament schedule confirmed; individual matchup/order pending	A top-player night-session match can outrank routine baseball depending on the draw.	7:07 PM-10:22 PM	MLB	Boston Red Sox at Toronto Blue Jays	Replace with the highest-demand confirmed night match and adjust for actual court duration.	https://nationalbankopen.com/
2026-08-11	12:00 PM-3:00 PM	Swimming	European Aquatics Championships	European Aquatics Championships — featured finals session	68	C	Medium	Official championship dates; finals session estimated	Continental championship swimming adds a concise afternoon block.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm official daily session timetable.	https://www.worldaquatics.com/competitions
2026-08-11	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League qualifying round — featured match TBD	80	A	Low	Round date confirmed; matchup and kickoff selection pending	The highest-profile European qualifier can lead the afternoon window.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Replace with the biggest confirmed pairing and kickoff.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-08-11	7:00 PM-11:00 PM	Tennis	WTA 1000 Toronto	National Bank Open — featured night session	77	B	Medium	Tournament schedule confirmed; individual matchup/order pending	A top-player night-session match can outrank routine baseball depending on the draw.	10:00 PM-12:15 AM	Leagues Cup	Tigres UANL vs Vancouver Whitecaps FC	Replace with the highest-demand confirmed night match and adjust for actual court duration.	https://nationalbankopen.com/
2026-08-12	5:45 AM-1:00 PM	Cricket	Ireland vs Afghanistan	Ireland vs Afghanistan — ODI	73	B	Medium	Official match date; Toronto duration estimated	An international ODI fills the early-morning through midday window.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session	Confirm toss/start and weather.	https://www.cricketireland.ie/
2026-08-12	3:00 PM-5:30 PM	Soccer	UEFA Super Cup	Paris Saint-Germain vs Aston Villa	92	S	High	Confirmed matchup and kickoff	A standalone UEFA trophy match should lead global afternoon demand.	11:00 AM-5:00 PM	WTA 1000 Toronto	National Bank Open — featured day session		https://www.uefa.com/uefasupercup/
2026-08-12	7:30 PM-9:45 PM	Soccer	Leagues Cup	Inter Miami CF vs Club León	85	A	Medium	Matchup confirmed; kickoff to verify	Inter Miami again provides the strongest likely audience in Phase One.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session	Confirm exact kickoff and star availability.	https://www.leaguescup.com/schedule/
2026-08-12	10:00 PM-12:15 AM	Soccer	Leagues Cup	Toluca vs FC Dallas	74	B	High	Confirmed matchup/window	A late Liga MX–MLS matchup extends the day.	7:00 PM-11:00 PM	WTA 1000 Toronto	National Bank Open — featured night session		https://www.leaguescup.com/schedule/
2026-08-13	9:00 AM-3:00 PM	Golf	LPGA	Portland Classic — featured coverage	69	C	Medium	Tournament dates confirmed; broadcast window estimated	A significant LPGA event fills the morning and early afternoon.	1:00 PM-6:00 PM	PGA Tour	FedEx St. Jude Championship — featured coverage	Confirm tee times and official broadcast window.	https://www.lpga.com/tournaments
2026-08-13	3:30 PM-5:30 PM	Tennis	WTA 1000 Toronto	National Bank Open — doubles final	72	B	Medium	Final-day window confirmed; participants pending	Championship tennis provides a meaningful afternoon lead-in.	1:00 PM-6:00 PM	PGA Tour	FedEx St. Jude Championship — featured coverage	Confirm finalists and exact court start.	https://nationalbankopen.com/
2026-08-13	6:00 PM-8:30 PM	Tennis	WTA 1000 Toronto	National Bank Open — singles final	88	A	Medium	Final scheduled no earlier than 6:00 PM; participants pending	The Toronto WTA 1000 singles championship should be one of the day's highest-demand Canadian events.	3:07 PM-6:22 PM	MLB	Boston Red Sox at Toronto Blue Jays	Confirm finalists and actual court start.	https://nationalbankopen.com/
2026-08-13	10:10 PM-1:25 AM	Baseball	MLB	Milwaukee Brewers at Los Angeles Dodgers	73	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	8:00 PM-11:15 PM	NFL Preseason	NFL preseason — top Thursday matchup	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-14	9:15 AM-11:45 AM	Cricket	The Hundred	The Hundred — women's Eliminator	72	B	Medium	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (early rounds; players TBD)	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-14	1:00 PM-6:00 PM	Golf	PGA Tour	FedEx St. Jude Championship — featured coverage	79	B	Medium	Tournament dates confirmed; broadcast window estimated	A major PGA Tour stop supplies a long daytime viewing block.	2:20 PM-5:35 PM	MLB	St. Louis Cardinals at Chicago Cubs	Confirm tee times, weather and final broadcast window.	https://www.pgatour.com/schedule/2026
2026-08-14	7:15 PM-10:30 PM	Baseball	MLB	New York Yankees at Toronto Blue Jays	82	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	Cincinnati Open	Cincinnati Open — featured night session (early rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-15	12:30 AM-8:30 AM	Cricket	International Cricket	India vs Sri Lanka — Test, Day 1	75	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	5:45 AM-1:00 PM	Ireland vs Afghanistan	Ireland vs Afghanistan — ODI	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-15	9:00 AM-3:00 PM	Golf	LPGA	Portland Classic — featured coverage	69	C	Medium	Tournament dates confirmed; broadcast window estimated	A significant LPGA event fills the morning and early afternoon.	12:30 PM-6:00 PM	Woodbine Racing	King's Plate Day at Woodbine	Confirm tee times and official broadcast window.	https://www.lpga.com/tournaments
2026-08-15	3:07 PM-6:22 PM	Baseball	MLB	New York Yankees at Toronto Blue Jays	82	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	12:30 PM-6:00 PM	Woodbine Racing	King's Plate Day at Woodbine	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-15	7:00 PM-10:00 PM	Swimming	Pan Pacific Swimming Championships	Pan Pacific Championships — featured finals session	77	B	Medium	Official championship dates; finals session estimated	A major international swimming meet in North America supplies an evening finals block.	9:00 PM-1:00 AM	UFC	UFC 330: Makhachev vs Machado Garry	Confirm official final-session time.	https://www.worldaquatics.com/competitions
2026-08-16	12:30 AM-8:30 AM	Cricket	International Cricket	India vs Sri Lanka — Test, Day 2	75	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	9:00 PM-1:00 AM	UFC	UFC 330: Makhachev vs Machado Garry	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-16	9:15 AM-11:45 AM	Cricket	The Hundred	The Hundred — women's Final	78	B	Medium	Official fixture/session time; end time estimated	Short-format cricket adds a compact, globally relevant daytime option.	9:00 AM-3:00 PM	LPGA	Portland Classic — final-day coverage	Confirm finalists for knockout rows.	https://www.thehundred.com/fixtures
2026-08-16	12:00 PM-2:30 PM	Motorsport	INDYCAR	Markham Grand Prix	81	A	High	Confirmed race start; end time estimated	The Ontario event receives additional Canadian demand.	12:00 PM-6:00 PM	PGA Tour	FedEx St. Jude Championship — final-round featured coverage	Check for weather and caution-related delays.	https://www.indycar.com/Schedule
2026-08-16	3:00 PM-5:15 PM	Soccer	LaLiga	FC Barcelona vs Athletic Club	84	A	Medium	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	12:00 PM-6:00 PM	PGA Tour	FedEx St. Jude Championship — final-round featured coverage	Confirm kickoff where the league has not yet assigned a broadcast time.	https://www.laliga.com/calendar-2026-2027/laliga-easports
2026-08-16	7:00 PM-11:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured night session (early rounds; players TBD)	75	B	Medium	Tournament date confirmed; daily order of play pending	The top night-session match may exceed routine baseball demand depending on players.	7:20 PM-10:35 PM	MLB	Seattle Mariners at Houston Astros	Replace with the top confirmed night matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-17	12:30 AM-8:30 AM	Cricket	International Cricket	India vs Sri Lanka — Test, Day 3	76	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	1:00 AM-8:00 AM	BWF World Championships	BWF World Championships — opening round	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-17	11:00 AM-5:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured day session (early rounds; players TBD)	72	B	Medium	Tournament date confirmed; daily order of play pending	The highest-profile daytime match offers a long live viewing block.	1:40 PM-4:55 PM	MLB	St. Louis Cardinals at Cincinnati Reds	Replace with the top confirmed matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-17	7:00 PM-11:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured night session (early rounds; players TBD)	75	B	Medium	Tournament date confirmed; daily order of play pending	The top night-session match may exceed routine baseball demand depending on players.	8:40 PM-11:55 PM	MLB	Los Angeles Dodgers at Colorado Rockies	Replace with the top confirmed night matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-18	12:30 AM-8:30 AM	Cricket	International Cricket	India vs Sri Lanka — Test, Day 4	77	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	1:00 AM-8:00 AM	BWF World Championships	BWF World Championships — early rounds	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-18	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League playoff round — featured match TBD	84	A	Low	Round date confirmed; matchup and kickoff selection pending	The highest-profile European qualifier can lead the afternoon window.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (early rounds; players TBD)	Replace with the biggest confirmed pairing and kickoff.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-08-18	6:35 PM-9:50 PM	Baseball	MLB	New York Yankees at Baltimore Orioles	76	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	Cincinnati Open	Cincinnati Open — featured night session (early rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-19	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Pakistan — Test, Day 1	79	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (quarterfinals; players TBD)	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-19	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League playoff round — featured match TBD	84	A	Low	Round date confirmed; matchup and kickoff selection pending	The highest-profile European qualifier can lead the afternoon window.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (quarterfinals; players TBD)	Replace with the biggest confirmed pairing and kickoff.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-08-19	7:00 PM-11:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured night session (quarterfinals; players TBD)	81	A	Medium	Tournament date confirmed; daily order of play pending	The top night-session match may exceed routine baseball demand depending on players.	6:35 PM-9:50 PM	MLB	New York Yankees at Baltimore Orioles	Replace with the top confirmed night matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-20	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Pakistan — Test, Day 2	79	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (quarterfinals; players TBD)	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-20	1:00 PM-6:00 PM	Golf	PGA Tour	BMW Championship — featured coverage	81	A	Medium	Tournament dates confirmed; broadcast window estimated	A major PGA Tour stop supplies a long daytime viewing block.	11:00 AM-5:00 PM	Cincinnati Open	Cincinnati Open — featured day session (quarterfinals; players TBD)	Confirm tee times, weather and final broadcast window.	https://www.pgatour.com/schedule/2026
2026-08-20	7:00 PM-11:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured night session (quarterfinals; players TBD)	81	A	Medium	Tournament date confirmed; daily order of play pending	The top night-session match may exceed routine baseball demand depending on players.	6:35 PM-9:50 PM	MLB	New York Yankees at Baltimore Orioles	Replace with the top confirmed night matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-21	1:00 AM-8:00 AM	Badminton	BWF World Championships	BWF World Championships — quarterfinals	77	B	Medium	Official tournament date; Toronto session window estimated	The sport's world championship provides high-level overnight and early-morning competition.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Test, Day 3	Confirm court schedule and finalists.	https://badmintonworldtour.com/events/month/2026-08/
2026-08-21	9:00 AM-3:00 PM	Golf	LPGA	CPKC Women's Open — featured coverage	78	B	Medium	Tournament dates confirmed; broadcast window estimated	A significant LPGA event fills the morning and early afternoon.	1:00 PM-6:00 PM	PGA Tour	BMW Championship — featured coverage	Confirm tee times and official broadcast window.	https://www.lpga.com/tournaments
2026-08-21	3:00 PM-5:15 PM	Soccer	Premier League	Coventry City vs Arsenal	82	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	1:00 PM-6:00 PM	PGA Tour	BMW Championship — featured coverage	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-21	8:00 PM-10:00 PM	Pro Wrestling	WWE SmackDown	WWE SmackDown — Toronto	78	B	High	Official event date; end time estimated	Combat-sport and wrestling cards can produce concentrated evening demand driven by headliners.	7:05 PM-10:20 PM	MLB	Toronto Blue Jays at New York Yankees	Confirm final card, cancellations and broadcast start.	https://www.wwe.com/events
2026-08-21	10:10 PM-1:25 AM	Baseball	MLB	Chicago Cubs at Seattle Mariners	69	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:05 PM-10:20 PM	MLB	Toronto Blue Jays at New York Yankees	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-22	6:00 AM-7:00 AM	Motorsport	Formula 1	Dutch Grand Prix — sprint	82	A	High	Race date confirmed; end time estimated	Formula 1 provides a concentrated high-demand international viewing window.	1:00 AM-8:00 AM	BWF World Championships	BWF World Championships — semifinals	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-08-22	7:30 AM-9:45 AM	Soccer	Premier League	Manchester United at Hull City	84	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	1:00 AM-8:00 AM	BWF World Championships	BWF World Championships — semifinals	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-22	10:00 AM-11:15 AM	Motorsport	Formula 1	Dutch Grand Prix — qualifying	82	A	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Test, Day 4	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-08-22	12:30 PM-2:45 PM	Soccer	Bundesliga	Borussia Dortmund vs Bayern Munich	94	S	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	1:30 PM-3:45 PM	LaLiga	RCD Espanyol vs Real Madrid		https://www.bundesliga.com/en/bundesliga/matchday/2026-2027/fc-bayern-muenchen
2026-08-22	2:45 PM-5:00 PM	Soccer	Ligue 1	Paris Saint-Germain vs Rennes	85	A	Medium	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	1:30 PM-3:45 PM	LaLiga	RCD Espanyol vs Real Madrid	Confirm kickoff where the league has not yet assigned a broadcast time.	https://ligue1.com/en/articles/l1_article_5292-the-2026-27-ligue-1-mc-donald-s-calendar-is-released
2026-08-22	7:00 PM-11:00 PM	Tennis	Cincinnati Open	Cincinnati Open — featured night session (semifinals; players TBD)	81	A	Medium	Tournament date confirmed; daily order of play pending	The top night-session match may exceed routine baseball demand depending on players.	5:00 PM-10:00 PM	UFC	UFC Fight Night: Hernandez vs Rodrigues	Replace with the top confirmed night matchup after the order of play is released.	https://cincinnatiopen.com/
2026-08-23	1:00 AM-8:00 AM	Badminton	BWF World Championships	BWF World Championships — finals	85	A	Medium	Official tournament date; Toronto session window estimated	The sport's world championship provides high-level overnight and early-morning competition.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Test, Day 5	Confirm court schedule and finalists.	https://badmintonworldtour.com/events/month/2026-08/
2026-08-23	9:00 AM-11:15 AM	Motorsport	Formula 1	Dutch Grand Prix	88	A	High	Race date confirmed; end time estimated	Formula 1 provides a concentrated high-demand international viewing window.	9:00 AM-11:15 AM	Premier League	Bournemouth at Manchester City	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-08-23	11:30 AM-1:45 PM	Soccer	Premier League	Liverpool at Newcastle United	88	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	12:00 PM-6:00 PM	PGA Tour	BMW Championship — final-round featured coverage	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-23	2:45 PM-5:00 PM	Soccer	Serie A	AC Milan at Torino	80	A	Medium	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	12:00 PM-6:00 PM	PGA Tour	BMW Championship — final-round featured coverage	Confirm kickoff where the league has not yet assigned a broadcast time.	https://en.legaseriea.it/serie-a/news/looking-forward-to-the-2026-27-serie-a-fixture-list
2026-08-23	7:00 PM-9:30 PM	Tennis	Cincinnati Open	Cincinnati Open — championship final (players TBD)	87	A	Medium	Final date and evening window confirmed; participants pending	A WTA 1000 championship final is one of the day's strongest live events.	7:10 PM-10:25 PM	MLB	Atlanta Braves at Milwaukee Brewers	Confirm finalists and exact court start.	https://cincinnatiopen.com/
2026-08-24	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 3	71	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	11:00 AM-5:00 PM	US Open	US Open Fan Week / qualifying — featured courts	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-08-24	3:00 PM-5:15 PM	Soccer	Premier League	Chelsea at Fulham	83	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	11:00 AM-5:00 PM	US Open	US Open Fan Week / qualifying — featured courts	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-24	8:00 PM-11:00 PM	Pro Wrestling	WWE Raw	WWE Raw — Ottawa	77	B	High	Official event date; end time estimated	Combat-sport and wrestling cards can produce concentrated evening demand driven by headliners.	9:40 PM-12:55 AM	MLB	Philadelphia Phillies at Seattle Mariners	Confirm final card, cancellations and broadcast start.	https://www.wwe.com/events
2026-08-25	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 4 — mountain	76	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	11:00 AM-5:00 PM	US Open	US Open Fan Week / qualifying — featured courts	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-08-25	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League playoff round — featured match TBD	84	A	Low	Round date confirmed; matchup and kickoff selection pending	The highest-profile European qualifier can lead the afternoon window.	11:00 AM-5:00 PM	US Open	US Open Fan Week / qualifying — featured courts	Replace with the biggest confirmed pairing and kickoff.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-08-25	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup quarterfinal — highest-demand matchup TBD	84	A	Low	Quarterfinal date window confirmed; matchup and kickoff pending	The strongest knockout matchup should displace routine regular-season games.	7:15 PM-10:30 PM	MLB	Los Angeles Dodgers at Atlanta Braves	Replace with the confirmed quarterfinal and kickoff after Phase One.	https://www.leaguescup.com/schedule/
2026-08-26	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 5	72	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	11:00 AM-5:00 PM	US Open	US Open Fan Week / qualifying — featured courts	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-08-26	1:00 PM-3:15 PM	Soccer	LaLiga	Real Madrid vs Real Sociedad	84	A	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	3:00 PM-5:15 PM	UEFA Champions League	Champions League playoff round — featured match TBD		https://www.laliga.com/es-CA/clubes/real-madrid/proximos-partidos
2026-08-26	3:40 PM-6:55 PM	Baseball	MLB	Chicago Cubs at Arizona Diamondbacks	68	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	3:00 PM-5:15 PM	UEFA Champions League	Champions League playoff round — featured match TBD	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-26	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup quarterfinal — highest-demand matchup TBD	84	A	Low	Quarterfinal date window confirmed; matchup and kickoff pending	The strongest knockout matchup should displace routine regular-season games.	7:05 PM-10:20 PM	MLB	Houston Astros at New York Yankees	Replace with the confirmed quarterfinal and kickoff after Phase One.	https://www.leaguescup.com/schedule/
2026-08-27	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Pakistan — Lord's Test, Day 1	81	A	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	12:00 PM-2:00 PM	UEFA Champions League	Champions League league-phase draw	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-27	1:00 PM-6:00 PM	Golf	PGA Tour	Tour Championship — featured coverage	85	A	Medium	Tournament dates confirmed; broadcast window estimated	A major PGA Tour stop supplies a long daytime viewing block.	12:00 PM-2:00 PM	UEFA Champions League	Champions League league-phase draw	Confirm tee times, weather and final broadcast window.	https://www.pgatour.com/schedule/2026
2026-08-27	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup quarterfinal — highest-demand matchup TBD	84	A	Low	Quarterfinal date window confirmed; matchup and kickoff pending	The strongest knockout matchup should displace routine regular-season games.	7:05 PM-10:20 PM	MLB	Houston Astros at New York Yankees	Replace with the confirmed quarterfinal and kickoff after Phase One.	https://www.leaguescup.com/schedule/
2026-08-28	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 7 — mountain	77	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Lord's Test, Day 2	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-08-28	12:30 PM-2:45 PM	Soccer	Bundesliga	Bayern Munich vs Stuttgart	85	A	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	1:00 PM-6:00 PM	PGA Tour	Tour Championship — featured coverage		https://www.bundesliga.com/en/bundesliga/matchday/2026-2027/fc-bayern-muenchen
2026-08-28	3:00 PM-5:15 PM	Soccer	Premier League	Manchester City at Crystal Palace	81	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	1:00 PM-6:00 PM	PGA Tour	Tour Championship — featured coverage	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-28	7:00 PM-10:15 PM	American Football	NFL Preseason	NFL preseason — top Friday matchup	72	B	Medium	Date/window confirmed; featured matchup may change	NFL preseason delivers strong North American demand, especially in standalone windows.	7:15 PM-10:30 PM	MLB	Boston Red Sox at New York Yankees	Replace generic slot with the highest-demand confirmed matchup and verify local broadcast.	https://www.nfl.com/news/2026-nfl-preseason-schedule-released
2026-08-28	10:15 PM-1:30 AM	Baseball	MLB	Arizona Diamondbacks at San Francisco Giants	65	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:15 PM-10:30 PM	MLB	Boston Red Sox at New York Yankees	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-29	7:30 AM-9:45 AM	Soccer	Premier League	Nottingham Forest at Liverpool	81	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Lord's Test, Day 3	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-29	10:00 AM-11:00 AM	Motorsport	MotoGP	Aragon MotoGP Sprint	80	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Lord's Test, Day 3	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-08-29	12:30 PM-2:45 PM	Soccer	Premier League	Newcastle United at Tottenham Hotspur	82	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	12:00 PM-6:00 PM	PGA Tour	Tour Championship — featured coverage	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-29	3:30 PM-7:00 PM	American Football	College Football	NC State vs Virginia — Rio de Janeiro	74	B	Medium	Date and matchup confirmed; kickoff window estimated	A major ranked or national-brand college matchup fills a key weekend window.	12:00 PM-6:00 PM	PGA Tour	Tour Championship — featured coverage	Confirm television-selected kickoff and current rankings.	https://www.ncaa.com/news/football/article/2026-college-football-schedule
2026-08-29	7:15 PM-10:30 PM	Baseball	MLB	Boston Red Sox at New York Yankees — Game 2	85	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:30 PM-11:00 PM	NASCAR Cup Series	NASCAR Cup — Daytona	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-08-30	8:00 AM-10:00 AM	Motorsport	MotoGP	Aragon MotoGP	85	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Lord's Test, Day 4	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-08-30	11:30 AM-1:45 PM	Soccer	Premier League	Ipswich Town at Manchester United	82	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	12:00 PM-6:00 PM	PGA Tour	Tour Championship — final-round featured coverage	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-30	2:45 PM-5:00 PM	Soccer	Ligue 1	LOSC Lille vs Paris Saint-Germain	88	A	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	12:00 PM-6:00 PM	PGA Tour	Tour Championship — final-round featured coverage		https://ligue1.com/en/articles/l1_article_5292-the-2026-27-ligue-1-mc-donald-s-calendar-is-released
2026-08-30	7:00 PM-11:00 PM	Tennis	US Open	US Open — featured night session (opening rounds; players TBD)	82	A	Medium	Tournament date confirmed; daily order of play pending	Arthur Ashe night sessions are among the strongest prime-time tennis windows.	7:20 PM-10:35 PM	MLB	Cincinnati Reds at Chicago Cubs	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-08-31	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Pakistan — Lord's Test, Day 5	83	A	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-08-31	3:00 PM-5:15 PM	Soccer	Premier League	Arsenal at Aston Villa	84	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-08-31	7:00 PM-9:30 PM	Basketball	FIBA World Cup Qualifier	Canada men's national team — home qualifier in Quebec City	82	A	Medium	Official home date/location; opponent and tipoff require final confirmation	A Canada senior men's national-team home game carries strong Canadian demand.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Insert opponent and confirmed tipoff.	https://www.basketball.ca/news/canada-to-host-fiba-basketball-world-cup-2027-americas-qualifiers-in-quebec-city
2026-08-31	9:38 PM-12:53 AM	Baseball	MLB	New York Yankees at Los Angeles Angels	73	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-01	11:00 AM-5:00 PM	Tennis	US Open	US Open — featured day session (opening rounds; players TBD)	78	B	Medium	Tournament date confirmed; daily order of play pending	The most prominent day-session match provides a high-demand daytime anchor.	9:00 AM-12:30 PM	Vuelta a España	Vuelta a España — Stage 10	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-01	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup semifinal — highest-demand matchup TBD	87	A	Low	Semifinal date window confirmed; matchup and kickoff pending	The strongest semifinal becomes a prime-time priority.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Replace with the confirmed semifinal and kickoff.	https://www.leaguescup.com/schedule/
2026-09-01	10:10 PM-1:25 AM	Baseball	MLB	St. Louis Cardinals at Los Angeles Dodgers	72	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-02	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 11	71	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-09-02	12:40 PM-3:55 PM	Baseball	MLB	San Diego Padres at Cincinnati Reds	66	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-02	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup semifinal — highest-demand matchup TBD	87	A	Low	Semifinal date window confirmed; matchup and kickoff pending	The strongest semifinal becomes a prime-time priority.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Replace with the confirmed semifinal and kickoff.	https://www.leaguescup.com/schedule/
2026-09-02	10:10 PM-1:25 AM	Baseball	MLB	St. Louis Cardinals at Los Angeles Dodgers	72	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night session (opening rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-03	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 12 — mountain	77	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-09-03	1:10 PM-4:25 PM	Baseball	MLB	Toronto Blue Jays at Cleveland Guardians	70	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	11:00 AM-5:00 PM	US Open	US Open — featured day session (opening rounds; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-03	7:00 PM-11:00 PM	Tennis	US Open	US Open — featured night session (opening rounds; players TBD)	82	A	Medium	Tournament date confirmed; daily order of play pending	Arthur Ashe night sessions are among the strongest prime-time tennis windows.	7:30 PM-11:00 PM	College Football	Colorado at Georgia Tech	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-04	5:30 AM-7:30 AM	Basketball	FIBA Women's World Cup	Japan vs Mali	65	C	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.					https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-04	8:15 AM-10:15 AM	Basketball	FIBA Women's World Cup	United States vs China	85	A	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.	9:00 AM-12:30 PM	Vuelta a España	Vuelta a España — Stage 13		https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-04	11:45 AM-1:45 PM	Basketball	FIBA Women's World Cup	Spain vs Germany	78	B	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.	11:00 AM-5:00 PM	US Open	US Open — featured day session (third/fourth round; players TBD)		https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-04	3:00 PM-5:15 PM	Soccer	Premier League	Liverpool at Ipswich Town	82	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	11:00 AM-5:00 PM	US Open	US Open — featured day session (third/fourth round; players TBD)	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-09-04	7:00 PM-11:00 PM	Tennis	US Open	US Open — featured night session (third/fourth round; players TBD)	86	A	Medium	Tournament date confirmed; daily order of play pending	Arthur Ashe night sessions are among the strongest prime-time tennis windows.	8:00 PM-11:30 PM	College Football	Miami at Stanford	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-05	5:30 AM-7:30 AM	Basketball	FIBA Women's World Cup	Mali vs Spain	66	C	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.					https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-05	7:30 AM-9:45 AM	Soccer	Women's Super League	Chelsea vs Aston Villa	78	B	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	9:00 AM-12:30 PM	Vuelta a España	Vuelta a España — Stage 14 — mountain		https://womensleagues.thefa.com/fixtures/
2026-09-05	10:00 AM-11:15 AM	Motorsport	Formula 1	Italian Grand Prix — qualifying	84	A	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	11:00 AM-5:00 PM	US Open	US Open — featured day session (third/fourth round; players TBD)	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-05	12:30 PM-2:45 PM	Soccer	Bundesliga	Schalke 04 vs Bayern Munich	82	A	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	2:00 PM-7:00 PM	World Championship Boxing	Katie Taylor vs Flora Pili		https://www.bundesliga.com/en/bundesliga/matchday/2026-2027/fc-bayern-muenchen
2026-09-05	3:30 PM-7:00 PM	American Football	College Football	Clemson at LSU	89	A	Medium	Date and matchup confirmed; kickoff window estimated	A major ranked or national-brand college matchup fills a key weekend window.	2:45 PM-5:00 PM	Ligue 1	Paris Saint-Germain vs Monaco	Confirm television-selected kickoff and current rankings.	https://www.ncaa.com/news/football/article/2026-college-football-schedule
2026-09-05	7:00 PM-11:00 PM	Tennis	US Open	US Open — featured night session (third/fourth round; players TBD)	86	A	Medium	Tournament date confirmed; daily order of play pending	Arthur Ashe night sessions are among the strongest prime-time tennis windows.	3:00 PM-8:00 PM	UFC	UFC Paris: Hooker vs Parnasse	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-06	5:30 AM-7:30 AM	Basketball	FIBA Women's World Cup	Türkiye vs Australia	72	B	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.	7:00 AM-9:15 AM	Women's Super League	Brighton vs Arsenal		https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-06	9:00 AM-11:15 AM	Motorsport	Formula 1	Italian Grand Prix	90	S	High	Race date confirmed; end time estimated	Formula 1 provides a concentrated high-demand international viewing window.	9:00 AM-11:15 AM	Premier League	Manchester United at Everton	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-06	11:30 AM-1:45 PM	Soccer	Premier League	Chelsea at Arsenal	91	S	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	12:00 PM-3:30 PM	College Football	Wisconsin vs Notre Dame	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-09-06	2:45 PM-4:45 PM	Basketball	FIBA Women's World Cup	Italy vs United States	86	A	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.	12:00 PM-3:30 PM	College Football	Wisconsin vs Notre Dame		https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-06	7:30 PM-10:00 PM	Soccer	Leagues Cup	Leagues Cup Final	91	S	Low	Final date confirmed; teams/time pending	The cross-border tournament final should lead North American soccer demand.	7:00 PM-11:00 PM	US Open	US Open — featured night session (third/fourth round; players TBD)	Replace with confirmed finalists and kickoff.	https://www.leaguescup.com/schedule/
2026-09-06	10:10 PM-1:25 AM	Baseball	MLB	Washington Nationals at Los Angeles Dodgers	67	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night session (third/fourth round; players TBD)	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-07	5:30 AM-7:30 AM	Basketball	FIBA Women's World Cup	Belgium vs Australia	75	B	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.					https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-07	8:30 AM-10:30 AM	Basketball	FIBA Women's World Cup	Nigeria vs France	74	B	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.					https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-07	11:50 AM-1:50 PM	Basketball	FIBA Women's World Cup	Japan vs Spain	74	B	High	Official group-stage matchup and Toronto-converted start	A senior national-team world championship adds global basketball demand.	11:00 AM-5:00 PM	US Open	US Open — featured day session (third/fourth round; players TBD)		https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-07	2:30 PM-5:30 PM	Canadian Football	CFL	Toronto Argonauts at Hamilton Tiger-Cats	83	A	High	Confirmed kickoff; end time estimated	A nationally relevant CFL matchup strengthens the Canadian evening slate.	11:00 AM-5:00 PM	US Open	US Open — featured day session (third/fourth round; players TBD)	Confirm any broadcast-related schedule adjustment.	https://www.cfl.ca/schedule/2026/
2026-09-07	7:00 PM-11:00 PM	Tennis	US Open	US Open — featured night session (third/fourth round; players TBD)	86	A	Medium	Tournament date confirmed; daily order of play pending	Arthur Ashe night sessions are among the strongest prime-time tennis windows.	8:00 PM-11:30 PM	College Football	SMU at Florida State	Insert the highest-demand confirmed matchup once the order of play is published.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-08	9:00 AM-12:30 PM	Cycling	Vuelta a España	Vuelta a España — Stage 16	73	B	Medium	Official stage date/route; Toronto coverage window estimated	A Grand Tour stage adds substantial European morning demand.	12:00 PM-5:00 PM	US Open	US Open — featured quarterfinal	Confirm the official stage timetable.	https://www.lavuelta.es/en/overall-route
2026-09-08	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League Matchday 1 — highest-demand match TBD	89	A	Low	Matchday dates confirmed; draw and final kickoff pending	The biggest Champions League match should dominate the afternoon.	12:00 PM-5:00 PM	US Open	US Open — featured quarterfinal	Replace with the top confirmed matchup after the league-phase draw.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-09-08	6:40 PM-9:55 PM	Baseball	MLB	Houston Astros at Philadelphia Phillies	72	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night quarterfinal	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-08	10:10 PM-1:25 AM	Baseball	MLB	Cincinnati Reds at Los Angeles Dodgers	68	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night quarterfinal	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-09	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Pakistan — Edgbaston Test, Day 1	80	A	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	12:00 PM-5:00 PM	US Open	US Open — featured quarterfinal	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-09-09	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League Matchday 1 — highest-demand match TBD	89	A	Low	Matchday dates confirmed; draw and final kickoff pending	The biggest Champions League match should dominate the afternoon.	12:00 PM-5:00 PM	US Open	US Open — featured quarterfinal	Replace with the top confirmed matchup after the league-phase draw.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-09-09	6:40 PM-9:55 PM	Baseball	MLB	Houston Astros at Philadelphia Phillies	72	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night quarterfinal	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-09	10:10 PM-1:25 AM	Baseball	MLB	Cincinnati Reds at Los Angeles Dodgers	68	C	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:00 PM-11:00 PM	US Open	US Open — featured night quarterfinal	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-10	5:30 AM-7:45 AM	Basketball	FIBA Women's World Cup	FIBA Women's World Cup — quarterfinal 1	80	A	Medium	Official round/time; teams determined by tournament results	Knockout-stage world championship basketball receives a major stakes boost.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Edgbaston Test, Day 2	Replace with confirmed teams after the preceding round.	https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-10	8:30 AM-10:45 AM	Basketball	FIBA Women's World Cup	FIBA Women's World Cup — quarterfinal 2	82	A	Medium	Official round/time; teams determined by tournament results	Knockout-stage world championship basketball receives a major stakes boost.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Edgbaston Test, Day 2	Replace with confirmed teams after the preceding round.	https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-10	11:45 AM-2:00 PM	Basketball	FIBA Women's World Cup	FIBA Women's World Cup — quarterfinal 3	83	A	Medium	Official round/time; teams determined by tournament results	Knockout-stage world championship basketball receives a major stakes boost.	6:00 AM-1:00 PM	International Cricket	England vs Pakistan — Edgbaston Test, Day 2	Replace with confirmed teams after the preceding round.	https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-10	3:00 PM-5:15 PM	Soccer	UEFA Champions League	Champions League Matchday 1 — highest-demand match TBD	89	A	Low	Matchday dates confirmed; draw and final kickoff pending	The biggest Champions League match should dominate the afternoon.	2:45 PM-5:00 PM	FIBA Women's World Cup	FIBA Women's World Cup — quarterfinal 4	Replace with the top confirmed matchup after the league-phase draw.	https://www.uefa.com/uefachampionsleague/fixtures-results/
2026-09-10	7:00 PM-11:00 PM	Tennis	US Open	US Open — women's semifinals	90	S	Medium	Semifinal date confirmed; participants and order pending	Two major semifinals create a premium prime-time block.	8:35 PM-11:50 PM	NFL	San Francisco 49ers at Los Angeles Rams	Confirm session start and participants.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-11	7:30 AM-8:30 AM	Motorsport	Formula 1	Madrid Grand Prix — practice	71	B	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	7:00 AM-6:00 PM	Solheim Cup	Solheim Cup — opening foursomes/fourballs	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-11	9:00 AM-3:00 PM	Golf	LPGA	Solheim Cup — featured coverage	88	A	Medium	Tournament dates confirmed; broadcast window estimated	A significant LPGA event fills the morning and early afternoon.	7:00 AM-6:00 PM	Solheim Cup	Solheim Cup — opening foursomes/fourballs	Confirm tee times and official broadcast window.	https://www.lpga.com/tournaments
2026-09-11	3:00 PM-11:00 PM	Tennis	US Open	US Open — men's semifinals	92	S	Medium	Semifinal date confirmed; participants and order pending	The men's semifinal doubleheader is a full-day global tennis anchor.	7:00 AM-6:00 PM	Solheim Cup	Solheim Cup — opening foursomes/fourballs	Confirm session start and participants.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-12	10:00 AM-11:15 AM	Motorsport	Formula 1	Madrid Grand Prix — qualifying	85	A	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	9:00 AM-3:00 PM	LPGA	Solheim Cup — featured coverage	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-12	12:00 PM-3:30 PM	American Football	College Football	Ohio State at Texas	94	S	Medium	Date and matchup confirmed; kickoff window estimated	A major ranked or national-brand college matchup fills a key weekend window.	9:00 AM-3:00 PM	LPGA	Solheim Cup — featured coverage	Confirm television-selected kickoff and current rankings.	https://www.ncaa.com/news/football/article/2026-college-football-schedule
2026-09-12	4:00 PM-7:00 PM	Tennis	US Open	US Open — women's singles final	94	S	Medium	Final date confirmed; participants and exact start pending	A Grand Slam singles final should lead afternoon demand.	3:30 PM-7:00 PM	College Football	Oklahoma at Michigan	Confirm finalists and official start.	https://www.usopen.org/en_US/about/eventschedule.html
2026-09-12	8:00 PM-12:30 AM	Boxing	World Championship Boxing	Ryan Garcia vs Conor Benn / Opetaia card	87	A	Medium	Event/card announced; Toronto window estimated	Combat-sport and wrestling cards can produce concentrated evening demand driven by headliners.	5:00 PM-10:00 PM	UFC	Noche UFC — featured card	Confirm final card, cancellations and broadcast start.	https://www.dazn.com/en-US/news/boxing/boxing-schedule-fight-dates-tv-channel-and-live-stream-for-confirmed-cards/
2026-09-13	8:00 AM-10:00 AM	Motorsport	MotoGP	San Marino MotoGP	86	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	9:00 AM-3:00 PM	LPGA	Solheim Cup — final-day coverage	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-09-13	10:30 AM-12:45 PM	Basketball	FIBA Women's World Cup	FIBA Women's World Cup — bronze-medal game	81	A	Medium	Official round/time; teams determined by tournament results	Knockout-stage world championship basketball receives a major stakes boost.	11:30 AM-1:45 PM	Premier League	Manchester City at Manchester United	Replace with confirmed teams after the preceding round.	https://www.fiba.basketball/en/events/fiba-womens-basketball-world-cup-2026/games
2026-09-13	1:00 PM-4:15 PM	American Football	NFL	NFL Sunday early window — highest-demand matchup	86	A	Medium	National window confirmed; featured matchup to be finalized	NFL national windows carry exceptional per-game demand in North America.	4:00 PM-7:00 PM	US Open	US Open — men's singles final	Use live standings, starting quarterbacks and national distribution to select the final featured game.	https://www.nfl.com/schedules/2026/REG1/
2026-09-13	4:25 PM-7:40 PM	American Football	NFL	Green Bay Packers at Minnesota Vikings	89	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	4:00 PM-7:00 PM	US Open	US Open — men's singles final	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-13	8:20 PM-11:35 PM	American Football	NFL	Dallas Cowboys at New York Giants	92	S	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	7:20 PM-10:35 PM	MLB	San Diego Padres at San Francisco Giants	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-14	3:00 PM-5:15 PM	Soccer	Premier League	Newcastle United at Leeds United	79	B	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.				Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-09-14	8:15 PM-11:30 PM	American Football	NFL	Denver Broncos at Kansas City Chiefs	89	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	7:40 PM-10:55 PM	MLB	New York Yankees at Minnesota Twins	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-15	1:00 PM-4:30 PM	Cricket	International Cricket	England vs Sri Lanka — T20 International	75	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.				Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-09-15	7:40 PM-10:55 PM	Baseball	MLB	New York Yankees at Minnesota Twins	73	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:07 PM-10:22 PM	MLB	Detroit Tigers at Toronto Blue Jays	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-16	3:00 PM-5:15 PM	Soccer	UEFA Europa League	Europa League Matchday 1 — highest-demand match TBD	81	A	Low	Matchday dates confirmed; draw and kickoff pending	The most prominent Europa League matchup anchors the afternoon.	3:00 PM-5:15 PM	LaLiga	Elche vs Real Madrid	Replace with the top confirmed matchup after the draw.	https://www.uefa.com/uefaeuropaleague/fixtures-results/
2026-09-16	7:10 PM-10:25 PM	Baseball	MLB	Baltimore Orioles at New York Mets	71	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	9:38 PM-12:53 AM	MLB	Seattle Mariners at Los Angeles Angels	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-17	3:00 PM-5:15 PM	Soccer	UEFA Europa League	Europa League Matchday 1 — highest-demand match TBD	81	A	Low	Matchday dates confirmed; draw and kickoff pending	The most prominent Europa League matchup anchors the afternoon.	1:00 PM-4:30 PM	International Cricket	England vs Sri Lanka — T20 International	Replace with the top confirmed matchup after the draw.	https://www.uefa.com/uefaeuropaleague/fixtures-results/
2026-09-17	8:15 PM-11:30 PM	American Football	NFL	Detroit Lions at Buffalo Bills	88	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	7:15 PM-10:30 PM	MLB	Philadelphia Phillies at New York Mets	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-18	2:30 PM-4:45 PM	Soccer	Bundesliga	Bayern Munich vs Union Berlin	82	A	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	3:00 PM-5:15 PM	Premier League	Chelsea at Brentford		https://www.bundesliga.com/en/bundesliga/matchday/2026-2027/fc-bayern-muenchen
2026-09-18	7:00 PM-9:30 PM	Hockey	CHL	Windsor Spitfires at London Knights — OHL opener	66	C	High	Official league date; end time estimated	Junior hockey adds regional Canadian demand when it fills an otherwise open window.	7:10 PM-10:25 PM	MLB	Philadelphia Phillies at New York Mets	Confirm broadcast availability.	https://chl.ca/ohl/article/ohl-announces-home-openers-for-2026-27-regular-season/
2026-09-18	10:10 PM-1:25 AM	Baseball	MLB	San Francisco Giants at Los Angeles Dodgers	74	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	7:10 PM-10:25 PM	MLB	Philadelphia Phillies at New York Mets	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-19	7:30 AM-9:45 AM	Soccer	Premier League	Aston Villa at Tottenham Hotspur	80	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.				Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-09-19	10:00 AM-11:00 AM	Motorsport	MotoGP	Austrian MotoGP Sprint	81	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	10:00 AM-2:00 PM	World Athletics	World Athletics Road Running Championships — Day 1	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-09-19	12:00 PM-3:30 PM	American Football	College Football	Florida State at Alabama	90	S	Medium	Date and matchup confirmed; kickoff window estimated	A major ranked or national-brand college matchup fills a key weekend window.	12:30 PM-2:45 PM	Bundesliga	Stuttgart vs Borussia Dortmund	Confirm television-selected kickoff and current rankings.	https://www.ncaa.com/news/football/article/2026-college-football-schedule
2026-09-19	3:30 PM-7:00 PM	American Football	College Football	Michigan State at Notre Dame	84	A	Medium	Date and matchup confirmed; kickoff window estimated	A major ranked or national-brand college matchup fills a key weekend window.	4:10 PM-7:25 PM	MLB	Philadelphia Phillies at New York Mets	Confirm television-selected kickoff and current rankings.	https://www.ncaa.com/news/football/article/2026-college-football-schedule
2026-09-19	7:30 PM-11:00 PM	Motorsport	NASCAR Cup Series	NASCAR Cup — Bristol	81	A	High	Confirmed race start; end time estimated	A Cup Series race is a strong North American motorsport block.	9:10 PM-12:25 AM	MLB	San Francisco Giants at Los Angeles Dodgers	Check for weather delays and red flags.	https://www.nascar.com/nascar-cup-series/2026/schedule/
2026-09-20	8:00 AM-10:00 AM	Motorsport	MotoGP	Austrian MotoGP	87	A	Medium	Official race weekend; Toronto session time estimated	MotoGP adds a major global motorcycle-racing audience alongside F1 and NASCAR.	9:00 AM-11:15 AM	Premier League	Liverpool at Bournemouth	Confirm official session start after the detailed weekend timetable is published.	https://www.motogp.com/en/Calendar/2026
2026-09-20	11:30 AM-1:45 PM	Soccer	Premier League	Manchester United at Fulham	83	A	High	Broadcast-selected kickoff time confirmed; end time estimated	The highest-reach Premier League fixture in its time slot is a strong global-demand anchor.	1:00 PM-4:15 PM	NFL	NFL Sunday early window — highest-demand matchup	Recheck only for exceptional schedule disruption.	https://www.premierleague.com/en/fixtures
2026-09-20	2:45 PM-5:00 PM	Soccer	Ligue 1	Marseille vs Paris Saint-Germain	95	S	High	Official matchup; kickoff exact where published, otherwise league-window estimate	Major European club match selected for global reach, rivalry and star-team demand.	3:00 PM-5:15 PM	LaLiga	Atlético Madrid vs Real Madrid		https://ligue1.com/en/articles/l1_article_5292-the-2026-27-ligue-1-mc-donald-s-calendar-is-released
2026-09-20	8:20 PM-11:35 PM	American Football	NFL	Indianapolis Colts at Kansas City Chiefs	87	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	7:00 PM-11:00 PM	WWE	WWE Wrestlepalooza	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-21	9:00 AM-1:00 PM	Cycling	UCI Road World Championships	Montréal 2026 — featured time trial	75	B	Low	Championship dates confirmed; discipline/time assignment requires official schedule	A home Canadian world championship can materially raise daytime demand.				Replace with official discipline and start time.	https://www.uci.org/competition-hub/2026-uci-road-world-championships/4TGrABtKj4KchBB9YDPZ5b
2026-09-21	8:15 PM-11:30 PM	American Football	NFL	New York Giants at Los Angeles Rams	84	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.	8:00 PM-10:30 PM	NHL Preseason	Minnesota Wild at Chicago Blackhawks	Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-22	6:00 AM-1:00 PM	Cricket	International Cricket	England vs Sri Lanka — ODI	77	B	Medium	Official match date; Toronto session window estimated	A major international cricket match fills hours not served by North American leagues.	9:00 AM-1:00 PM	UCI Road World Championships	Montréal 2026 — featured championship race	Confirm official start, weather and whether later Test days remain necessary.	https://www.ecb.co.uk/england/men/fixtures
2026-09-22	1:05 PM-4:20 PM	Baseball	MLB	Tampa Bay Rays at New York Yankees	80	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	3:00 PM-5:15 PM	UEFA Women's Champions League	Women's Champions League Matchday 1 — featured match TBD	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-22	7:00 PM-9:30 PM	Hockey	NHL Preseason	Edmonton Oilers at Winnipeg Jets	74	B	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.	8:00 PM-10:30 PM	NHL Preseason	Vancouver Canucks at Calgary Flames	Confirm final preseason broadcast and roster availability.	https://www.nhl.com/schedule
2026-09-22	10:10 PM-1:25 AM	Baseball	MLB	San Diego Padres at Los Angeles Dodgers	75	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	8:00 PM-10:30 PM	NHL Preseason	Vancouver Canucks at Calgary Flames	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-23	9:00 AM-1:00 PM	Cycling	UCI Road World Championships	Montréal 2026 — featured championship race	73	B	Low	Championship dates confirmed; discipline/time assignment requires official schedule	A home Canadian world championship can materially raise daytime demand.				Replace with official discipline and start time.	https://www.uci.org/competition-hub/2026-uci-road-world-championships/4TGrABtKj4KchBB9YDPZ5b
2026-09-23	3:00 PM-5:15 PM	Soccer	UEFA Women's Champions League	Women's Champions League Matchday 1 — featured match TBD	78	B	Low	Matchday dates confirmed; matchup and kickoff pending	The strongest European women's club match fills the afternoon.	1:00 PM-5:00 PM	European Club Basketball	EuroLeague Women / EuroCup Women — opening-day featured game	Replace with the highest-demand confirmed matchup.	https://www.uefa.com/womenschampionsleague/fixtures-results/
2026-09-23	7:05 PM-10:20 PM	Baseball	MLB	Tampa Bay Rays at New York Yankees	80	A	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	10:10 PM-1:25 AM	MLB	San Diego Padres at Los Angeles Dodgers	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-24	5:30 AM-6:30 AM	Motorsport	Formula 1	Azerbaijan Grand Prix — practice	69	C	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	6:00 AM-1:00 PM	International Cricket	England vs Sri Lanka — ODI	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-24	9:00 AM-1:00 PM	Cycling	UCI Road World Championships	Montréal 2026 — featured championship race	74	B	Low	Championship dates confirmed; discipline/time assignment requires official schedule	A home Canadian world championship can materially raise daytime demand.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Replace with official discipline and start time.	https://www.uci.org/competition-hub/2026-uci-road-world-championships/4TGrABtKj4KchBB9YDPZ5b
2026-09-24	2:45 PM-5:00 PM	Soccer	UEFA Nations League	Nations League — highest-demand European match TBD	82	A	Low	International window confirmed; matchup and kickoff selection pending	The strongest national-team matchup may lead the afternoon once fixtures are known.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Replace with the highest-demand confirmed matchup and Toronto kickoff.	https://www.uefa.com/uefanationsleague/fixtures-results/
2026-09-24	7:00 PM-9:15 PM	Basketball	WNBA	WNBA regular-season finale window — featured game	78	B	Low	Schedule slot available; matchup/broadcast verification required	A top WNBA matchup gives the slate a high-quality basketball option.	8:15 PM-11:30 PM	NFL	Atlanta Falcons at Green Bay Packers	Verify the official matchup, start time and player availability.	https://www.wnba.com/schedule
2026-09-24	10:10 PM-1:25 AM	Baseball	MLB	San Diego Padres at Los Angeles Dodgers	75	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	8:15 PM-11:30 PM	NFL	Atlanta Falcons at Green Bay Packers	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-25	8:00 AM-9:15 AM	Motorsport	Formula 1	Azerbaijan Grand Prix — qualifying	83	A	Medium	Race weekend confirmed; Toronto session window estimated	Formula 1 provides a concentrated high-demand international viewing window.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-25	10:00 AM-2:00 PM	Athletics	World Athletics	World Mountain & Trail Running Championships — featured race	70	B	Medium	Official championship date; Toronto session time estimated	World-level athletics broadens the lineup beyond team sports.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Confirm official event timetable.	https://worldathletics.org/Competition
2026-09-25	2:00 PM-6:30 PM	Tennis	Laver Cup	Laver Cup — Day 1 session 2	84	A	Medium	Official session time; player matchups announced shortly before play	Team Europe vs Team World supplies a premium tennis block after the US Open.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Replace with the highest-demand announced matchup.	https://lavercup.com/schedule
2026-09-25	8:00 PM-11:00 PM	Canadian Football	CFL	Toronto Argonauts at Winnipeg Blue Bombers	78	B	High	Confirmed kickoff; end time estimated	A nationally relevant CFL matchup strengthens the Canadian evening slate.	10:15 PM-1:30 AM	MLB	Los Angeles Dodgers at San Francisco Giants	Confirm any broadcast-related schedule adjustment.	https://www.cfl.ca/schedule/2026/
2026-09-26	7:00 AM-9:15 AM	Motorsport	Formula 1	Azerbaijan Grand Prix	88	A	High	Race date confirmed; end time estimated	Formula 1 provides a concentrated high-demand international viewing window.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Confirm official session time and weather delays.	https://www.formula1.com/en/racing/2026
2026-09-26	10:00 AM-12:00 PM	Rugby Union	PREM Rugby	PREM Rugby — highest-demand Saturday fixture	73	B	Medium	League opening weekend confirmed; Toronto kickoff exact where available	Top-flight English rugby adds a meaningful transatlantic daytime audience.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Confirm featured fixture and kickoff before publication.	https://www.premiershiprugby.com/content/202627-fixtures-and-club-tickets
2026-09-26	2:00 PM-6:30 PM	Tennis	Laver Cup	Laver Cup — Day 2 session 2	86	A	Medium	Official session time; player matchups announced shortly before play	Team Europe vs Team World supplies a premium tennis block after the US Open.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — featured team sessions	Replace with the highest-demand announced matchup.	https://lavercup.com/schedule
2026-09-26	7:15 PM-10:30 PM	Baseball	MLB	Baltimore Orioles at New York Yankees	76	B	High	Confirmed first-pitch time; end time estimated	High-demand MLB matchup chosen using current standings, franchise reach, rivalry and Canadian relevance.	10:00 PM-4:15 AM	FIA WEC	6 Hours of Fuji — FIA World Endurance Championship	Confirm starting pitchers, postponements and doubleheader changes on game day.	https://www.mlb.com/schedule
2026-09-27	4:00 AM-10:00 AM	Esports	VALORANT Champions Tour	VALORANT Champions Shanghai — featured match day	72	B	Low	Tournament date window confirmed; matchups and exact session pending	A global tier-one esports competition supplies overnight and morning demand.	7:00 AM-1:30 PM	Laver Cup	Laver Cup — final day	Replace with the most popular confirmed matchup and official start.	https://valorantesports.com/en-US/
2026-09-27	10:00 AM-12:00 PM	Rugby Union	PREM Rugby	PREM Rugby — highest-demand Sunday fixture	73	B	Medium	League opening weekend confirmed; Toronto kickoff exact where available	Top-flight English rugby adds a meaningful transatlantic daytime audience.	7:00 AM-1:30 PM	Laver Cup	Laver Cup — final day	Confirm featured fixture and kickoff before publication.	https://www.premiershiprugby.com/content/202627-fixtures-and-club-tickets
2026-09-27	1:00 PM-4:15 PM	American Football	NFL	NFL Sunday early window — highest-demand matchup	86	A	Medium	National window confirmed; featured matchup to be finalized	NFL national windows carry exceptional per-game demand in North America.	7:00 AM-1:30 PM	Laver Cup	Laver Cup — final day	Use live standings, starting quarterbacks and national distribution to select the final featured game.	https://www.nfl.com/schedules/2026/REG1/
2026-09-27	4:25 PM-7:40 PM	American Football	NFL	NFL Sunday late window — highest-demand matchup	87	A	Medium	National window confirmed; featured matchup to be finalized	NFL national windows carry exceptional per-game demand in North America.	8:00 AM-6:00 PM	Presidents Cup	Presidents Cup — Sunday singles	Use live standings, starting quarterbacks and national distribution to select the final featured game.	https://www.nfl.com/schedules/2026/REG1/
2026-09-27	8:20 PM-11:35 PM	American Football	NFL	Los Angeles Rams at Denver Broncos	85	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.				Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-28	10:00 AM-2:00 PM	Athletics	World Athletics	World Mountain & Trail Running Championships — final races	74	B	Medium	Official championship date; Toronto session time estimated	World-level athletics broadens the lineup beyond team sports.				Confirm official event timetable.	https://worldathletics.org/Competition
2026-09-28	2:45 PM-5:00 PM	Soccer	UEFA Nations League	Nations League — highest-demand European match TBD	82	A	Low	International window confirmed; matchup and kickoff selection pending	The strongest national-team matchup may lead the afternoon once fixtures are known.				Replace with the highest-demand confirmed matchup and Toronto kickoff.	https://www.uefa.com/uefanationsleague/fixtures-results/
2026-09-28	8:15 PM-11:30 PM	American Football	NFL	Philadelphia Eagles at Chicago Bears	88	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.				Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
2026-09-29	2:45 PM-5:00 PM	Soccer	UEFA Nations League	Nations League — highest-demand European match TBD	82	A	Low	International window confirmed; matchup and kickoff selection pending	The strongest national-team matchup may lead the afternoon once fixtures are known.				Replace with the highest-demand confirmed matchup and Toronto kickoff.	https://www.uefa.com/uefanationsleague/fixtures-results/
2026-09-29	5:00 PM-7:30 PM	Hockey	NHL	Florida Panthers at Carolina Hurricanes	82	A	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.	7:00 PM-9:30 PM	NHL	Montreal Canadiens at Toronto Maple Leafs		https://www.nhl.com/news/nhl-announces-2026-27-regular-season-schedule
2026-09-29	8:00 PM-10:30 PM	Hockey	NHL	New York Rangers at Boston Bruins	89	A	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.	7:00 PM-9:30 PM	NHL	Montreal Canadiens at Toronto Maple Leafs		https://www.nhl.com/news/nhl-announces-2026-27-regular-season-schedule
2026-09-29	10:30 PM-1:00 AM	Hockey	NHL	Chicago Blackhawks at Vegas Golden Knights	80	A	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.	10:00 PM-12:30 AM	NHL	Vancouver Canucks at Edmonton Oilers		https://www.nhl.com/news/nhl-announces-2026-27-regular-season-schedule
2026-09-30	2:45 PM-5:00 PM	Soccer	UEFA Nations League	Nations League — highest-demand European match TBD	82	A	Low	International window confirmed; matchup and kickoff selection pending	The strongest national-team matchup may lead the afternoon once fixtures are known.	3:00 PM-5:15 PM	UEFA Women's Champions League	Women's Champions League Matchday 2 — featured match TBD	Replace with the highest-demand confirmed matchup and Toronto kickoff.	https://www.uefa.com/uefanationsleague/fixtures-results/
2026-09-30	7:30 PM-10:00 PM	Hockey	NHL	Pittsburgh Penguins at Philadelphia Flyers	85	A	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.	7:00 PM-9:30 PM	WNBA Playoffs	WNBA playoff game — highest-demand matchup TBD		https://www.nhl.com/news/nhl-announces-2026-27-regular-season-schedule
2026-09-30	10:00 PM-12:30 AM	Hockey	NHL	Los Angeles Kings at Colorado Avalanche	79	B	High	Official matchup/start; end time estimated	Hockey demand is ranked using rivalry, Canadian relevance, franchise reach and opening-night status.					https://www.nhl.com/news/nhl-announces-2026-27-regular-season-schedule
2026-10-01	4:00 AM-10:00 AM	Esports	VALORANT Champions Tour	VALORANT Champions Shanghai — featured match day	72	B	Low	Tournament date window confirmed; matchups and exact session pending	A global tier-one esports competition supplies overnight and morning demand.				Replace with the most popular confirmed matchup and official start.	https://valorantesports.com/en-US/
2026-10-01	2:45 PM-5:00 PM	Soccer	UEFA Nations League	Nations League — highest-demand European match TBD	82	A	Low	International window confirmed; matchup and kickoff selection pending	The strongest national-team matchup may lead the afternoon once fixtures are known.	3:00 PM-5:15 PM	UEFA Women's Champions League	Women's Champions League Matchday 2 — featured match TBD	Replace with the highest-demand confirmed matchup and Toronto kickoff.	https://www.uefa.com/uefanationsleague/fixtures-results/
2026-10-01	8:15 PM-11:30 PM	American Football	NFL	Pittsburgh Steelers at Cleveland Browns	88	A	High	Confirmed kickoff time; end time estimated	NFL national windows carry exceptional per-game demand in North America.				Check for flex scheduling only where permitted.	https://www.nfl.com/schedules/2026/REG1/
"""
}

private extension FeaturedEventPick {
    func matches(_ match: Match) -> Bool {
        guard isSameLeague(as: match) else { return false }
        let eventText = Self.normalized([title, league, sport].joined(separator: " "))
        let matchText = Self.normalized([match.name, match.shortName, match.home.displayName, match.away.displayName].joined(separator: " "))
        if eventText.contains(Self.normalized(match.name)) || matchText.contains(eventText) { return true }

        let homeTokens = Set(Self.significantTokens(in: match.home.displayName))
        let awayTokens = Set(Self.significantTokens(in: match.away.displayName))
        let titleTokens = Set(Self.significantTokens(in: title))
        let hasHome = !homeTokens.isDisjoint(with: titleTokens) || Self.titleContainsAbbreviation(match.home.abbreviation, in: title)
        let hasAway = !awayTokens.isDisjoint(with: titleTokens) || Self.titleContainsAbbreviation(match.away.abbreviation, in: title)
        return hasHome && hasAway
    }

    func isSameLeague(as match: Match) -> Bool {
        let pickTokens = Set(Self.significantTokens(in: [league, sport].joined(separator: " ")))
        let leagueTokens = Set(Self.significantTokens(in: ([match.league.name, match.league.shortName, match.league.path] + match.league.keywords).joined(separator: " ")))
        return !pickTokens.isDisjoint(with: leagueTokens)
    }

    private static func normalized(_ value: String) -> String {
        String(value.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ").joined(separator: " "))
    }

    private static func significantTokens(in value: String) -> [String] {
        let stopWords: Set<String> = ["at", "vs", "the", "fc", "cf", "sc", "club", "city", "united", "coverage", "featured"]
        return normalized(value).split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func titleContainsAbbreviation(_ abbreviation: String, in title: String) -> Bool {
        guard !abbreviation.isEmpty else { return false }
        return significantTokens(in: title).contains(abbreviation.lowercased())
    }
}
