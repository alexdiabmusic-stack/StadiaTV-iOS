# CarPlay implementation audit

Baseline: 2026-10-14, MyApp scheme, iPhone 17 Pro simulator (iOS 27.0), Xcode BuildProject succeeded with no errors. Working tree was clean before this work.

## Ownership and reuse

| System | Owner and consumers | Findings |
| --- | --- | --- |
| Composition | BannerAppEnvironment | iPhone and CarPlay share stores in one process; no additional App Group is needed for CarPlay. |
| Sports | SportsCore/SportsRepository and league providers/mappers | Used by iPhone, CarPlay, notifications and live activities. Snapshot includes failures; CarPlay currently ignores them. Existing Match and GameSummary names must be preserved. |
| Favourites | PreferencesStore in Preferences.swift | UserDefaults plus existing CloudSyncService; stable team identities. CarPlay reads the same instance but refreshes once per minute. Current match follow action toggles both teams, potentially inverting opposite selections. |
| IPTV | PlaylistStore, EPGRepository, StreamAvailabilityStore, Matching/StreamLinker | Shared parsing, caches, credentials and strict matching. confirmsCurrentBroadcast revalidates event identity immediately before playback. CarPlay currently only checks cached confirmation. |
| Classification | BannerSportsChannelClassifier | Reuses network vocabulary but unrestricted substring checks allow false positives. Sports categories override unrelated channel names. |
| Podcasts | PodcastStore, PodcastIndexService, RSSFeedParser, TeamPodcastResolver, PodcastMatcher | Discovery, metadata, follows, RSS fallback and progress already exist. CarPlay only displays subscribed bundled feeds and tries cached first episodes without loading. |
| Live playback | Playback/PlaybackController, AudioSessionManager | Shared iPhone/CarPlay AVPlayer with bounded reconnects, route and interruption handling. Presentation callbacks are single-owner and can overwrite each other. |
| Podcast playback | PodcastStore | Separate existing AVPlayer and remote targets. Live-to-podcast handoff is incomplete; background progress saves stale currentTime; episode replacement does not first save progress. No authoritative cross-content queue. |
| Now Playing | VideoNowPlaying, CarPlayNowPlaying, PodcastStore | Three publishers and target registrations require explicit ownership. CarPlay publishes playing before readiness and does not follow live score updates. |
| CarPlay | CarPlaySceneDelegate and CarPlayCoordinator | Native list/tab templates, existing scene lifecycle. Current tabs Live/Following/Listen/More; missing runtime list budgeting, episode browsing and meaningful More destinations. |
| Sports Drive | SportsDrivePlayer/ScriptBuilder/Narrator | Existing script system, silent narrator by default; attempts first favourite game without checking confirmation before choosing it. Not a continuous queue. |
| Storage | UserDefaults, file caches, Keychain, CloudSyncService | Reuse current mechanisms. Podcast progress/subscriptions are local; do not claim account synchronization for them. |
| Advanced | LiveActivityManager and BannerLiveActivity target | Existing score activities should be reused. No podcast download manager was found in the inventory. |
| Dependencies | Project package references | No remote Swift package references found in project.pbxproj. Existing native/provider implementations remain authoritative. |

## Architecture

League providers / playlist and EPG stores / podcast discovery / preferences
→ shared repositories and playback ownership
→ iPhone views and CarPlay presentation coordinator

CarPlay remains a presentation scene, not a new API, favourites database or RSS engine.

## Capabilities

MyApp/MyApp.entitlements declares com.apple.developer.carplay-audio and is the signing entitlements file for the app. Info.plist declares background audio and CPTemplateApplicationScene with CarPlaySceneDelegate. App target deployment is iOS 18.0; project-level defaults and other targets differ. A simulator build does not verify Apple's managed entitlement approval, distribution provisioning or real-vehicle behavior. Those remain release checks.

## Duplication and migration priorities

