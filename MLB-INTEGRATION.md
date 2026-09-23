# MLB native integration

Status: native discovery-to-Game-Centre data pipeline verified against MLB; app builds and offline tests pass. Visual interaction sign-off is still pending because the Xcode simulator session disappeared before returning a screen. This is not a claim that all device acceptance criteria have been verified.

## Architecture and runtime routing

`SportsRepository` now registers `MLBProvider` alongside `NHLProvider`. MLB schedules use `sportId=1`; the returned numeric `gamePk` becomes `game:league.baseball-mlb:mlb:{gamePk}`. iOS/iPadOS `MatchDetailView` and tvOS `TVMatchDetailView` route MLB directly into `MLBGameCenterView`. Generic summary loading is bypassed for this specialized surface. Existing premium access, spoiler preferences, streams, fantasy, picks, news, team roster and player destinations are preserved.

The native path is StatsAPI → defensive resource DTOs → baseball normalized models → shared discovery/team/roster/standings models and coordinated Game Centre state → SwiftUI. MLB's fantasy roster path also uses StatsAPI. No ESPN requests, API key, proxy or backend are part of the primary MLB provider.

## Endpoints

- `/api/v1/schedule`: date/range discovery; sportId=1; team, linescore, probable pitcher and broadcast hydration. Endpoint builder also supports teamId, season and gameTypes.
- `/api/v1.1/game/{gamePk}/feed/live`: initial/foreground/recovery snapshot; periodic full reconciliation. Filtered form obtains status and server timestamp during light refreshes.
- `/api/v1/game/{gamePk}/playByPlay`, `/linescore`, `/boxscore`: selected-surface refresh and independent fallback resources.
- `/api/v1/game/{gamePk}/winProbability`: fetched only for the Stats chart, fields-filtered to at-bat index/probability.
- `/api/v1/game/{gamePk}/contextMetrics`: implemented client resource; not polled because no additional context-metrics component currently requires it.
- `/api/v1/game/{gamePk}/content`: supplied HTTPS MP4 highlights in Overview; no invented replay links.
- `/api/v1/leagues?sportId=1`: verifies active major-league metadata for standings.
- `/api/v1/standings`: season, verified league IDs, division/team hydration.
- `/api/v1/teams?sportId=1`, `/api/v1/teams/{teamId}`, `/api/v1/teams/{teamId}/roster`.
- `/api/v1/people/{personId}`: on-demand profile/season stats.

Diff patches are intentionally not implemented; this uses the requested phase-one full-state/light-resource strategy.

## Refresh, correctness and caching

- Live: 10 seconds. Between innings: 25 seconds. Warmup: 25 seconds.
- Delayed/suspended: 30 seconds. Pregame within an hour: 60 seconds; farther away: 300 seconds.
- Final/postponed/cancelled: stop polling after refresh. Background: cancel view-owned task. Foreground/reconnection: refresh immediately.
- Full reconciliation approximately every 120 seconds during a continuous live session; lightweight requests otherwise. Plays/Overview refresh plays; Box Score refreshes box score; Stats requests win probability. Standings never poll with games.
- URLSession timeout 15 seconds; at most two retries with exponential delay; shared client respects numeric/HTTP-date Retry-After cooldown. View-level failure backoff is capped at 300 seconds.
- Generation tokens, cancellation, gamePk validation, server timestamps, request timestamps, inning/at-bat progression checks reject stale or wrong-game updates. At-bats deduplicate by gamePk + atBatIndex, events by gamePk + atBatIndex + event index.
- Atomic JSON snapshots use the existing NHL cache convention under `BannerTV/MLB/v1`, plus memory. Cached games display before refresh and show a saved-data label until accepted fresh data arrives. Final snapshots remain locally cached; the OS can purge its caches directory.
- Discovery cache 10 seconds; range schedules 120 seconds; standings 15 minutes; teams 24 hours; rosters/player overviews one hour.

## Status and play support

