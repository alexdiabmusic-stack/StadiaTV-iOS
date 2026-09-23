# Native NHL integration

The intentional provider deletions are preserved. `SportsRepository` now registers native providers explicitly; NHL is the first configured sport. Other leagues report an unavailable provider until their replacements are supplied. Existing shared display models and player/team destinations are retained.

## Data flow

`api-web.nhle.com` → defensive NHL DTOs → hockey normalization → canonical app/game-centre state → native SwiftUI views.

- Direct URLSession async/await, URLComponents, 15-second request timeout, cancellation, typed errors and decoding logs.
- At most two retries after transient failures; HTTP 429 uses Retry-After, including HTTP dates, and shared client backoff.
- NHL discovery IDs remain provider-qualified throughout navigation. Game Centre rejects mismatched IDs, cancelled generations, regressing game clocks/periods and older event streams.
- Landing, box score, play-by-play and right-rail are fetched together; endpoint failures stay independent. Scoring summary remains available when play-by-play fails.
- No NHL backend, API key, scraping, proxy, or primary ESPN NHL call was added.

## Endpoints

| Endpoint | Use |
| --- | --- |
| `/score/now`, `/score/{date}` | Discovery, native IDs, live scores/clock/period |
| `/schedule/{date}` | Schedule discovery |
| `/gamecenter/{id}/landing` | Overview, scoring, supplied goal highlights |
| `/gamecenter/{id}/boxscore` | Skaters and goalie statistics |
| `/gamecenter/{id}/play-by-play` | Ordered events and roster-based player resolution |
| `/gamecenter/{id}/right-rail` | NHL team-game comparisons including power play and faceoffs |
| `/standings/now` | Standings and current team catalog |
| `/roster/{abbreviation}/current` | Existing team roster destination |
| `/player/{id}/landing` | Existing player detail destination |

## Live state and caching

| State | Refresh |
| --- | --- |
| Active live play-by-play | 10 seconds |
| Other active live Game Centre tabs | 18 seconds |
| Intermission | 30 seconds |
| Pregame | 90 seconds |
| Final | Stop after refresh |
| Background | Cancel polling |
| Foreground / connection recovery | Immediate refresh, subject to Retry-After |

Failures back off to at most 120 seconds, with longer Retry-After respected. A single view-owned task coordinates polling. Filters are local. New events are deferred while reading older events, with a jump-to-live action. Scores cache for 10 seconds; schedules for 120 seconds; standings for 15 minutes; rosters for an hour. Game Centre snapshots use memory and atomic JSON files in the app caches directory; saved state shows its timestamp until refreshed. There is no new database.

## UI

Persistent score header and team navigation; Overview, Play-by-Play, Box Score and Stats; period-grouped timeline; local goal/penalty/shot/hit filters; goal assists, strength and available media; player navigation; optional correctly oriented rink location; shootout rounds; arbitrary overtime periods; loading, empty and endpoint-specific retry states. iPad adds a context column at sufficient width. tvOS has focusable filters, event/detail columns and expandable box-score buttons. Dynamic text styles, labels, symbols, minimum targets, reduced-motion handling and spoiler preferences are included.

Supported events: goals, shots on goal, missed/blocked/failed shots, penalties (including bench and served-by), hits, faceoffs, giveaways, takeaways, stoppages, delayed penalties, period boundaries, shootout completion, game end and unknown future event types. `typeDescKey` takes precedence over numeric codes; event IDs plus sort order reconcile refreshes.

## Validation

- The iPhone rebuild eventually succeeded with no reported errors (confirmed through Xcode build logs). A final incremental check is running.
- tvOS simulator builds passed, including the platform-compatibility changes. Subsequent concurrency, stale-clock and accessibility refinements still need a final build verification.
- All 24 offline Swift Testing tests passed in three suites, including parameterized endpoint-isolation and strict clock-regression coverage, plus actual in-flight URLSession cancellation. The standalone runner now compiles each module in one frontend job to reduce repeated compiler startup. The final run passed all 24 tests in 34.208 seconds.
- The networking boundary also passed standalone Swift 6 type checking with MainActor default isolation and a nonisolated service consumer.
- Native Swift live-network smoke check: discovered game 2023020573, loaded 343 plays, 40 player rows, 10 team comparisons and 3 scoring-summary goals, with no endpoint errors. Scores-now, schedule, standings, roster and player endpoints also succeeded.
- Xcode's active app test plan contains no test targets. The independent `NHLCoreTests` package compiles symlinks to the production core. Run `swift test --package-path NHLCoreTests`, or `bash NHLCoreTests/run-tests.sh` with `DEVELOPER_DIR` pointing to the chosen Xcode when nested macro sandboxing prevents SwiftPM execution.
- Fixtures cover pregame, regulation, intermission, final, overtime and shootout. Regulation/intermission fixtures are explicitly documented variations of a captured NHL response. Tests require no NHL server.
- iPhone simulator connection attempts failed. An iPad workspace session was created, but disappeared before its first capture; cleanup confirmed it no longer existed. No runnable tvOS simulator is installed. iPhone/iPad layout and tvOS remote-focus behavior remain unverified.

