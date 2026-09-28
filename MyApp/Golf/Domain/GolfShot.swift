import Foundation

/// Normalized playing surface, preserving the raw provider string alongside
/// the mapped case (STEP 30) — UI logic should never depend on an arbitrary
/// provider string directly.
nonisolated enum GolfLie: Sendable, Hashable {
    case tee
    case fairway
    case rough
    case intermediateRough
    case bunker
    case green
    case fringe
    case nativeArea
    case penaltyArea
    case hole
    case unknown(String)

    init(raw: String?) {
        guard let raw, !raw.isEmpty else { self = .unknown(""); return }
        switch raw.uppercased().replacingOccurrences(of: "_", with: " ") {
        case "TEE", "TEE BOX": self = .tee
        case "FAIRWAY": self = .fairway
        case "ROUGH": self = .rough
        case "INTERMEDIATE ROUGH", "1ST CUT", "FIRST CUT": self = .intermediateRough
        case "BUNKER", "SAND", "TRAP", "GREENSIDE BUNKER", "FAIRWAY BUNKER": self = .bunker
        case "GREEN": self = .green
        case "FRINGE", "COLLAR", "APRON": self = .fringe
        case "NATIVE AREA", "NATIVE": self = .nativeArea
        case "PENALTY AREA", "WATER", "HAZARD": self = .penaltyArea
        case "HOLE", "CUP", "PIN": self = .hole
        default: self = .unknown(raw)
        }
    }

    var displayName: String {
        switch self {
        case .tee: return "Tee"
        case .fairway: return "Fairway"
        case .rough: return "Rough"
        case .intermediateRough: return "Intermediate Rough"
        case .bunker: return "Bunker"
        case .green: return "Green"
        case .fringe: return "Fringe"
        case .nativeArea: return "Native Area"
        case .penaltyArea: return "Penalty Area"
        case .hole: return "Hole"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }
}

/// A shot's reported distance. Unit is whatever the provider supplied
/// (`displayValue`, when present); this app never guesses yards vs. feet.
nonisolated struct GolfDistance: Codable, Sendable, Hashable {
    let value: Double?
    let displayValue: String?
}

/// One point in the provider's own shot-coordinate space. `x`/`y` and the
/// `tourcast*` triple are the exact field names observed in captured
/// `shotDetailsV4Compressed` payloads (via `overview.leftToRightCoords` /
/// `overview.bottomToTopCoords`). Neither projection is a verified
/// geographic system — treat as schematic until validated against a real
/// captured hole (STEP 32).
nonisolated struct GolfShotPoint: Codable, Sendable, Hashable {
    let x: Double?
    let y: Double?
    let tourcastX: Double?
    let tourcastY: Double?
    let tourcastZ: Double?
}

nonisolated struct GolfShotCoordinatePair: Codable, Sendable, Hashable {
    let from: GolfShotPoint?
    let to: GolfShotPoint?
}

nonisolated struct GolfShotCoordinates: Codable, Sendable, Hashable {
    let leftToRight: GolfShotCoordinatePair?
    let bottomToTop: GolfShotCoordinatePair?

    var hasUsableCoordinates: Bool {
        leftToRight?.from != nil || leftToRight?.to != nil || bottomToTop?.from != nil || bottomToTop?.to != nil
    }
}

nonisolated struct GolfShot: Identifiable, Codable, Sendable, Hashable {
    var id: String { "\(holeNumber)-\(strokeNumber)" }
    let holeNumber: Int
    let strokeNumber: Int
    let description: String?
    let distance: GolfDistance?
    let distanceRemaining: GolfDistance?
    let strokeTypeRaw: String?
    let fromLocationRaw: String?
    let toLocationRaw: String?
    let isFinalStroke: Bool
    let coordinates: GolfShotCoordinates?

    var fromLie: GolfLie { GolfLie(raw: fromLocationRaw) }
    var toLie: GolfLie { GolfLie(raw: toLocationRaw) }
}

nonisolated struct GolfShotHole: Identifiable, Codable, Sendable, Hashable {
    var id: Int { holeNumber }
    let holeNumber: Int
    let par: Int?
    let yardage: Int?
    let statusRaw: String?
    let scoreDisplay: String?
    let shots: [GolfShot]
}

nonisolated struct GolfShotRound: Codable, Sendable, Hashable {
    let tournamentID: String
    let playerID: String
    let round: Int
    let holes: [GolfShotHole]
}