Scheduled, pregame, warmup, live, delayed/rain delay, suspended, postponed, cancelled, final and unknown. Detailed MLB status remains available. Doubleheaders retain distinct gamePk values and game numbers; extra innings have no fixed maximum; postseason game types remain preserved.

Home run, single, double, triple, strikeout, walk/intentional walk, hit by pitch, sacrifice fly, double play, field error, stolen base, caught stealing, wild pitch, passed ball, pitching/offensive/defensive substitutions, reviews, outs and unknown future events. Official descriptions are retained; structured pitchers, batters, runners, counts, pitch calls/types/velocity/spin/location and batted-ball distance/exit velocity are normalized where supplied. Player dictionaries are resolved once from game feed data, without per-at-bat profile calls.

## Game Centre UI

Persistent score/inning header; real MLB JPEG team logos; team navigation; base diamond; balls/strikes and three out indicators; Overview/Play-by-Play/Box Score/Stats tabs; inning-grouped at-bats; emphasized scoring; expandable pitches/actions; optional measured pitch locations; deferred new-play insertion and jump-to-live; current/probable matchup; batting leaders; scoring summary; records/venue/weather; real highlights; horizontally scrollable inning linescore; adaptive batting/pitching grids; MLB win-probability chart; wide-iPad context column; tvOS focusable at-bat list/detail panel. Loading, cache, retry and pregame states are implemented. Text styles, named controls, player/team navigation labels and non-color base/out/play indicators support accessibility.

## Validation

- Final iPhone build: passed, 2026-09-22, BuildProject-Log-20260922-081816.txt.
- Final tvOS simulator SDK build: passed, 2026-09-22, BuildProject-Log-20260922-081853.txt. No new MLB warnings in the checked build log; unrelated pre-existing project warnings remain.
- 17 offline Swift Testing tests in three suites passed in 4.357 seconds (parameterized cases additionally cover 12 game states and three base configurations). Fixture tests cover all 19 modeled result variants, real player resolution/pitches, missing data, malformed scalars, doubleheaders, linescore, box score, cache round-trip, wrong/stale games and endpoint versions. URLProtocol tests cover bounded retries, malformed JSON, rate limiting, cancellation, independent resource failure and light-refresh request selection. Lifecycle tests cover late game-switch responses, background/foreground refresh and final/delay/intermission polling.
- 25 NHL regression tests passed in 3.335 seconds.
- Production native Swift live smoke passed: discovered gamePk 744834 from schedule; loaded 61 at-bats, 51 box players, 29 highlights, 61 probability points; light refresh, teams, standings, roster, player and context endpoints succeeded. An earlier native attempt timed out; bounded retries failed cleanly, and subsequent production run succeeded.
- `git diff --check` passed.
- iPad Pro 11-inch (M5) build also passed with zero errors during device verification.
- Device verification: both fresh iPhone and iPad workspace sessions disappeared after successful builds. Immediate InstallAndRun did not produce a usable active launch; captures returned “Session not found.” No screenshots or hierarchy were available. Sessions were cleaned up and iPhone 17 Pro was restored as the destination. iPhone/iPad layout, scrolling and tvOS focus still need functioning device/simulator interaction verification.

Tests use production-source symlinks and local fixtures. Recorded final/schedule payloads are labeled separately from deliberately derived edge-case fixture variations. No fixtures are loaded by the app.

Run offline:
```sh
DEVELOPER_DIR='/Users/alexdiab/Downloads/Xcode-beta 2.app/Contents/Developer' bash MLBCoreTests/run-tests.sh
```
Optional separate live smoke (network deliberately opt-in):
```sh
DEVELOPER_DIR='/Users/alexdiab/Downloads/Xcode-beta 2.app/Contents/Developer' MLB_LIVE_SMOKE=1 bash MLBCoreTests/run-tests.sh
```

## API limitations

Pitch locations, spin, velocity, hit distance/exit velocity, player profile/headshot data, weather, probability and highlights are not universal. Missing values are omitted or shown as unavailable. Highlights are shown in Overview because a reliable universal highlight-to-atBatIndex join is not supplied. Future unknown actions remain represented. No app-generated probability prediction, invented headshot/video URL, runner inference from prose or fabricated scores is used.

