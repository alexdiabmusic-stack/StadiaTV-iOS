import Foundation

nonisolated enum F1SegmentStatusMapper {
    static func map(_ code: Int?) -> F1Performance {
        switch code { case 2049: .personalBest; case 2051: .overallBest; case 0,2048,2064: .neutral; default: .unknown }
    }
    static func performance(_ raw: F1Value) -> F1Performance { raw["OverallFastest"].bool == true ? .overallBest : raw["PersonalFastest"].bool == true ? .personalBest : .neutral }
}
nonisolated enum F1TrackStatusMapper {
    static func label(_ code: String?) -> String {
        switch code { case "1": "Green flag"; case "2": "Yellow flag"; case "4": "Safety Car"; case "5": "Red flag"; case "6": "Virtual Safety Car"; case "7": "VSC ending"; default: "Track status unavailable" }
    }
}
nonisolated enum F1StrategyMapper {
    static func stints(_ raw: F1Value) -> [F1Stint] {
        // Restart/formation-lap entries can reuse tyres without a pit stop. In
        // those sessions absolute lap boundaries are ambiguous, so omit them.
        let entries = F1DeltaMerger.indexed(raw)
        var start: Int? = entries.contains { $0.1["TyresNotChanged"].int == 1 } ? nil : 1
        return entries.map { key, value in
            let laps = value["TotalLaps"].int
            let length = laps.map { max(0, $0 - (value["StartLaps"].int ?? 0)) }
            let compound = value["Compound"].string?.uppercased() ?? "UNKNOWN"
            let result = F1Stint(id: key, compound: ["SOFT","MEDIUM","HARD","INTERMEDIATE","WET"].contains(compound) ? compound : "UNKNOWN", laps: laps,
                new: value["New"].bool ?? value["New"].string.map { $0.lowercased() == "true" }, completedLaps: length, startLap: start)
            if let length, let old = start { start = old + length } else { start = nil }
            return result
        }
    }
}
nonisolated enum F1TimingMapper {
    static func display(_ value: F1Value) -> String? {
        guard let text = value["Value"].string ?? value.string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    static func normalize(_ topics: [String: F1Value], identity: String, time: Date) -> F1SessionState {
        func topic(_ name: String) -> F1Value { topics[name] ?? .null }
        let info = topic("SessionInfo"), session = topic("SessionData")
        let timing = topics["CanonicalTiming"] ?? topics["TimingDataF1"] ?? topic("TimingData")
        var result = F1SessionState(identity: identity)
        result.path = info["Path"].string; result.meeting = info["Meeting"]["Name"].string ?? "Formula 1"
        result.circuit = info["Meeting"]["Circuit"]["ShortName"].string; result.name = info["Name"].string ?? info["Type"].string ?? "Session"
        result.type = F1SessionType(result.name.lowercased().contains("sprint") ? result.name : info["Type"].string ?? result.name)
        result.status = topic("SessionStatus")["Status"].string ?? F1DeltaMerger.indexed(session["StatusSeries"]).last?.1["SessionStatus"].string ?? info["SessionStatus"].string ?? "Unknown"
        result.phase = timing["SessionPart"].int ?? F1DeltaMerger.indexed(session["Series"]).last?.1["QualifyingPart"].int
        result.currentLap = topic("LapCount")["CurrentLap"].int; result.totalLaps = topic("LapCount")["TotalLaps"].int
        let clock = topic("ExtrapolatedClock")
        result.clock = F1Clock(remaining: F1Date.duration(clock["Remaining"].string), utc: F1Date.utc(clock["Utc"].string), extrapolating: clock["Extrapolating"].bool ?? false)
        result.trackCode = topic("TrackStatus")["Status"].string; result.trackStatus = F1TrackStatusMapper.label(result.trackCode)
        let weather = topic("WeatherData")
        if !weather.object.isEmpty { result.weather = F1WeatherState(air: weather["AirTemp"].double, track: weather["TrackTemp"].double, humidity: weather["Humidity"].double, pressure: weather["Pressure"].double, windDirection: weather["WindDirection"].double, windKPH: weather["WindSpeed"].double.map { $0 * 3.6 }, raining: weather["Rainfall"].int.flatMap { $0 == 0 ? false : $0 == 1 ? true : nil }) }
        result.drivers = topic("DriverList").object.compactMap { key, value -> F1DriverTimingState? in
            guard let number = value["RacingNumber"].string ?? (Int(key) != nil ? key : nil) else { return nil }
            let driver = F1Driver(number: number, name: value["FullName"].string ?? value["BroadcastName"].string ?? "Unknown driver", tla: value["Tla"].string ?? number,
                team: value["TeamName"].string ?? "", colour: value["TeamColour"].string, country: value["CountryCode"].string,
                headshot: value["HeadshotUrl"].string.flatMap(URL.init(string:)))
            let line = timing["Lines"][number], stats = topic("TimingStats")["Lines"][number], app = topic("TimingAppData")["Lines"][number]
            let sectorValues = F1DeltaMerger.indexed(line["Sectors"])
            let sectors = sectorValues.map { key, sector in F1Sector(id: key, time: sector["Value"].string, performance: F1SegmentStatusMapper.performance(sector), segments: F1DeltaMerger.indexed(sector["Segments"]).map { F1SegmentStatusMapper.map($0.1["Status"].int) }) }
            let phaseIndex = max(0, (result.phase ?? 1) - 1)
            let phaseStats = F1DeltaMerger.indexed(line["Stats"]).first { $0.0 == String(phaseIndex) }?.1 ?? .null
            let times = F1DeltaMerger.indexed(line["BestLapTimes"])
            let best = result.type.isQualifying ? (times.isEmpty ? line["BestLapTime"]["Value"].string : times.first { $0.0 == String(phaseIndex) }?.1["Value"].string) : line["BestLapTime"]["Value"].string ?? stats["PersonalBestLapTime"]["Value"].string
            return F1DriverTimingState(driver: driver, position: line["Position"].int,
                gap: result.type.isRace ? display(line["GapToLeader"]) : phaseStats["TimeDiffToFastest"].string ?? display(line["GapToLeader"]),
                interval: result.type.isRace ? display(line["IntervalToPositionAhead"]) : nil,
                lastLap: line["LastLapTime"]["Value"].string, bestLap: best, qualifyingTimes: times.map { $0.1["Value"].string ?? "–" }, laps: line["NumberOfLaps"].int,
                sectors: sectors, speeds: F1DeltaMerger.merge(stats["BestSpeeds"], line["Speeds"] == .null ? .object([:]) : line["Speeds"]).object.compactMapValues { $0["Value"].string }, bestSectors: F1DeltaMerger.indexed(stats["BestSectors"]).compactMap { $0.1["Value"].string },
                stints: F1StrategyMapper.stints(app["Stints"]), inPit: line["InPit"].bool ?? false, pitOut: line["PitOut"].bool ?? false, stops: line["NumberOfPitStops"].int,
                retired: line["Retired"].bool ?? false, stopped: line["Stopped"].bool ?? false, knockedOut: line["KnockedOut"].bool ?? false,
                overallFastest: line["LastLapTime"]["OverallFastest"].bool ?? false, personalFastest: line["LastLapTime"]["PersonalFastest"].bool ?? false)
        }.sorted { ($0.position ?? 999, $0.id) < ($1.position ?? 999, $1.id) }
        result.messages = F1DeltaMerger.indexed(topic("RaceControlMessages")["Messages"]).compactMap { key, raw in
            guard let text = raw["Message"].string else { return nil }
            return F1RaceControlMessage(id: identity + ":rc:" + key, time: F1Date.utc(raw["Utc"].string), category: raw["Category"].string ?? "Other", flag: raw["Flag"].string, scope: raw["Scope"].string, driverNumber: raw["RacingNumber"].string, text: text, lap: raw["Lap"].int)
        }
        result.radio = F1DeltaMerger.indexed(topic("TeamRadio")["Captures"]).map { key, raw in
            let path = raw["Path"].string
            let url = path.flatMap { path -> URL? in
                if let url = URL(string: path), url.scheme == "https", url.host == "livetiming.formula1.com" { return url }
                guard let sessionPath = result.path else { return nil }
                return try? F1LiveTimingEndpoint.archive(sessionPath + path)
            }
            return F1TeamRadioMessage(id: identity + ":radio:" + key, driverNumber: raw["RacingNumber"].string, time: F1Date.utc(raw["Utc"].string), url: url)
        }
        result.pitStops = topic("PitStopSeries")["PitTimes"].object.flatMap { number, stops in
            F1DeltaMerger.indexed(stops).map { key, raw in F1PitStop(id: "\(number):\(key)", driverNumber: number, number: Int(key).map { $0 + 1 }, lap: raw["PitStop"]["Lap"].int, duration: raw["PitStop"]["PitStopTime"].string, laneTime: raw["PitStop"]["PitLaneTime"].string) }
        }
        result.availableTopics = Set(topics.keys); result.updatedAt = time
        return result
    }
}
