# iPhone Duo implementation

Status of the BannerTV adaptation for the foldable iPhone Duo. Only items marked **verified** were actually exercised; everything else is source-level work that still needs a device/simulator pass.

## Audit (Phase 0)

| Area | Finding |
|---|---|
| Lifecycle | SwiftUI `@main` `App` + `WindowGroup`; `UIApplicationDelegateAdaptor` for the app delegate; CarPlay scene declared in `Info.plist`. |
| Navigation | `RootView` (`ContentView.swift`) uses `TabView` with `.tabViewStyle(.sidebarAdaptable)` and five `Tab`s (Home, Following, Live, Discover, Settings). The system owns tab-bar placement. |
| Playback | `PlaybackController` owns the single `AVPlayer`. It is created once in `BannerAppEnvironment.shared.playbackController`; every `PlayerView` init attaches that shared instance. Presentations (about ten `fullScreenCover` sites) therefore re-attach rather than restart. `TVPlayerView` (tvOS) and multiview tiles build their own controllers by design. |
| Launch screen | `UILaunchScreen` declared. |
| iPad orientations | All four declared. |
| `UIRequiresFullScreen` | Not in `Info.plist`; project-level build settings were not confirmed. Left untouched. |
| Legacy APIs | No `UIScreen.main`, `topLayoutGuide`/`bottomLayoutGuide`, or orientation *reads*. `requestGeometryUpdate` in `PlayerView.requestOrientation` is a request, not a layout read. |
| Idiom checks | `Theme.isPad` was used for layout in ~10 places (see below). |
| SDK | Xcode 27.1 (27A9275). iOS Simulator SDK 27.2 contains `ReservedRegion`, `GeometryProxy.reservedRegions`, `ArrangementView`, `arrangementViewStyle`, and the UIKit equivalents. |

## Work done (Phase 1, in progress)

- `MyApp/Adaptive/AdaptiveLayout.swift`: `bannerReadableWidth(_:)`, a size-class-driven width cap replacing `Theme.isPad ? N : .infinity`.
- `MyApp/Adaptive/AdaptiveLayoutContext.swift`: `\.adaptiveLayout` environment value carrying size, active division frames, active occlusion frames, `foldAxis`, `isExpanded`. Reads `reservedRegions` behind `#if os(iOS)` + `#available(iOS 27.1, *)`. Injected once in `RootView`.
- `Theme.isPad` layout uses replaced with `horizontalSizeClass` in: `MoreView`, `FantasyDashboardView`, `BannerFantasyHubView` (x2), `GolfTournamentCentreView`, `MatchesView` (`FollowingNewsCard`), `HomeView` (`TeamMatchupHero`, `EventHero` card height).

## Work done (Phases 2-3, source-level)

- `MyApp/Adaptive/AdaptiveTwoPane.swift`: `AdaptiveTwoPane` stacks `primary` then `secondary` normally and places them in two columns when `adaptiveLayout.prefersTwoPane` (width >= 700 and the fold is not a tabletop hinge). Columns are separated by at least the vertical fold's width. `hasSecondary: false` keeps one column.
- Phase 2: Home (overview | live + schedule), Following (hero + coming up | news + standings), Live > Sports (live games | starting soon), Live > Guide (grid with an inline `ProgrammeDetailSheet` pane instead of a sheet; the picker use via `onChannelSelected` keeps the sheet).
- Phase 3: `GameCentreSplit` (`MyApp/Adaptive/GameCentreSplit.swift`) puts the hero and watch card in a scrolling column beside the tabs in NHL, MLB, NFL, CFL, F1, Basketball and Soccer; their `wide` checks are off while two-pane. Golf's `Theme.isPad` split-leaderboard check now uses `adaptiveLayout`.
- Phase 3: generic `MatchDetailView` fallback (event, watch sources, head-to-head | game centre, play-by-play, news).

## Player: Watch + Game Centre / Sports Desk (source-level)

- `MatchPlayerScreen` (`PlayerView.swift`) picks an arrangement from `\.adaptiveLayout`: `.sideBySide` (video beside the game centre, on an unfolded Duo or a vertical fold, with the fold gap between), `.tabletop` (video above the horizontal hinge, game centre below it), `.classic` (the previous behaviour). Only when a match is attached. The arrangements switch through `AnyLayout`, so the video container keeps its identity; the `AVPlayer` already lives in the shared `PlaybackController`, so no session is created.
- `ArrangementView` / `.arrangementViewStyle(.split)` exist in the 27.1 SDK (`SwiftUICore` swiftinterface), but I did not adopt them: I couldn't verify how they behave without a fold, so the hinge handling uses `reservedRegions` geometry instead.
- Discover's two-column grid now follows available width (`adaptiveLayout.isExpanded`) instead of only the size class.

## Not done
- Live > Channels master/detail with preview, EPG preview pane and the 20k-channel profiling.
- Home "featured game" ranking, duplicate empty-state consolidation, schedule time wrapping, article categorisation audit, new Duo settings, French strings for new UI.
- No tests were added or run.

- Live > Channels (`LiveBrowserView`) is unchanged.
- Golf's centre is one scroll view, so its watch card is not beside the tabs; only its split leaderboard became width-driven.
- "Sports Desk" does not exist in the codebase and was skipped.

## Not yet done / unverified

- Phases 1-3 and the player arrangement compile (`BuildProject` succeeded), but nothing has been run on a simulator or device, so the two-pane layouts have not been seen.
- `Theme.scaled(_:)` and `ContentView`'s `.dynamicTypeSize(Theme.isPad ? ...)` still use the idiom.
- The assumption that `ReservedRegion.frame` is in the proxy's local space is untested.
- Navigation-overlap fix: manual bottom compensation exists (`Spacer(minLength: 80)` in the Fantasy views, `.padding(.bottom, 120)` at `MatchesView.swift:1064`, `.padding(.bottom, 100)` at `TVGuideView.swift:1494`). The overlap itself has not been reproduced, so these were not changed.
- No tests added yet; unit-test targets exist (`MyAppTests`, `MyAppUnitTests`, `MyAppUITests`).
