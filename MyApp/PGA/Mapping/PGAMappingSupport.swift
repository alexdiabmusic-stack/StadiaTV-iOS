import Foundation

/// Shared helpers so every PGA mapper parses dates/players the same way
/// instead of re-deriving these conventions per operation.
nonisolated enum PGAMappingSupport {
    /// PGA TOUR compressed payloads encode tee times / timestamps as
    /// epoch milliseconds (confirmed via pgatouR's
    /// `as.POSIXct(tee_time_ms / 1000, ...)`).
    static func epochMillis(_ value: PGAValue) -> Date? {
        guard let millis = value.double, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    static func player(_ value: PGAValue) -> GolfPlayerReference {
        GolfPlayerReference(
            id: value["id"].string ?? UUID().uuidString,
            firstName: value["firstName"].string,
            lastName: value["lastName"].string,
            displayName: value["displayName"].string,
            shortName: value["shortName"].string,
            country: value["country"].string,
            countryFlag: value["countryFlag"].string,
            amateur: value["amateur"].bool ?? false
        )
    }

    static func distance(_ value: PGAValue) -> GolfDistance? {
        if value.isNull { return nil }
        return GolfDistance(value: value.double, displayValue: value.string)
    }

    static func shotPoint(_ value: PGAValue) -> GolfShotPoint? {
        guard !value.isNull else { return nil }
        return GolfShotPoint(
            x: value["x"].double,
            y: value["y"].double,
            tourcastX: value["tourcastX"].double,
            tourcastY: value["tourcastY"].double,
            tourcastZ: value["tourcastZ"].double
        )
    }

    static func coordinatePair(_ value: PGAValue) -> GolfShotCoordinatePair? {
        guard !value.isNull else { return nil }
        let from = shotPoint(value["fromCoords"])
        let to = shotPoint(value["toCoords"])
        guard from != nil || to != nil else { return nil }
        return GolfShotCoordinatePair(from: from, to: to)
    }
}
