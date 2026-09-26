import Foundation

/// **Disclosed gap**: unlike `EPLAssetResolver`, no MLS crest URL pattern was found
/// that's constructible from a bare club ID. The MLS site serves crests from
/// Cloudinary URLs with a per-club, per-upload hash (e.g.
/// `.../v1771377726/assets/rbny/logos/RBNY_crest_480x480_ddvzxy.png`) that isn't
/// derivable from `club_id`/`club_three_letter_code` alone, and neither the clubs
/// list nor any match endpoint returns a logo URL field. This returns `nil`
/// unconditionally — MLS team crests simply don't render until either MLS exposes
/// a logo field or a verified per-club asset table is built and confirmed live.
nonisolated enum MLSAssetResolver {
    static func logoURL(teamID: String) -> URL? { nil }
}
