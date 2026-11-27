import AetherEngine
import BannerPlaybackContract
import Foundation

/// The one door into BannerPlaybackKit, an iOS 18+ framework that holds AetherEngine.
///
/// The app supports iOS 16.1, which AetherEngine's package floor (iOS 18.0) rules out linking directly, so this framework is
/// embedded but not linked: the app looks the class up by name at run time, and only on iOS 18 or later (see
/// `BannerPlaybackKitLoader` in the app). Everything AetherEngine is confined to this module so the app never imports it;
/// the two sides share only the types in BannerPlaybackContract.
@objc(BannerPlaybackKitEntry)
public final class BannerPlaybackKitEntry: NSObject {
    /// Bumped when the contract between the app and this framework changes.
    @objc public static let contractVersion = 2

    /// The AetherEngine this framework was built against (pinned exactly in the Xcode project).
    @objc public static let aetherEngineVersion = "7.72.0"

    /// The factory the app uses to create playback surfaces. Main thread only.
    @MainActor
    @objc public static func makeFactory() -> AnyObject { AetherBackendFactory.shared }

    /// Creates an engine once and reports the `[FFmpeg]` line the engine logs on first init: the versions of libavcodec,
    /// libavformat, libavutil and libswresample that really answered. A mismatch with the headers the engine was built
    /// against is reported by the engine itself as an `ERROR:` line, which is returned too. Used to prove that the engine
    /// binds to its own `AetherLib*` frameworks and not to the libmpv FFmpeg that lives in the same process.
    @MainActor
    @objc public static func probeFFmpegBinding() -> String {
        var lines: [String] = []
        let lock = NSLock()
        EngineLog.handler = { line in
            guard line.contains("FFmpeg") else { return }
            lock.lock(); lines.append(line); lock.unlock()
        }
        defer { EngineLog.handler = nil }
        do {
            _ = try AetherEngineHolder.shared.engine()
        } catch {
            return "engine init failed: \(error)"
        }
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? "no [FFmpeg] line was logged" : lines.joined(separator: "\n")
    }
}

/// AetherEngine is meant to live for the whole app and be reused for every title, so there is exactly one.
@MainActor
final class AetherEngineHolder {
    static let shared = AetherEngineHolder()
    private var instance: AetherEngine?

    func engine() throws -> AetherEngine {
        if let instance { return instance }
        let created = try AetherEngine()
        instance = created
        return created
    }
}

@MainActor
final class AetherBackendFactory: NSObject, BannerPlaybackBackendFactory {
    static let shared = AetherBackendFactory()

    var engineVersion: String { BannerPlaybackKitEntry.aetherEngineVersion }

    func makeBackend() -> BannerPlaybackBackend? {
        guard let engine = try? AetherEngineHolder.shared.engine() else { return nil }
        return AetherBackend(engine: engine)
    }
}
