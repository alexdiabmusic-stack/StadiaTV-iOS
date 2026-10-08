# NFL Shield integration

Status: implemented and under validation; full acceptance is not yet claimed.

## Runtime architecture

Native URLSession/async-await calls to api.nfl.com; no Node runtime, ESPN primary path, backend or personal account. Existing SportsRepository and MatchDetailView/TVMatchDetailView route NFL through the native provider. Existing `nfl` provider namespace preserves opaque NFL IDs separately from ESPN IDs.

## Endpoints

- POST /identity/v3/token
- GET /football/v2/weeks/date/{date}
- GET /football/v2/weeks/season/{season}/seasonType/{PRE|REG|POST}
- GET /football/v2/experience/weekly-game-details (season/type/week, drive chart enabled for Game Centre; replay/video/standings extras disabled)
- GET /football/v2/stats/live/game-summaries
- GET /football/v2/standings
- GET /football/v2/rosters
- GET /football/v2/teams/history
- GET /football/v2/teams/{id}
- GET /football/v2/injuries (verified `pageToken` pagination)

Authentication uses the public SportsDataverse WEB_DESKTOP configuration in one file. Tokens stay in memory, refresh 120 seconds before JWT expiry, use a five-minute fallback lifetime, and share an actor-managed mint task. A rejected old token cannot invalidate a replacement. Each data request has at most one authorization retry. Failures back off; HTTP 429 honors Retry-After. GET requests are coalesced and cancel when their last waiter cancels. DEBUG payload recording is opt-in (`NFL_RECORD_PAYLOADS=1`), bounded per response, and never includes token endpoint responses or request headers.

## Refresh and cache

- Live Game Centre: six-second cycle, rich drive package approximately every 12 seconds, lightweight summaries in between.
- Halftime: 25 seconds; delay/suspension: 45 seconds.
- Pregame: 180 seconds beyond 30 minutes, 45 seconds near kickoff.
- Final: fetch final detail package then stop. Background stops the view-owned task; foreground starts an immediate refresh. Connectivity recovery restarts it.
- Atomic canonical JSON snapshots under Caches/BannerTV/NFL/v1, displayed before refresh; final snapshots retained subject to OS cache eviction.
- In-memory HTTP cache: team metadata one day, rosters four hours, standings/injuries 15 minutes, weeks one hour, live summaries five seconds, rich details eight seconds, schedule packages 30 seconds. No extra database.
- Generation checks after every awaited state load and native ID/offset checks prevent stale or cross-game commits.

## Data and UI

Score/quarter/clock/possession/down/distance/goal-to-go/red-zone/field position, quarter scores, venue/weather, native team navigation. Overview, drive-oriented Plays with local filters and corrections, Box Score, Stats. Season/stage/week calendar reaches historical games. Current and completed drives preserve start/end quarter/clock/field, plays, net yards, possession time and result. Unknown plays remain displayable.

Play support includes runs, passes, incompletions, sacks, interceptions, fumbles with separate lost-possession flag, punts, kickoffs, made/missed field goals and extra points, two-point attempts, touchdowns, safeties, penalties, timeouts, kneels/spikes, reviews, quarter/game endings. Accepted/declined/offsetting penalty and review wording comes from the official description, without guessing enforcement.

Typed player totals aggregate supplied GSIS play-stat records: passing, rushing, receiving, defense, kicking and punting. Core totals were checked against the NFL gamebook linked by the actual response. Unknown stat IDs are retained but not assigned invented meanings. Team comparison includes first downs, net passing/rushing/total yards and penalties.

## Validation

- Real native Swift diagnostic loaded 16 games, 323 drives and 2,983 plays for 2025 REG week 1.
- Native calls verified 18 weeks, 16 summaries, standings, 32 rosters, injuries and exact native team identity.
- 22 offline Swift Testing tests pass, including single-flight auth, expiry/401 behavior, rate limiting, game switching, background/foreground, offset protection, corrections/deletions, raw envelope variants, optional/unknown fields, field position and gamebook totals.
- Fixtures include real weekly game, summaries, teams, rosters, standings, injuries, weeks and 23 representative play cases. Status boundary cases are explicitly constructed test inputs, never production mock data.
- Isolated iOS simulator app build passed with unfinished NBA source files temporarily excluded via command-line build settings only. The normal Xcode build remains blocked by missing NBAPlayDescriptionBuilder and NBACourtCoordinateTransformer in NBAPlayMapper.swift.
- iPhone/iPad pregame screens, real NFL schedule and team-roster navigation were observed. Historical populated Game Centre and final UI fixes are still being checked. An isolated arm64 tvOS build passed; tvOS focus has not been observed.

## Known limits / remaining verification

The supplied catalogue does not expose a conventional player-game box-score endpoint. Box scores use verified structured play-stat aggregation; additional obscure/lateral/defensive statistics need broader gamebook regression coverage. Play-clock values, fully structured penalty enforcement, supplied per-play score snapshots, and a standalone explicit current-drive identifier were not present in the sampled responses. The latest drive is used as live drive context only when its reported result does not indicate a completed drive. Replay/tagged-video extras remain off because no highlight feature was added.

Live-game device polling/scroll insertion, tvOS focus, comprehensive accessibility sizes and Instruments profiling remain unverified. This report is not a claim that every requested acceptance criterion has passed.

## Files

Created:
- `MyApp/NFL/API/NFLAPIError.swift`
- `MyApp/NFL/API/NFLClientConfiguration.swift`
- `MyApp/NFL/API/NFLEndpoint.swift`
- `MyApp/NFL/API/NFLShieldClient.swift`
- `MyApp/NFL/API/NFLTokenProvider.swift`
- `MyApp/NFL/DTO/NFLValue.swift`
- `MyApp/NFL/DTO/NFLWeeklyResponse.swift`
- `MyApp/NFL/Mapping/NFLGameMapper.swift`
- `MyApp/NFL/Mapping/NFLLegacyMapper.swift`
- `MyApp/NFL/Mapping/NFLPlayMapper.swift`
- `MyApp/NFL/Models/NFLGameState.swift`
- `MyApp/NFL/Models/NFLPlayerStatistics.swift`
- `MyApp/NFL/Services/NFLGameCenterService.swift`
- `MyApp/NFL/Services/NFLGameCenterViewModel.swift`
- `MyApp/NFL/Services/NFLProvider.swift`
- `MyApp/NFL/UI/NFLBoxScoreView.swift`
- `MyApp/NFL/UI/NFLCalendarView.swift`
- `MyApp/NFL/UI/NFLGameCenterView.swift`
- `MyApp/NFL/UI/NFLGameHeaderView.swift`
- `MyApp/NFL/UI/NFLPlaysView.swift`
- `NFLCoreTests/` — standalone production-source test harness and local fixtures.

Modified for NFL:
- `MyApp/SportsCore/SportsRepository.swift`
- `MyApp/MatchDetailView.swift`
- `MyApp/TV/TVMatchDetailView.swift`

References: attached nfl_api.yaml/nfl_auth.ts/nfl_api.ts and current SportsDataverse sources at https://github.com/sportsdataverse/sportsdataverse-js. The attached SportsDataverse PDF describes ESPN wrappers and was not used as the Shield API specification.
