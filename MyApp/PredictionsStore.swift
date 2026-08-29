import Foundation
import Combine

// MARK: - Pick outcome

enum PickOutcome: String, Codable, CaseIterable {
    case away, draw, home

    func label(away awayName: String, home homeName: String) -> String {
        switch self {
        case .away: return awayName
        case .draw: return "Draw"
        case .home: return homeName
        }
    }

    var systemImage: String {
        switch self {
        case .away: return "arrow.left.circle.fill"
        case .draw: return "equal.circle.fill"
        case .home: return "arrow.right.circle.fill"
        }
    }
}

// MARK: - Prediction model

struct Prediction: Identifiable, Codable {
    let id: String              // equals match.id
    let matchName: String
    let leagueName: String
    let homeTeamName: String
    let awayTeamName: String
    let homeLogoURLString: String?
    let awayLogoURLString: String?
    let pick: PickOutcome
    let placedAt: Date
    /// The scheduled start time of the match (stored for lookup when tapping a past pick).
    var matchDate: Date?
    var resolvedOutcome: PickOutcome?
    /// Points awarded (nil = pending, 0 = wrong, >0 = correct + streak bonus).
    var pointsEarned: Int?
    /// Consecutive correct picks at the time this resolved (for display in history).
    var streakAtTime: Int?

    var homeLogoURL: URL? { homeLogoURLString.flatMap(URL.init(string:)) }
    var awayLogoURL: URL? { awayLogoURLString.flatMap(URL.init(string:)) }

    var isResolved: Bool { resolvedOutcome != nil }

    var isCorrect: Bool? {
        guard let resolved = resolvedOutcome else { return nil }
        return pick == resolved
    }
}

// MARK: - Store

/// Persists match predictions locally and tracks points + streaks for gamification.
@MainActor
final class PredictionsStore: ObservableObject {
    @Published private(set) var predictions: [Prediction] = []
    @Published private(set) var totalPoints: Int = 0
    @Published private(set) var currentStreak: Int = 0
    @Published private(set) var bestStreak: Int = 0

    private let key = "stadiatv.predictions.v1"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Prediction].self, from: data) else { return }
        predictions = decoded
        recomputePointsAndStreaks()
    }

    func hasPrediction(for matchID: String) -> Bool {
        predictions.contains { $0.id == matchID }
    }

    func prediction(for matchID: String) -> Prediction? {
        predictions.first { $0.id == matchID }
    }

    var correctCount: Int { predictions.compactMap(\.isCorrect).filter { $0 }.count }
    var resolvedCount: Int { predictions.filter(\.isResolved).count }
    var pendingCount: Int { predictions.filter { !$0.isResolved }.count }

    var winRate: Double? {
        guard resolvedCount > 0 else { return nil }
        return Double(correctCount) / Double(resolvedCount)
    }

    var weeklyRecord: (correct: Int, total: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekly = predictions.filter { $0.isResolved && $0.placedAt >= cutoff }
        let correct = weekly.compactMap(\.isCorrect).filter { $0 }.count
        return (correct, weekly.count)
    }

    func place(pick: PickOutcome, for match: Match) {
        guard !hasPrediction(for: match.id) else { return }
        let p = Prediction(
            id: match.id,
            matchName: match.name,
            leagueName: match.league.name,
            homeTeamName: match.home.displayName,
            awayTeamName: match.away.displayName,
            homeLogoURLString: match.home.logoURL?.absoluteString,
            awayLogoURLString: match.away.logoURL?.absoluteString,
            pick: pick,
            placedAt: Date(),
            matchDate: match.date
        )
        predictions.append(p)
        save()
    }

    /// Resolves the prediction for a single completed match. Returns true if newly resolved as correct.
    @discardableResult
    func resolveIfNeeded(for match: Match) -> Bool {
        guard match.state == .final,
              let idx = predictions.firstIndex(where: { $0.id == match.id }),
              predictions[idx].resolvedOutcome == nil else { return false }

        predictions[idx].resolvedOutcome = outcome(for: match)
        recomputePointsAndStreaks()
        save()
        return predictions[idx].isCorrect == true
    }

    /// Resolves all pending predictions that have finished matches in the provided list.
    /// Returns IDs of predictions newly resolved as correct.
    @discardableResult
    func resolveAll(from matches: [Match]) -> [String] {
        var anyChanged = false
        var newlyCorrect: [String] = []

        for match in matches where match.state == .final {
            guard let idx = predictions.firstIndex(where: { $0.id == match.id }),
                  predictions[idx].resolvedOutcome == nil else { continue }
            predictions[idx].resolvedOutcome = outcome(for: match)
            anyChanged = true
            if predictions[idx].isCorrect == true {
                newlyCorrect.append(predictions[idx].id)
            }
        }

        if anyChanged {
            recomputePointsAndStreaks()
            save()
        }
        return newlyCorrect
    }

    /// Fetches the last 30 days of scoreboards for every league that has a pending
    /// prediction, then resolves any matches found. Call on view appear so that picks
    /// made on previous sessions (different league selected, or days ago) auto-resolve.
    func resolveStaleIfNeeded() async {
        let pending = predictions.filter { !$0.isResolved }
        guard !pending.isEmpty else { return }

        let leagueNames = Set(pending.map(\.leagueName))
        let leagues = League.all.filter { leagueNames.contains($0.name) }
        guard !leagues.isEmpty else { return }

        let startDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        var allMatches: [Match] = []
        await withTaskGroup(of: [Match].self) { group in
            for league in leagues {
                group.addTask {
                    (try? await SportsRepository.shared.legacyScoreboards(for: league, starting: startDate, days: 31)) ?? []
                }
            }
            for await matches in group {
                allMatches.append(contentsOf: matches)
            }
        }
        resolveAll(from: allMatches)
    }

    // MARK: - Private

    private func outcome(for match: Match) -> PickOutcome {
        let homeScore = Int(match.home.score ?? "") ?? 0
        let awayScore = Int(match.away.score ?? "") ?? 0
        if homeScore > awayScore { return .home }
        if awayScore > homeScore { return .away }
        return .draw
    }

    /// Rebuilds pointsEarned / streakAtTime for every resolved pick in chronological order,
    /// then updates totalPoints, currentStreak, and bestStreak.
    ///
    /// Points per correct pick: 10 base + 2 per pick in the current streak (capped at +10 bonus).
    /// Streak 1→10 pts, 2→12 pts, 3→14 pts, 4→16 pts, 5→18 pts, 6+→20 pts.
    private func recomputePointsAndStreaks() {
        let resolvedIndices = predictions.indices
            .filter { predictions[$0].isResolved }
            .sorted { predictions[$0].placedAt < predictions[$1].placedAt }

        var runningStreak = 0
        var best = 0
        var pts = 0

        for idx in resolvedIndices {
            if predictions[idx].isCorrect == true {
                runningStreak += 1
                best = max(best, runningStreak)
                let bonus = min(runningStreak - 1, 5) * 2
                let earned = 10 + bonus
                predictions[idx].pointsEarned = earned
                predictions[idx].streakAtTime = runningStreak
                pts += earned
            } else {
                runningStreak = 0
                predictions[idx].pointsEarned = 0
                predictions[idx].streakAtTime = 0
            }
        }

        totalPoints = pts
        currentStreak = runningStreak
        bestStreak = best
    }

    private func save() {
        if let data = try? JSONEncoder().encode(predictions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
