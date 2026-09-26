import Foundation

/// MLS paginates with an opaque `next_page_token` sibling field rather than PulseLive's
/// `{pagination:{_next,_prev}, data:[...]}` envelope, and the array itself is keyed
/// differently per endpoint (`schedule`, `events`, `commentary`, `clubs`,
/// `player_statistics`, ...) rather than a uniform `data` key — so this wrapper takes
/// the array key explicitly instead of assuming one.
nonisolated struct MLSPagedResponse {
    let raw: MLSValue
    let arrayKey: String
    var data: [MLSValue] { raw[arrayKey].array }
    var nextPageToken: String? { raw["next_page_token"].string }
}
