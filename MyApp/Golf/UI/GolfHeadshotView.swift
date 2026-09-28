import SwiftUI

/// Locally bundled PGA TOUR headshots (Assets.xcassets `GolfHeadshot_{playerID}`),
/// keyed by the same numeric player id PGA TOUR's GraphQL API uses for
/// `GolfPlayerReference.id`. Snapshot of the active roster — players outside
/// this set (rookies added after the snapshot, amateurs, alternates) fall
/// back to a placeholder in `GolfHeadshotView`.
nonisolated enum GolfHeadshotAssetResolver {
    static func assetURL(playerID: String) -> URL? {
        guard knownPlayerIDs.contains(playerID) else { return nil }
        return URL.bannerImageAsset(named: "GolfHeadshot_\(playerID)")
    }

    static let knownPlayerIDs: Set<String> = [
        "06567", "08793", "12716", "22371", "22405", "23108", "24502", "25493", "25900", "27064",
        "27139", "27214", "27349", "27644", "27649", "28089", "28237", "28252", "28723", "28775",
        "29221", "29420", "29478", "29535", "29725", "29908", "29936", "30163", "30692", "30911",
        "30926", "30927", "31323", "31646", "32070", "32102", "32139", "32150", "32757", "32791",
        "32839", "33141", "33204", "33399", "33448", "33597", "33968", "34021", "34046", "34076",
        "34098", "34099", "34174", "34256", "34371", "34409", "34466", "34587", "35296", "35310",
        "35450", "35461", "35506", "35532", "35658", "36326", "36529", "36689", "36699", "36799",
        "36801", "36824", "36884", "37076", "37275", "37278", "37338", "37378", "37455", "38991",
        "39324", "39327", "39335", "39546", "39971", "39975", "39977", "39997", "40006", "40026",
        "40042", "40058", "40098", "40115", "40162", "40250", "45157", "45242", "45522", "45609",
        "46046", "46340", "46414", "46442", "46443", "46464", "46601", "46717", "47056", "47347",
        "47393", "47420", "47483", "47504", "47591", "47917", "47983", "47993", "47995", "48001",
        "48081", "48117", "48153", "48867", "48887", "49037", "49120", "49228", "49590", "49766",
        "49771", "49855", "49947", "49960", "49964", "50095", "50188", "50286", "50484", "50497",
        "50525", "50582", "51003", "51070", "51287", "51349", "51600", "51634", "51696", "51766",
        "51890", "51894", "51950", "51977", "51997", "52215", "52372", "52375", "52453", "52513",
        "52514", "52666", "52686", "52689", "52955", "54304", "54421", "54422", "54576", "54591",
        "54607", "54628", "54783", "54788", "55165", "55182", "55573", "55721", "55789", "55851",
        "55893", "56630", "56762", "56781", "57123", "57259", "57362", "57364", "57366", "57586",
        "57869", "57900", "57975", "58168", "59006", "59018", "59095", "59141", "59143", "59440",
        "59442", "59567", "59836", "59866", "60004", "60019", "60067", "60386", "61522", "63121",
        "63343", "63454", "63807", "64442", "65256", "66701", "66743"
    ]
}

/// Circular player headshot for leaderboard rows and player detail headers.
/// Falls back to a silhouette for golfers outside the bundled roster snapshot.
struct GolfHeadshotView: View {
    let playerID: String
    let size: CGFloat

    var body: some View {
        Group {
            if let assetName = GolfHeadshotAssetResolver.assetURL(playerID: playerID)?.bannerImageAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.textTertiary)
                    .padding(size * 0.06)
                    .background(Theme.surfaceElevated)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
