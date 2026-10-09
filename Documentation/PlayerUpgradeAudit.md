# BANNER player audit — 2026-10-08

## Architecture and technical limits

The existing custom `MyApp/PlayerView.swift` is the starting point. It renders AVPlayerLayer through UIKit/AppKit representables and uses the process-owned `BannerAppEnvironment.playbackController`. `PlaybackController`, `PlaybackItemFactory`, `StreamSelectionState`, provider HTTP headers, StreamHealthStore and PlaybackMetrics implement playback, source selection, startup and recovery. No integrated VLC/FFmpeg playback engine was found; VLC strings in playlist parsing are provider header directives.

The application target declares iOS/iPadOS, macOS, tvOS and visionOS. TV has a separate `TV/TVPlayerView.swift` using the same controller implementation. Mac has AppKit layer rendering in PlayerView. These are source-level findings, not device verification. AVFoundation limits source/codec support; DVR, tracks, PiP and representations depend on actual source/platform capabilities. Commercial metadata detection is absent. Hardware simultaneous decoder capacity cannot be inferred merely from platform support.

Shared services to preserve: PlaylistStore and M3U/Xtream adapters; EPGRepository/EPGProgrammeStore/XML parser and TVGuideViewModel; WatchStore forwarding favourites to ChannelPreferencesStore; PreferencesStore; SportsRepository and league services; StreamLinker and StreamAvailabilityStore; MatchNotificationService/Planner; Theme and UI/DesignComponents. PlayerStoreReferences avoids broad player invalidation from imports.

## Feature inventory before changes

“Existing” below means code found; runtime functionality is unverified unless separately tested.

| Feature | Existing implementation | iPhone status | Other platform status | Required action |
|---|---|---|---|---|
| P0.1 Cinematic controls | PlayerView, Theme | Existing, incomplete accessibility auto-hide | Mac shared; TV separate | Preserve styling; prevent hide during interaction |
| P0.2 Channel switching/identity | switchChannel, StreamSelection, PlaybackController, StreamLinker | Existing; async stale updates possible | TV selection disconnected | Guard callbacks and source identity |
| P0.3 Drawer | PlayerChannelListSheet | Existing basic list | TV missing | Extend search, favourites, category, EPG |
| P0.4 Compact guide | PlayerChannelInfoPage now/next | Existing single channel | TV missing | Extend existing drawer using EPG repository |
| P0.5 Controls | PlayerChromeActions, PlayerMoreSheet | Existing pause/mute/volume/zap/PiP/live/tracks | TV subset; Mac subset | Capability checks and integration |
| P0.6 Recovery | PlaybackController | Existing watchdog, delayed spinner, bounded backoff | Shared with TV; tiles bypass it | Reuse controller in tiles; guard old observers |
| P0.7 Orientation/gestures | MatchPlayerScreen, PlayerSurface | Existing fit/fill, rotation, double-tap channel | Mac adaptive layout | Preserve player; no left-swipe exit found |
| P0.8 Remote | TVPlayerView | Not applicable | Existing but incomplete | Channel panel, back handling and focus |
| P0.9 Exit | dismiss, sheet state | Existing; full-screen guide triggers stop | TV Back immediately dismisses | Preserve playback and close panel first |
| P0.10 State | WatchStore, PreferencesStore, aspect defaults | Existing; track preference incomplete | Shared stores | Preserve persistent schemas |
| P1.1 Full guide | TVGuideView/Model, EPGGuideGrid | Existing virtualized time/channel grid, filters, now/details | Shared UI | Fix detail action opening second player |
| P1.2 History/previous | WatchStore, PlayerRecentsSheet | Existing recent/history; previous shortcut incomplete | TV disconnected | Wire existing store |
| P1.3 Favourites | ChannelPreferencesStore via WatchStore | Existing settings action | Shared persistence | Add drawer access/filter |
| P1.4 Settings | PlayerMoreSheet, PlayerAspectMode, StreamMetadataReader | Existing quality caps, tracks, aspect, diagnostics | TV subset | No fabricated delay/DVR capabilities |
| P1.5 PiP/mini player | PlayerSurface/PiPHolder | Existing native iOS PiP | Mac mini player incomplete | Lifecycle validation still needed |
| P1.6 Sports panel | SportGameCentre, league views, SportsRepository | Existing extensive sports UI | TV score only; Mac shared | Prevent spoiler/stale data exposure |
| P1.7 Matching | StreamLinker, confidenceScore, metadataMatchScore | Existing; player accepts weak scores | TV threshold even weaker | Use confirmed linker evidence |
| P1.8 Broadcasts | MatchPlaybackContext, ranked sources | Existing; raw auto failover too broad | Shared selection model | Restrict automatic feed substitution |
| P1.9 Desktop | AppKit PlayerSurface, keyboard handler | Not applicable | Existing incomplete shortcuts/mini-player | Native interactions still need expansion |
| P1.10 Adaptive UI | MatchPlayerScreen, Theme | Existing portrait/landscape | Mac/shared; TV separate | Validate layouts on destinations |
| P2.1 Multiview | MultiScreenPlayerView/StreamTile | Existing 2/4/PiP layouts, audio selection | Shared with TV/Mac | Shared recovery; 3 layout, replacement/save/capacity gaps |
| P2.2 Multiview recommendations | PlayerMultiscreenPicker.loadLiveGames | Existing live game selection | Shared | Confirm access/evidence and favourites priority |
| P2.3 Spoilers | Preferences.spoilerFreeMode | Existing but player ignores it | TV also ignores it | Apply hide consistently; delay absent |
| P2.4 Sports context | liveScoreMatch + game-centre tabs | Existing | TV subset | Invalidate when switching/association expires |
| P2.5 Recommendations | relatedChannels, sports screens | Existing basic same-group/live suggestions | Shared partial | No automatic switching |
| P2.6 Alerts | MatchNotificationService, fantasy live tracker/toasts | Existing | TV watch callbacks disconnected | Respect spoiler settings and wire TV callbacks |
| P2.7 Commercial mode | No reliable detector found | Not implemented | Not implemented | Explicit unavailable integration/settings only |
| P2.8 Customization | Preferences.playerBarActions/panel timeout/buffer, aspect | Existing partial | Shared persistence | Extend without duplicate settings |
| P2.9 Diagnostics | PlaybackMetrics, metadata, health store | Existing partial | Shared controller | Sanitize error descriptions; expand useful status |

## Repairs prioritized

1. Ignore old item callbacks, preflight results, media selection and sports responses.
2. Preserve active playback when full guide is presented; route programme-detail playback through existing selection callback.
3. Reuse confirmed matching rules instead of additive player-only token heuristics.
4. Connect channel panel/history/favourites and TV navigation without creating a new player.
5. Reuse PlaybackController for isolated multiscreen sessions.

## Validation

Build/test/device results and remaining requirements will be recorded in PlayerUpgradeValidation.md. Existing Localizable.xcstrings modifications predate this work and must be preserved.
