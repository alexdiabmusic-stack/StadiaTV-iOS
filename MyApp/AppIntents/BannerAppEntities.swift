import AppIntents

/// Lightweight App Intents projections of Banner's real domain models (`FavoriteTeam`,
/// `Channel`, `Podcast`) — deliberately not the domain types themselves, so this file
/// stays decoupled from their exact protocol conformances. All data still comes from
/// `BannerAppEnvironment.shared`'s real stores; no separate catalog is built here.

struct TeamEntity: AppEntity {
    let id: String
    let name: String
    let leagueBannerKey: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Team"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = TeamEntityQuery()

    @MainActor init(favorite: FavoriteTeam) {
        id = favorite.canonicalTeamID
        name = favorite.displayName
        leagueBannerKey = favorite.leagueBannerKey
    }
}

struct TeamEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor private var favorites: [FavoriteTeam] { BannerAppEnvironment.shared.preferences.favoriteTeams }

    @MainActor func entities(for identifiers: [String]) async throws -> [TeamEntity] {
        favorites.filter { identifiers.contains($0.canonicalTeamID) }.map(TeamEntity.init(favorite:))
    }

    @MainActor func suggestedEntities() async throws -> [TeamEntity] {
        favorites.map(TeamEntity.init(favorite:))
    }

    /// Backs "Play the Senators game" — matching against followed teams only, so Siri
    /// naturally asks for clarification when more than one followed team's name matches
    /// (e.g. two differently-sponsored "Ottawa" teams) instead of this code guessing.
    @MainActor func entities(matching string: String) async throws -> [TeamEntity] {
        favorites.filter { $0.displayName.localizedCaseInsensitiveContains(string) }.map(TeamEntity.init(favorite:))
    }
}

struct SportsChannelEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sports Channel"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = SportsChannelEntityQuery()
}

struct SportsChannelEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor private var channels: [Channel] {
        BannerAppEnvironment.shared.playlistStore.allChannels
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [SportsChannelEntity] {
        channels.filter { identifiers.contains($0.id) }.map { SportsChannelEntity(id: $0.id, name: $0.name) }
    }

    @MainActor func suggestedEntities() async throws -> [SportsChannelEntity] {
        channels.filter(BannerSportsChannelClassifier.isSportsChannel).prefix(25)
            .map { SportsChannelEntity(id: $0.id, name: $0.name) }
    }

    @MainActor func entities(matching string: String) async throws -> [SportsChannelEntity] {
        channels.filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map { SportsChannelEntity(id: $0.id, name: $0.name) }
    }
}

struct BannerPodcastEntity: AppEntity {
    let id: String   // feedURL.absoluteString
    let title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Podcast"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static var defaultQuery = BannerPodcastEntityQuery()
}

struct BannerPodcastEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor private var subscribed: [Podcast] {
        let store = BannerAppEnvironment.shared.podcastStore
        return store.catalog.filter { store.subscribedIDs.contains($0.feedURL.absoluteString) }.map { $0.toPodcast() }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [BannerPodcastEntity] {
        subscribed.filter { identifiers.contains($0.id) }.map { BannerPodcastEntity(id: $0.id, title: $0.title) }
    }

    @MainActor func suggestedEntities() async throws -> [BannerPodcastEntity] {
        subscribed.map { BannerPodcastEntity(id: $0.id, title: $0.title) }
    }

    @MainActor func entities(matching string: String) async throws -> [BannerPodcastEntity] {
        subscribed.filter { $0.title.localizedCaseInsensitiveContains(string) }
            .map { BannerPodcastEntity(id: $0.id, title: $0.title) }
    }
}