## Outstanding acceptance checks

This is not an end-to-end completion claim. Finish the final incremental platform build checks and verify live navigation, layout, scrolling and focus on functioning iPhone, iPad and Apple TV devices/simulators. No mock runtime data or fabricated video links were used to bypass these checks.

## Fields genuinely absent in some responses

Coordinates, player headshots, per-event shots, explicit goal modifiers, highlight URLs and recap URLs are not universal. The UI omits unavailable data. Numeric video/content IDs alone are not converted into fabricated replay links. Unknown player IDs display “Unknown player” and are logged in debug builds.

## Files created

- `MyApp/NHL/API/NHLAPIClient.swift`
- `MyApp/NHL/DTO/NHLGameDTO.swift`
- `MyApp/NHL/DTO/NHLValue.swift`
- `MyApp/NHL/Mapping/HockeyModels.swift`
- `MyApp/NHL/Mapping/HockeyPlayDescriptionBuilder.swift`
- `MyApp/NHL/Mapping/NHLGameMapper.swift`
- `MyApp/NHL/Mapping/NHLLegacyMatchMapper.swift`
- `MyApp/NHL/Mapping/NHLPlayMapper.swift`
- `MyApp/NHL/Mapping/NHLSituationParser.swift`
- `MyApp/NHL/Services/NHLConnectivity.swift`
- `MyApp/NHL/Services/NHLFantasyAdapter.swift`
- `MyApp/NHL/Services/NHLGameCenterService.swift`
- `MyApp/NHL/Services/NHLGameCenterViewModel.swift`
- `MyApp/NHL/Services/NHLProvider.swift`
- `MyApp/NHL/UI/NHLGameCenterView.swift`
- `MyApp/NHL/UI/NHLGameHeaderView.swift`
- `MyApp/NHL/UI/NHLPlayByPlayView.swift`
- `MyApp/NHL/UI/NHLPlayEventRow.swift`
- `MyApp/SportsCore/BannerGameStatus.swift`
- `MyApp/SportsCore/ConfiguredSportsProvidersView.swift`
- `MyApp/SportsCore/LocalTeamLogos.swift`
- `MyApp/SportsCore/NativeSportsProvider.swift`
- `MyApp/SportsCore/SportsCapabilities.swift`
- `MyApp/SportsCore/SportsDomain.swift`
- `MyApp/SportsCore/SportsIdentity.swift`
- `MyApp/SportsCore/SportsLegacyMapping.swift`
- `MyApp/SportsCore/SportsRepository.swift`

Tests: `NHLCoreTests/Package.swift`, `DirectRunner.swift`, `run-tests.sh`, `Tests/NHLCoreTests/NHLTests.swift`, `NHLConcurrencyTests.swift`, fixture JSON/README, and symlinks to production sources.

## Existing files modified

- `MyApp/ArticleReaderView.swift`
- `MyApp/ChannelBrowserView.swift`
- `MyApp/DiscoverView.swift`
- `MyApp/Fantasy/BannerFantasyHubView.swift`
- `MyApp/Fantasy/BannerFantasyServices.swift`
- `MyApp/Fantasy/FantasyDashboardView.swift`
- `MyApp/FavoriteEntitiesView.swift`
- `MyApp/GameCentreViews.swift`
- `MyApp/HLSRecorder.swift`
- `MyApp/HighlightsView.swift`
- `MyApp/HomeView.swift`
- `MyApp/LiveBrowserView.swift`
- `MyApp/LiveView.swift`
- `MyApp/MatchDetailView.swift`
- `MyApp/MatchesViewModel.swift`
- `MyApp/PodcastView.swift`
- `MyApp/RecordingsView.swift`
- `MyApp/SettingsView.swift`
- `MyApp/SportsSelectionView.swift`
- `MyApp/TV/TVFollowingView.swift`
- `MyApp/TV/TVHomeView.swift`
- `MyApp/TV/TVLiveTVView.swift`
- `MyApp/TV/TVMatchDetailView.swift`
- `MyApp/TV/TVPlayerView.swift`
- `MyApp/TVGuideView.swift`
- `MyApp/Theme.swift`
- `MyApp/WelcomeView.swift`

Changes outside the NHL flow are narrow build prerequisites: tvOS guards for iOS-only APIs, focusable control alternatives, missing TV player arguments and a malformed existing TV label. iOS behavior is retained behind platform branches. The original staged deletions remain intact.

## Regression verification during MLB integration (2026-09-22)

The latest 25-test NHL suite passed in 3.335 seconds, including scalar safety. Final iPhone and tvOS builds passed with the MLB integration. This supersedes earlier pending build/test notes above. Device interaction remains unverified due to disappearing simulator sessions. NHL connectivity monitoring now aliases the shared SportsConnectivity implementation.
