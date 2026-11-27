import BannerCore
import Foundation
import Security

/// A channel as the Live TV screens use it.
struct ChannelItem: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: URL?
    let group: String
    let url: URL?
    let headers: [String: String]
}

struct AiringInfo: Hashable {
    let title: String
    let start: Date
    let end: Date
    let detail: String?
    var fraction: Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(max(Date().timeIntervalSince(start) / total, 0), 1) : 0
    }
}

struct PlaylistSource: Codable, Hashable, Identifiable {
    var id: String { url }
    var name: String
    var url: String
}

/// The person's IPTV sources. Everything but the Xtream password lives in UserDefaults; the password is in the Keychain.
@MainActor
final class LiveTvSources: ObservableObject {
    @Published var playlists: [PlaylistSource] = [] { didSet { save() } }
    @Published var epgUrls: [String] = [] { didSet { save() } }
    @Published var xtreamServer = "" { didSet { save() } }
    @Published var xtreamUser = "" { didSet { save() } }
    @Published var xtreamPassword = "" { didSet { savePassword(); save() } }
    private var loading = true
    private static let passwordAccount = "xtream-password"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "mac_live_playlists"), let list = try? JSONDecoder().decode([PlaylistSource].self, from: data) { playlists = list }
        epgUrls = d.stringArray(forKey: "mac_live_epg") ?? []
        xtreamServer = d.string(forKey: "mac_live_xtream_server") ?? ""
        xtreamUser = d.string(forKey: "mac_live_xtream_user") ?? ""
        xtreamPassword = Keychain.read(Self.passwordAccount) ?? ""
        loading = false
        apply()
    }

    var isConfigured: Bool { !playlists.isEmpty || (!xtreamServer.isEmpty && !xtreamUser.isEmpty) }

    private var commitTask: Task<Void, Never>?

    /// Changes are saved and applied once typing pauses, so a half-typed server or password is never sent to a provider.
    private func save() {
        guard !loading else { return }
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            let d = UserDefaults.standard
            d.set(try? JSONEncoder().encode(self.playlists), forKey: "mac_live_playlists")
            d.set(self.epgUrls, forKey: "mac_live_epg")
            d.set(self.xtreamServer, forKey: "mac_live_xtream_server")
            d.set(self.xtreamUser, forKey: "mac_live_xtream_user")
            if self.xtreamPassword.isEmpty { Keychain.delete(Self.passwordAccount) } else { Keychain.write(Self.passwordAccount, self.xtreamPassword) }
            self.apply()
        }
    }

    private func savePassword() {}

    func apply() {
        MacLiveTv.shared.configure(newSources: MacLiveTvSources(
            playlistNames: playlists.map(\.name), playlistUrls: playlists.map(\.url),
            xtreamServer: xtreamServer, xtreamUsername: xtreamUser, xtreamPassword: xtreamPassword, epgUrls: epgUrls))
    }
}

/// Minimal Keychain access for one generic password per account name.
enum Keychain {
    private static let service = "tv.banner.mac"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Channels, favourites and the guide, from the shared core.
@MainActor
final class LiveTvModel: ObservableObject {
    @Published private(set) var channels: [ChannelItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isGuideLoading = false
    @Published private(set) var guideLoaded = false
    @Published private(set) var error: String?
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var recents: [String] = []
    private var watches: [MacWatch] = []

    func start() {
        guard watches.isEmpty else { return }
        watches.append(MacBridge.shared.watchLiveTv { [weak self] state in
            let items = state.channels.map { c in
                ChannelItem(id: c.id, name: c.name, logo: c.logoUrl.flatMap(URL.init(string:)), group: c.group ?? "Other",
                            url: URL(string: c.streamUrl), headers: c.headers)
            }
            Task { @MainActor in
                self?.channels = items; self?.isLoading = state.isLoading; self?.error = state.error
                self?.isGuideLoading = state.isGuideLoading; self?.guideLoaded = state.guideLoaded
            }
        })
        watches.append(MacBridge.shared.watchLiveFavorites { [weak self] ids in Task { @MainActor in self?.favorites = ids } })
        watches.append(MacBridge.shared.watchLiveRecents { [weak self] ids in Task { @MainActor in self?.recents = ids } })
    }

    var groups: [String] { Array(Set(channels.map(\.group))).sorted() }

    func nowNext(_ channel: ChannelItem) -> (now: AiringInfo?, next: AiringInfo?) {
        let list = MacLiveTv.shared.nowAndNext(channelId: channel.id).map(Self.airing)
        let nowMs = Date().timeIntervalSince1970
        guard let first = list.first else { return (nil, nil) }
        if first.start.timeIntervalSince1970 <= nowMs { return (first, list.dropFirst().first) }
        return (nil, first)
    }

    func programs(_ channel: ChannelItem) -> [AiringInfo] { MacLiveTv.shared.programsFor(channelId: channel.id).map(Self.airing) }

    func toggleFavorite(_ channel: ChannelItem) { MacLiveTv.shared.toggleFavorite(channelId: channel.id) }
    func refresh() { MacLiveTv.shared.refresh() }

    private static func airing(_ p: MacProgram) -> AiringInfo {
        AiringInfo(title: p.title, start: Date(timeIntervalSince1970: Double(p.startMs) / 1000), end: Date(timeIntervalSince1970: Double(p.endMs) / 1000), detail: p.description)
    }
}
