import Foundation

/// Maps `CourseStats` (per-tournament hole scoring stats) and `HoleDetails`
/// (single-hole deep detail). Neither is compressed.
nonisolated enum PGACourseMapper {
    static func courses(_ value: PGAValue) -> [GolfCourse] {
        value["courses"].array.map(course)
    }

    private static func course(_ value: PGAValue) -> GolfCourse {
        let overview = value["courseOverview"]
        // Hole scoring stats are reported per round; use the most recent
        // round that has data so the Course tab reflects the latest
        // completed/in-progress scoring rather than only round 1.
        let latestRound = value["roundHoleStats"].array.last { !$0["holeStats"].array.isEmpty }
        let holes = (latestRound?["holeStats"].array ?? [])
            .filter { $0["__typename"].string == "CourseHoleStats" }
            .compactMap(hole)
            .sorted { $0.number < $1.number }
        return GolfCourse(
            id: value["courseId"].string ?? "",
            name: value["courseName"].string ?? overview["name"].string ?? "",
            code: value["courseCode"].string,
            isHostCourse: value["hostCourse"].bool ?? false,
            par: value["par"].int,
            yardage: value["yardage"].int,
            city: overview["city"].string,
            state: overview["state"].string,
            country: overview["country"].string,
            holes: holes
        )
    }

    private static func hole(_ value: PGAValue) -> GolfHole? {
        guard let number = value["courseHoleNum"].int else { return nil }
        return GolfHole(
            number: number,
            par: value["parValue"].int,
            yardage: value["yards"].int,
            scoringAverage: value["scoringAverage"].double,
            scoringAverageToParDisplay: value["scoringAverageDiff"].string,
            rank: value["rank"].int,
            eagles: value["eagles"].int,
            birdies: value["birdies"].int,
            pars: value["pars"].int,
            bogeys: value["bogeys"].int,
            doubleBogeyOrWorse: value["doubleBogey"].int
        )
    }

    static func holeDetail(_ value: PGAValue, courseID: String) -> GolfHoleDetail {
        let summary = value["statsSummary"]
        let info = value["holeInfo"]
        return GolfHoleDetail(
            courseID: courseID,
            holeNumber: value["holeNum"].int ?? 0,
            par: info["par"].int,
            yardage: info["yards"].int,
            rankDisplay: info["rank"].string,
            aboutThisHole: info["aboutThisHole"].string,
            eagles: summary["eagles"].int,
            eaglesPercent: summary["eaglesPercent"].double,
            birdies: summary["birdies"].int,
            birdiesPercent: summary["birdiesPercent"].double,
            pars: summary["pars"].int,
            parsPercent: summary["parsPercent"].double,
            bogeys: summary["bogeys"].int,
            bogeysPercent: summary["bogeysPercent"].double,
            doubleBogeysOrWorse: summary["doubleBogeys"].int,
            doubleBogeysOrWorsePercent: summary["doubleBogeysPercent"].double,
            tourcastURL: (value["tourcastURL"].string ?? value["tourcastURLWeb"].string).flatMap(URL.init(string:))
        )
    }
}