1. Preserve the existing live and podcast engines while establishing exclusive playback and metadata ownership; do not add another AVPlayer to CarPlay.
2. Replace cached-only podcast actions with shared feed loading and episode browsing.
3. Reuse strict broadcast revalidation, including manual alternate selection; never promote possible sources.
4. Replace duplicated raw status composition with shared presentation, retaining sport-specific provider semantics.
5. Consolidate queue/history and recommendation policies in shared services before adding Sports Drive automation.

## Validation gates

Each phase needs a build and targeted tests. Acceptance journeys remain unverified until exercised: podcast start/resume, live handoff, return to podcast, empty favourites, intermission, uncertain broadcast, phone interruption, reconnect, offline downloads, immediate favourites update, older iOS, French, unsupported media. Real vehicle, entitlement approval and signed distribution require external validation. No acceptance item is marked passed merely from compilation.

Advanced parked video is evaluation-only, as requested; no entitlement or vehicle support is assumed. Server-driven Live Activities need separately provisioned infrastructure. These are not implied by the core audio implementation.

## Foundation work in this session

- Added Playback/NowPlayingOwnership.swift. Existing podcast, video and CarPlay publishers transfer system control ownership synchronously; removed the podcast's asynchronous notification-based reclamation. No new media player was added.
- BannerAppEnvironment coordinates exclusive playback between the existing podcast and live engines. PodcastStore saves the actual player position before replacement/background persistence, guards asynchronous artwork by current ownership and episode, and makes remote play/pause commands idempotent.
- NHLLegacyMatchMapper omits stale countdown values during intermission, including from the shared clock model.
- BannerSportsChannelClassifier excludes unrelated categories by channel identity and stops treating arbitrary embedded broadcaster substrings/general-purpose networks as sports proof.
- CarPlayCoordinator exposes Listen Live only for live games with a confirmed cached source, distinguishes empty/failure/favourites states, applies follow/unfollow consistently instead of inverting both teams, and drops cancelled refresh results.
- CarPlayPlaybackCoordinator revalidates event/channel identity through the existing confirmsCurrentBroadcast method before playback or alternate selection. New selections cancel older verification; failed verification leaves current playback intact. Now Playing navigation waits for accepted playback.
- CarPlayNowPlaying observes actual player status and disables unsupported live controls.
- Added CarPlayFoundationTests covering unrelated sports-group channels, dedicated networks, ambiguous broadcaster substrings, ownership handoff, and intermission clock suppression.

Validation: baseline build passed; foundation build and build-for-testing passed before the final broadcast revalidation/metadata-observation edits. The focused test request stalled without reporting results. An alternate iPhone 17 simulator build-for-testing was requested; its result is pending. Do not treat the milestone or any acceptance journey as passed yet.

Localization tooling reported that the project registers only English. Seven new messages use String(localized:); French translations were reviewed, but catalog insertion requires registering French. LocalizationPlanner was requested and is pending. Full French CarPlay coverage remains outstanding.

The implementation continuation below supersedes this initial foundation-only status. Release readiness has not been established.

## Implementation continuation — validation delegated to the user

At the user's request, no builds, automated tests, diagnostics or simulator/device validation were run during this continuation. The following describes code added, not acceptance tests passed.

### Core browsing and shared state

- Rebuilt CarPlayCoordinator around For You, Live, Listen and More using native list/tab templates and the shared Now Playing template. Added runtime list limits, episode pagination, artwork loading, useful empty/error states, and targeted section updates.
- Reused BannerAppEnvironment, SportsDataService, StreamAvailabilityStore, PlaylistStore, PodcastStore, ImagePipeline and PreferencesStore. ChannelPreferencesStore is now shared with the phone; hidden channels, favorites and configured languages affect browsing.
- Added preference/library notifications for immediate scene updates. CarPlay does not maintain a separate sports API, RSS parser, favorites database or player.
- Added MatchAudioPresentation for audio browsing and sports metadata, including intermission, baseball and soccer presentation. Other phone/widget status call sites still need a full migration before claiming one universal formatter.

### Podcasts and listening

