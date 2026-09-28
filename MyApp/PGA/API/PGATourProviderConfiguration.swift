import Foundation

/// Centralizes every PGA TOUR transport endpoint plus the public frontend
/// `x-api-key`. The key is the same undocumented public value the pgatour.com
/// website itself ships in its JS bundle (not a user credential — no sign-in
/// is ever required). It can rotate; every PGA request must resolve it from
/// here rather than hard-coding it locally so a single update fixes the app.
nonisolated struct PGATourProviderConfiguration: Sendable, Equatable {
    let graphqlHost: URL
    let restHost: URL
    let configHost: URL
    let currentFrontendAPIKey: String
    let platformHeader: String

    static let `default` = PGATourProviderConfiguration(
        graphqlHost: URL(string: "https://orchestrator.pgatour.com/graphql")!,
        restHost: URL(string: "https://data-api.pgatour.com")!,
        configHost: URL(string: "https://orchestrator-config.pgatour.com")!,
        currentFrontendAPIKey: "da2-gsrx5bibzbb4njvhl7t37wqyl4",
        platformHeader: "web"
    )
}

/// Owns the live configuration value so a remote-config refresh (or DEBUG
/// override) can rotate the frontend key without scattering mutable state
/// across every PGA service.
actor PGATourProviderConfigurationStore {
    static let shared = PGATourProviderConfigurationStore()

    private var configuration: PGATourProviderConfiguration

    init(configuration: PGATourProviderConfiguration = .default) {
        self.configuration = configuration
    }

    func current() -> PGATourProviderConfiguration { configuration }

    /// Called if the app ever learns of a rotated key (e.g. via its own
    /// remote-config channel). Never invented locally; only ever set from an
    /// explicit, trusted source.
    func updateAPIKey(_ key: String) {
        guard !key.isEmpty else { return }
        configuration = PGATourProviderConfiguration(
            graphqlHost: configuration.graphqlHost,
            restHost: configuration.restHost,
            configHost: configuration.configHost,
            currentFrontendAPIKey: key,
            platformHeader: configuration.platformHeader
        )
    }
}
