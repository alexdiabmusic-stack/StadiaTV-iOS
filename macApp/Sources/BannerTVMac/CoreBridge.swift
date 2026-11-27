import BannerCore
import Foundation

/// The Swift face of BannerCore (the shared Kotlin logic). Screens use this instead of touching Kotlin types, so the
/// generated Objective-C names stay in one place.
enum Core {
    /// Connects the shared core to this app. Backend settings are read from the app's Info.plist (written at build time
    /// from the local, untracked configuration), so no keys live in source.
    static func install() {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String { (info[key] as? String) ?? "" }
        MacRuntime.shared.install(
            supabaseUrl: value("BannerSupabaseURL"),
            supabaseAnonKey: value("BannerSupabaseAnonKey"),
            supabaseFallbackUrl: value("BannerSupabaseFallbackURL"),
            appVersionName: value("CFBundleShortVersionString"),
            tmdbApiKey: value("BannerTmdbApiKey")
        )
    }

    /// A collection as the Mac UI needs it.
    struct Collection: Identifiable, Hashable {
        let id: String
        let title: String
        let blurb: String
        let category: String
        let isEpisodeCollection: Bool
    }

    struct CollectionGroup { let title: String; let items: [Collection] }

    /// Every collection, grouped by its category in catalog order.
    static func collectionsByCategory() -> [CollectionGroup] {
        var order: [String] = []
        var map: [String: [Collection]] = [:]
        for c in MacDiscovery.shared.allCollections.map(Collection.init) {
            if map[c.category] == nil { order.append(c.category) }
            map[c.category, default: []].append(c)
        }
        return order.map { CollectionGroup(title: $0, items: map[$0] ?? []) }
    }
}

extension Core.Collection {
    init(_ c: ExploreCollection) {
        self.init(id: c.id, title: c.title, blurb: c.description_, category: c.category.title, isEpisodeCollection: c.episodes != nil)
    }
}
