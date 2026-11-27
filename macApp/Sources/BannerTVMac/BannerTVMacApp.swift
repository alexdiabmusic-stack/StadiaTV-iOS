import BannerCore
import SwiftUI

@main
struct BannerTVMacApp: App {
    @StateObject private var account = AccountModel()
    @StateObject private var router = Router()
    @StateObject private var data = UserDataModel()
    @StateObject private var home = HomeModel()
    @StateObject private var live = LiveTvModel()
    @StateObject private var sports = SportsModel()
    @StateObject private var arts = CollectionArtCache()
    @StateObject private var liveSources = LiveTvSources()

    init() { Theme.registerFonts(); Core.install() }

    @State private var selection: AppSection = .home
    /// `--play <url>` opens the player test straight away (used for automated checks).
    private let launchURL: URL? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--play"), args.indices.contains(index + 1) else { return nil }
        return URL(string: args[index + 1])
    }()

    /// `--selftest-addon <manifest url>` installs an add-on through the shared core and prints what loaded (automated checks).
    private let addonSelfTestURL: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest-addon"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()

    var body: some Scene {
        WindowGroup("BannerTV") {
            RootView(selection: $selection, launchURL: launchURL)
                .environmentObject(account)
                .environmentObject(router)
                .environmentObject(data)
                .environmentObject(home)
                .environmentObject(live)
                .environmentObject(sports)
                .environmentObject(arts)
                .environmentObject(liveSources)
                .task {
                    account.start()
                    data.start()
                    home.start()
                    live.start()
                    MacBridge.shared.startDiscovery()
                    MacSerializd.shared.onForeground()
                    MacLetterboxd.shared.onForeground()
                    PlaybackRecorder.sink = { request, position, duration, _ in data.recordPlayback(request, position: position, duration: duration) }
                    if let url = addonSelfTestURL { await account.selfTestAddon(url) }
                    await DebugHarness.snapshotAndQuit()
                }
                .frame(minWidth: 1040, minHeight: 680)
                .background(Theme.background)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if account.stage == .ready { data.refresh() }
                    // Send what the integrations have waiting, and read them again when the last read is old.
                    MacSerializd.shared.onForeground()
                    MacLetterboxd.shared.onForeground()
                }
                .onAppear {
                    if launchURL != nil { selection = .playbackTest }
                    if let section = DebugHarness.section { selection = section }
                    if let ref = DebugHarness.openRef { router.open(ref) }
                    if let id = DebugHarness.openGame { router.path.append(.game(id)) }
                    if let id = DebugHarness.openLeague { router.path.append(.league(id)) }
                    if DebugHarness.openSerializd { router.path.append(.serializd) }
                    if DebugHarness.openSerializdAdvanced { router.path.append(.serializdAdvanced) }
                    if DebugHarness.openLetterboxd { router.path.append(.letterboxd) }
                    if DebugHarness.openLetterboxdAdvanced { router.path.append(.letterboxdAdvanced) }
                    if let id = DebugHarness.openCollection { router.path.append(.collection(CollectionRoute(id: id, title: id, blurb: ""))) }
                }
        }
        .defaultSize(width: 1320, height: 840)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { selection = .settings }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                ForEach(AppSection.main) { section in
                    if let digit = section.shortcutDigit {
                        Button(section.title) { selection = section }
                            .keyboardShortcut(KeyEquivalent(digit), modifiers: .command)
                    }
                }
            }
        }
    }
}
