import Foundation

/// Maps the decompressed `shotDetailsV4Compressed` payload. Per-stroke
/// coordinate data lives under `stroke.overview.{leftToRightCoords,
/// bottomToTopCoords}.{fromCoords,toCoords}` — confirmed against the
/// pgatourPY reference client's flattening logic, not guessed. The top-level
/// hole field is named `strokes` in the real payload (the PGA docs'
/// abbreviated schema example calls it "shots", but both reference client
/// implementations read `hole["strokes"]`).
nonisolated enum PGAShotMapper {
    static func shotRound(_ value: PGAValue, tournamentID: String, playerID: String, round: Int) -> GolfShotRound {
        let holes = value["holes"].array.map(hole)
        return GolfShotRound(tournamentID: tournamentID, playerID: playerID, round: round, holes: holes)
    }

    private static func hole(_ value: PGAValue) -> GolfShotHole {
        GolfShotHole(
            holeNumber: value["holeNumber"].int ?? 0,
            par: value["par"].int,
            yardage: value["yardage"].int,
            statusRaw: value["status"].string,
            scoreDisplay: value["score"].string,
            shots: value["strokes"].array.map { stroke(holeNumber: value["holeNumber"].int ?? 0, value: $0) }
        )
    }

    private static func stroke(holeNumber: Int, value: PGAValue) -> GolfShot {
        let overview = value["overview"]
        let coordinates: GolfShotCoordinates? = overview.isNull ? nil : GolfShotCoordinates(
            leftToRight: PGAMappingSupport.coordinatePair(overview["leftToRightCoords"]),
            bottomToTop: PGAMappingSupport.coordinatePair(overview["bottomToTopCoords"])
        )
        return GolfShot(
            holeNumber: holeNumber,
            strokeNumber: value["strokeNumber"].int ?? 0,
            description: value["playByPlay"].string,
            distance: PGAMappingSupport.distance(value["distance"]),
            distanceRemaining: PGAMappingSupport.distance(value["distanceRemaining"]),
            strokeTypeRaw: value["strokeType"].string,
            fromLocationRaw: value["fromLocation"].string,
            toLocationRaw: value["toLocation"].string,
            isFinalStroke: value["finalStroke"].bool ?? false,
            coordinates: (coordinates?.hasUsableCoordinates == true) ? coordinates : nil
        )
    }
}