- Added PodcastListeningLibrary for persisted episode queue, episode history and autoplay preference. Extended the existing PodcastStore for coalesced feed loads, feed errors/retry, persisted speed including 1.75×, bookmark persistence, completion handling, next/previous controls and interruption intent.
- Added PodcastListeningView and phone episode actions for queue management, listening preferences and downloads. CarPlay exposes followed shows, team discoveries, episodes, resume, history, downloads and Up Next.
- Added AudioRecommendations and replaced SportsDrivePlayer's narrated-script flow with a playable podcast queue. Existing script/narrator files remain available but are no longer invoked by this flow.
- Added PodcastDownloads for ordinary audio-file downloads with persisted metadata, cellular preference and storage limits. Existing PodcastStore selects the saved local asset for playback. Downloads are foreground tasks; background transfer recovery and offline HLS are not implemented. The size budget is checked after transfer, before retaining the file.

### Live playback and Siri

- Preserved confirmed-source verification and the existing shared PlaybackController. Added awaitable verified playback for Siri and cancellation guards for superseded requests.
- Extended CarPlayNowPlaying with availability-gated native sports presentation, favorite indicators, spoiler preference support and periodic authoritative score refresh. Game clocks are paused snapshots refreshed with the feed, not an asserted synchronization with audio. Final scores do not stop postgame audio.
- Added multicast failure observers to PlaybackController so CarPlay no longer overwrites the phone's failure callback. Remote stop clears the live context and metadata polling. Unsupported live seek/speed/queue commands are disabled.
- Added in-app INPlayMediaIntent routing for followed podcasts, resumable episodes and sports channels, plus delegate/plist/Siri-entitlement wiring. Existing App Intents now resolve the requested team and await broadcast verification. Signing, Siri recognition and entitlement availability require user validation.

### Remaining roadmap work

- French catalog population for the new strings; source strings use localization APIs, but French translations are not complete.
- Release feature flags and rollback paths, performance instrumentation, and the full automated/integration acceptance matrix.
- Complete league-wide formatter adoption, richer source failure categories, explicit-content filtering where feed metadata supports it, and broader recommendation/preferences coverage.
- Queue currently contains podcast episodes; a mixed radio/game/podcast queue and optional spoken briefings remain future work.
- Existing local Live Activity infrastructure is reused; no APNs service or promise of continuous suspended-app score updates was added.
- Parked video remains a separate entitlement/vehicle-capability evaluation. Offline HLS and background download recovery are deferred.
- All build, older-OS, real-vehicle, interruption/reconnection, French and end-to-end playback checks remain for the user. No acceptance journey is marked passed by these edits.

## Advanced feature rollout — 2026-10-14

The user excluded French and requested a passing build. French translation work is out of scope for this delivery.

- Added shared persisted CarPlayRollout controls, enabled by default: personalized home, native sports Now Playing, Sports Drive, downloaded-episode browsing and the availability-gated MiniPlayer.
- Added phone controls in Podcasts → Listening → CarPlay. “Use Basic Experience” disables these enhancements without stopping audio or deleting the queue/downloads; “Enable Advanced Experience” restores them. This is a simplified current interface, not restoration of the old coordinator.
- Connected changes to the active scene and immediate sports metadata refresh. Sports Drive checks its switch both before preparation and before starting its queue.
- Corrected SiriKit resume/speed handling to use the SDK's Swift Bool/Double properties.
- Final Xcode BuildProject succeeded with zero errors after all source edits (20.683 seconds). Build log: /var/folders/1y/sv89fsys2gj80vtgv6lwswww0000gn/T/ActionArtifacts/9F72A33D-E36B-4100-A231-4457C0E32A32/BuildProject/BuildProject-Log-20261014-083450.txt.

No test suite or real-vehicle acceptance journey was run. These are local rollout preferences, not a remote staged deployment. Parked video, APNs-driven Live Activities, background downloads and offline HLS remain unimplemented; toggles do not imply those capabilities exist.
