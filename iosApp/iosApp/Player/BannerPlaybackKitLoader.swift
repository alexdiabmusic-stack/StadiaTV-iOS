import BannerPlaybackContract
import Foundation

/// Finds BannerPlaybackKit, the iOS 18+ framework that holds AetherEngine.
///
/// The framework is embedded in the app but deliberately not linked: AetherEngine requires iOS 18.0 and the app still supports
/// iOS 16.1. It is therefore loaded by name at run time, and only where the OS can run it. On older systems (or if the
/// framework is missing) `entry` is nil and playback stays on libmpv, which is always present.
enum BannerPlaybackKitLoader {
    /// The framework's `BannerPlaybackKitEntry` class, or nil when AetherEngine cannot be used on this device.
    static let entry: NSObject.Type? = {
        guard #available(iOS 18.0, *) else { return nil }
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        guard let bundle = Bundle(url: frameworks.appendingPathComponent("BannerPlaybackKit.framework")), bundle.load() else { return nil }
        return bundle.classNamed("BannerPlaybackKitEntry") as? NSObject.Type
    }()

    static var isAvailable: Bool { entry != nil }

    /// The contract version the loaded framework speaks (0 when unavailable). Bump both sides together.
    static var contractVersion: Int {
        guard let entry, let value = entry.value(forKey: "contractVersion") as? Int else { return 0 }
        return value
    }

    /// The contract version this app speaks. The framework must report the same, or AetherEngine is not used.
    static let expectedContractVersion = 2

    /// The factory that creates AetherEngine playback surfaces, or nil where AetherEngine cannot be used.
    @MainActor
    static func makeFactory() -> BannerPlaybackBackendFactory? {
        guard let entry, contractVersion == expectedContractVersion else { return nil }
        let selector = NSSelectorFromString("makeFactory")
        guard entry.responds(to: selector) else { return nil }
        return entry.perform(selector)?.takeUnretainedValue() as? BannerPlaybackBackendFactory
    }

    /// Verifies which FFmpeg the engine bound to. Must run on the main thread. Returns the engine's own `[FFmpeg]` line(s).
    @MainActor
    static func probeFFmpegBinding() -> String {
        guard let entry else { return "BannerPlaybackKit is not available on this device" }
        let selector = NSSelectorFromString("probeFFmpegBinding")
        guard entry.responds(to: selector), let result = entry.perform(selector)?.takeUnretainedValue() as? String else {
            return "BannerPlaybackKit does not answer probeFFmpegBinding"
        }
        return result
    }
}
