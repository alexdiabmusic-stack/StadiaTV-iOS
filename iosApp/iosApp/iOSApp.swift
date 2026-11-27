import SwiftUI
import ComposeApp

@main
struct iOSApp: App {
    @UIApplicationDelegateAdaptor(OrientationLockAppDelegate.self) private var appDelegate

    init() {
        // Connect the shared core (backend config, storage, HTTP) before anything else touches it.
        CoreInstallKt.installBannerCore()
        #if DEBUG
        HybridPlayerSelfTest.runIfRequested()
        // Debug aid: `-BannerAetherProbe YES` loads the AetherEngine framework, creates an engine and logs which FFmpeg answered.
        if UserDefaults.standard.bool(forKey: "BannerAetherProbe") {
            DispatchQueue.main.async {
                let result = BannerPlaybackKitLoader.probeFFmpegBinding()
                NSLog("BannerAetherProbe available=%d contract=%d\n%@", BannerPlaybackKitLoader.isAvailable, BannerPlaybackKitLoader.contractVersion, result)
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    AppUrlBridgeKt.handleAppUrl(url: url.absoluteString)
                }
        }
    }
}
