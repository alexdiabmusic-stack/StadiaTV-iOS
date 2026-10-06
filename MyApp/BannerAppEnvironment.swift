import Foundation
import Combine

/// Owns the single instance of each app-wide shared store so every scene — the phone's
/// `WindowGroup` and the CarPlay `CPTemplateApplicationScene` — reads and drives the same
/// sports/EPG/playback state instead of each spinning up its own copy (and its own polling).
///
/// `MyApp` wraps these in `@StateObject` so SwiftUI observes them as before; CarPlay reads
/// `BannerAppEnvironment.shared` directly since it has no SwiftUI environment of its own.
/// Constructed eagerly: the first access happens while `MyApp`'s own stored properties are
/// being set up, which runs at process launch regardless of which scene triggered it.
@MainActor
final class BannerAppEnvironment: ObservableObject {
    static let shared = BannerAppEnvironment()

    let preferences = PreferencesStore()
    let playlistStore = PlaylistStore()
    let podcastStore = PodcastStore()
    let epgRepository = EPGRepository()
    let guideStore = GuideChannelStore()
    let streamStore = StreamAvailabilityStore()
    let eventChannelRefresh = EventChannelRefreshService()

    /// The single `AVPlayer`-owning controller shared by the phone's `PlayerView` and
    /// CarPlay's `CarPlayPlaybackCoordinator`. Centralizing it here — rather than each
    /// surface constructing its own `PlaybackController` — is what makes continuity actually
    /// work: whichever surface starts a stream, the other sees the same `channel`/`state`/
    /// `currentItem` and can attach a video layer (phone) or just leave it audio-only
    /// (CarPlay) without re-resolving or restarting anything.
    let playbackController = PlaybackController()

    /// The match/channel currently playing live sports audio or video, set by whichever
    /// surface (phone player or CarPlay) starts a live-game stream. Lets the other surface
    /// offer continuity instead of re-resolving and restarting playback from scratch.
    @Published private(set) var activeLivePlaybackContext: MatchPlaybackContext?

    /// Set by any surface that receives a `banner://game/{eventID}` link — a notification
    /// tap, a Live Activity tap, or a Siri/App Intent — and observed by `RootView` to open
    /// the right game screen. One shared router instead of each surface building its own.
    @Published var pendingDeepLink: BannerDeepLink?

    /// Set by a Siri/App Intent (e.g. "Show my live games") that needs the app foreground
    /// and on a specific tab. `RootView` observes this and clears it after switching.
    @Published var requestedTab: AppTab?

    private init() {}

    func noteActiveLivePlayback(_ context: MatchPlaybackContext?) {
        activeLivePlaybackContext = context
    }
}
