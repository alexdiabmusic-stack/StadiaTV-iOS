import SwiftUI

/// Locally bundled 2026 grid headshots (Assets.xcassets `F1Headshot_{tla}`),
/// keyed by the three-letter driver code the live timing feed reports as `Tla`.
/// Drivers outside this snapshot (mid-season call-ups) fall back to the feed's
/// own `headshot` URL, then to a silhouette.
nonisolated enum F1HeadshotAssetResolver {
    static func assetURL(tla: String) -> URL? {
        guard knownTLAs.contains(tla.uppercased()) else { return nil }
        return URL.bannerImageAsset(named: "F1Headshot_\(tla.uppercased())")
    }

    static let knownTLAs: Set<String> = [
        "ALB", "ALO", "ANT", "BEA", "BOR", "BOT", "COL", "GAS", "HAD", "HAM",
        "HUL", "LAW", "LEC", "LIN", "NOR", "OCO", "PER", "PIA", "RUS", "SAI", "STR", "VER"
    ]
}

/// Circular driver headshot for timing rows and the driver detail header.
struct F1HeadshotView: View {
    let driver: F1Driver
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = F1HeadshotAssetResolver.assetURL(tla: driver.tla)?.bannerImageAssetName {
                Image(assetName).resizable().scaledToFill()
            } else if let url = driver.headshot {
                CachedImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Theme.textTertiary).padding(size * 0.06).background(Theme.surfaceElevated)
                }
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(Theme.textTertiary).padding(size * 0.06).background(Theme.surfaceElevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Team logo for timing rows and the driver detail header, resolved from the
/// live feed's `team` display name against the bundled 2026 grid logo set.
struct F1TeamLogoView: View {
    let team: String
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = TeamLogoAssetResolver.f1AssetURL(team: team)?.bannerImageAssetName {
                Image(assetName).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