## Files created

- `MyApp/MLB/API/MLBAPIClient.swift`
- `MyApp/MLB/API/MLBAPIError.swift`
- `MyApp/MLB/API/MLBEndpoint.swift`
- `MyApp/MLB/DTO/MLBBoxscoreDTO.swift`
- `MyApp/MLB/DTO/MLBContentDTO.swift`
- `MyApp/MLB/DTO/MLBGameFeedDTO.swift`
- `MyApp/MLB/DTO/MLBLineScoreDTO.swift`
- `MyApp/MLB/DTO/MLBPersonDTO.swift`
- `MyApp/MLB/DTO/MLBPlayByPlayDTO.swift`
- `MyApp/MLB/DTO/MLBRosterDTO.swift`
- `MyApp/MLB/DTO/MLBScheduleDTO.swift`
- `MyApp/MLB/DTO/MLBStandingsDTO.swift`
- `MyApp/MLB/DTO/MLBTeamDTO.swift`
- `MyApp/MLB/DTO/MLBValue.swift`
- `MyApp/MLB/Mapping/MLBBoxscoreMapper.swift`
- `MyApp/MLB/Mapping/MLBGameMapper.swift`
- `MyApp/MLB/Mapping/MLBLegacyMapper.swift`
- `MyApp/MLB/Mapping/MLBPlayDescriptionBuilder.swift`
- `MyApp/MLB/Mapping/MLBPlayMapper.swift`
- `MyApp/MLB/Mapping/MLBStatusMapper.swift`
- `MyApp/MLB/Models/BaseballAtBat.swift`
- `MyApp/MLB/Models/BaseballGame.swift`
- `MyApp/MLB/Services/MLBFantasyAdapter.swift`
- `MyApp/MLB/Services/MLBGameCenterCache.swift`
- `MyApp/MLB/Services/MLBGameCenterReducer.swift`
- `MyApp/MLB/Services/MLBGameCenterService.swift`
- `MyApp/MLB/Services/MLBGameCenterViewModel.swift`
- `MyApp/MLB/Services/MLBProvider.swift`
- `MyApp/MLB/UI/MLBAtBatRow.swift`
- `MyApp/MLB/UI/MLBBoxScoreView.swift`
- `MyApp/MLB/UI/MLBGameCenterView.swift`
- `MyApp/MLB/UI/MLBGameHeaderView.swift`
- `MyApp/MLB/UI/MLBGameLeadersView.swift`
- `MyApp/MLB/UI/MLBLineScoreView.swift`
- `MyApp/MLB/UI/MLBPlayByPlayView.swift`
- `MyApp/SportsCore/SportsConnectivity.swift` (shared connectivity monitor).
- `MLBCoreTests/Package.swift`, `DirectRunner.swift`, `run-tests.sh`; three test suites, production source symlinks, and documented local JSON fixtures.

## Existing files modified

- `MyApp/SportsCore/SportsRepository.swift`: provider registration, MLB enrichment and canonical player-stat provider routing.
- `MyApp/SportsCore/ConfiguredSportsProvidersView.swift`: MLB diagnostics.
- `MyApp/PremiumModels.swift`: optional division/league/wild-card/last-ten standing fields.
- `MyApp/MatchDetailView.swift`: MLB route; skip redundant generic summary requests; rename existing generic baseball timeline to avoid collision.
- `MyApp/TV/TVMatchDetailView.swift`: MLB route preserving stream/news content.
- `MyApp/Fantasy/BannerFantasyServices.swift`: MLB roster adapter.
- `MyApp/MatchesView.swift`: narrow tvOS guards for pre-existing iOS navigation/haptics/quick-stream controls that prevented the requested tvOS build.
- `MyApp/NHL/Services/NHLConnectivity.swift`: compatibility alias to the shared monitor; corresponding NHL test source symlink added.
- `NHL-INTEGRATION.md`: validation status updated after regression checks.

Existing intentional provider deletions remain untouched. Other pre-existing workspace modifications were not reset.
