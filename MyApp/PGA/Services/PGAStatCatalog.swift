import Foundation

/// Centralizes the handful of stat/cup IDs this app depends on for
/// product-critical features, so they're never scattered as bare string
/// literals across services and views (STEP 49).
nonisolated enum PGAStatIdentifier {
    /// Strokes Gained: Total.
    static let sgTotal = "02675"
    static let sgTeeToGreen = "02674"
    static let sgOffTheTee = "02567"
    static let sgApproach = "02568"
    static let sgAroundTheGreen = "02569"
    static let sgPutting = "02564"

    /// `TourCupSplit`'s `id` variable — this is a cup/stat id, not a
    /// tournament id. Per-tour values from the pgatouR reference client.
    static func fedExCupID(for tour: PGATourCode) -> String {
        switch tour {
        case .pgaTour: return "02671"
        case .pgaTourChampions: return "193"
        case .kornFerryTour: return "02668"
        case .pgaTourAmericas: return "2692"
        }
    }

    /// Convenience for the common PGA TOUR case.
    static let fedExCup = "02671"
}
