import BannerCore
import Foundation

/// One installed add-on as the Settings screen shows it.
struct AddonRow: Identifiable, Hashable {
    let id: String          // manifest URL
    let title: String
    let detail: String
    let enabled: Bool
    let isRefreshing: Bool
    let error: String?
}

struct ProfileInfo: Identifiable, Hashable {
    let index: Int
    var id: Int { index }
    let name: String
    let colorHex: String
    let avatar: URL?
    let pinEnabled: Bool
}

enum SessionStage { case launching, signedOut, choosingProfile, ready }

/// The signed-in account and its add-ons, driven by the shared Kotlin core (BannerCore). Everything here is the same
/// code the iPhone and Android apps run for sign-in and add-on sync.
@MainActor
final class AccountModel: ObservableObject {
    @Published private(set) var phase = "loading"          // loading | signedOut | signedIn
    @Published private(set) var email: String?
    @Published private(set) var isAnonymous = false
    @Published private(set) var addons: [AddonRow] = []
    @Published var message: String?
    @Published private(set) var busy = false
    @Published private(set) var stage: SessionStage = .launching
    @Published private(set) var profiles: [ProfileInfo] = []
    @Published private(set) var activeProfile: ProfileInfo?
    private var avatarURLs: [String: String] = [:]
    private var rawProfiles: [NuvioProfile] = []
    private var profileFlowUser: String?

    private var watches: [MacWatch] = []
    private var pulledFor: String?

    func start() {
        guard watches.isEmpty else { return }
        watches.append(MacBridge.shared.watchAccount { [weak self] account in
            Task { @MainActor in self?.apply(account) }
        })
        watches.append(MacBridge.shared.watchProfiles { [weak self] list in
            Task { @MainActor in self?.rawProfiles = list; self?.rebuildProfiles() }
        })
        watches.append(MacBridge.shared.watchAvatars { [weak self] map in
            Task { @MainActor in self?.avatarURLs = map; self?.rebuildProfiles() }
        })
        watches.append(MacBridge.shared.watchAddons { [weak self] list in
            let rows = list.map { Self.row($0) }
            Task { @MainActor in self?.addons = rows }
        })
    }

    private func rebuildProfiles() {
        profiles = rawProfiles.map { p in
            ProfileInfo(index: Int(p.profileIndex), name: p.name, colorHex: p.avatarColorHex,
                        avatar: (p.avatarUrl ?? p.avatarId.flatMap { avatarURLs[$0] }).flatMap(URL.init(string:)),
                        pinEnabled: p.pinEnabled)
        }
        if let active = activeProfile, let fresh = profiles.first(where: { $0.index == active.index }) { activeProfile = fresh }
    }

    private func apply(_ account: MacAccount) {
        phase = account.phase
        email = account.email
        isAnonymous = account.isAnonymous
        switch account.phase {
        case "signedOut":
            profileFlowUser = nil
            activeProfile = nil
            stage = .signedOut
            if DebugHarness.anonymous { continueWithoutAccount() }
        case "signedIn":
            guard profileFlowUser != account.userId else { return }
            profileFlowUser = account.userId
            beginProfileFlow()
        default:
            break
        }
    }

    /// Loads the profiles, then either opens the only one or asks who is watching.
    private func beginProfileFlow() {
        MacBridge.shared.pullProfiles { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.message = error }
                if (self.profiles.count > 1 || self.profiles.contains(where: \.pinEnabled)) && !self.isAnonymous { self.stage = .choosingProfile }
                else if let only = self.profiles.first { await self.choose(only) }
                else { await self.choose(ProfileInfo(index: 1, name: "Me", colorHex: "#1E88E5", avatar: nil, pinEnabled: false)) }
            }
        }
    }

    /// Makes a profile the active one and opens the app with its add-ons and data.
    func choose(_ profile: ProfileInfo) async {
        await withCheckedContinuation { continuation in
            MacBridge.shared.selectProfile(index: Int32(profile.index)) { continuation.resume() }
        }
        activeProfile = profile
        stage = .ready
    }

    func switchProfile() { if profiles.count > 1 { stage = .choosingProfile } }

    func verifyPin(_ profile: ProfileInfo, pin: String) async -> String? {
        await withCheckedContinuation { continuation in
            MacBridge.shared.verifyPin(index: Int32(profile.index), pin: pin) { continuation.resume(returning: $0) }
        }
    }

    func continueWithoutAccount() { MacBridge.shared.continueAnonymously() }

    func signIn(email: String, password: String) {
        busy = true; message = nil
        MacBridge.shared.signIn(email: email, password: password) { [weak self] error in
            Task { @MainActor in
                self?.busy = false
                self?.message = error
            }
        }
    }

    func signOut() {
        MacBridge.shared.signOut { [weak self] error in
            Task { @MainActor in self?.message = error }
        }
    }

    func addAddon(url: String) {
        busy = true; message = nil
        MacBridge.shared.addAddon(url: url) { [weak self] error in
            Task { @MainActor in
                self?.busy = false
                self?.message = error
            }
        }
    }

    func remove(_ row: AddonRow) { MacBridge.shared.removeAddon(manifestUrl: row.id) }
    func setEnabled(_ row: AddonRow, _ enabled: Bool) { MacBridge.shared.setAddonEnabled(manifestUrl: row.id, enabled: enabled) }
    func refresh() { MacBridge.shared.refreshAddons() }

    /// Debug aid for automated checks: install add-ons (comma-separated URLs) and report what the core loaded.
    func selfTestAddon(_ urls: String) async {
        for url in urls.split(separator: ",").map(String.init) {
            FileHandle.standardError.write(Data("[selftest] installing \(url)\n".utf8))
            addAddon(url: url)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        let summary = addons.map { "\($0.title): \($0.error ?? $0.detail)" }.joined(separator: " | ")
        FileHandle.standardError.write(Data("[selftest] account=\(phase) \(summary) message=\(message ?? "none")\n".utf8))
    }

    private static func row(_ addon: ManagedAddon) -> AddonRow {
        var detail = "Loading"
        if let manifest = addon.manifest {
            detail = "v\(manifest.version)  ·  \(manifest.catalogs.count) catalogs  ·  \(manifest.resources.count) resources"
        } else if addon.errorMessage != nil {
            detail = "Unavailable"
        }
        return AddonRow(id: addon.manifestUrl, title: addon.displayTitle, detail: detail,
                        enabled: addon.enabled, isRefreshing: addon.isRefreshing, error: addon.errorMessage)
    }
}
