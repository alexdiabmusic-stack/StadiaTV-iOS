import Foundation

/// LaLiga crest URLs are CMS-hosted with no derivable pattern from team ID (verified
/// live 2026-09-24: e.g. `.../xlarge/6b88661529a2c06840c8bf6bddd90970.png`, an opaque
/// hash-named asset, not the predictable `{teamID}.png` pattern EPL's badge host uses,
/// and unlike MLS — whose `AssetResolver` always returns `nil` for the same reason —
/// LaLiga's own match/standings/player-stats payloads *do* embed a real `shield.url`
/// per team, so this records whatever the mappers observe and serves it back for
/// legacy-model mapping (`LaLigaLegacyMapper`). A team seen only through the squad
/// endpoint (whose nested `team` object omits `shield` entirely) falls back to `nil`
/// until some other response records it — never a guessed URL.
nonisolated final class LaLigaAssetResolver: @unchecked Sendable {
    static let shared = LaLigaAssetResolver()
    private let lock = NSLock()
    private var shields: [String: URL] = [:]

    func record(teamID: String, shieldURLString: String?) {
        guard let shieldURLString, let url = URL(string: shieldURLString) else { return }
        lock.lock(); defer { lock.unlock() }
        shields[teamID] = url
    }

    func logoURL(teamID: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return shields[teamID]
    }
}
