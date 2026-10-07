# WNBA native integration

Status: implemented and unit-tested offline; live network verification against
`cdn.wnba.com`/`stats.wnba.com` was not possible this session (both hosts are
blocked from this sandbox — see Validation below) and is explicitly disclosed
rather than claimed.

## Runtime architecture

WNBA is layered onto a new shared `MyApp/Basketball/` module extracted from the
existing native NBA integration (Part A0 of this work). The shared layer holds
the canonical domain (`BasketballGame`, `BasketballGameSnapshot`, `NBAPlayEvent`,
`NBAPlayType`, box-score/leader rows), the reducer, cache, view model, legacy
mapper, and the Game Centre UI — all parameterized by `BasketballLeagueConfiguration`
(`.nba` / `.wnba`) rather than duplicated. `NBAGameCenterService` and the new
`WNBAGameCenterService` are the two conformers of one `BasketballGameCenterServing`
protocol. `WNBA*` files (API/DTO/Mapping) are a genuinely separate layer from
`NBA*` per the brief's explicit instruction, even though the schema is currently
believed identical — a schema divergence later doesn't require touching NBA code.

Game identity: `BasketballGameID(league: .wnba, providerID: gameId)` — the
10-digit provider ID is preserved verbatim and can never collide with an NBA
`BasketballGameID` even if the raw numeric strings happened to match, because
the `league` tag is part of equality.

## Endpoints

- `GET cdn.wnba.com/static/json/liveData/scoreboard/todaysScoreboard_10.json`
- `GET cdn.wnba.com/static/json/liveData/boxscore/boxscore_{gameId}.json`
- `GET cdn.wnba.com/static/json/liveData/playbyplay/playbyplay_{gameId}.json`
- `GET cdn.wnba.com/static/json/staticData/scheduleLeagueV2.json` (current season only — `stats.wnba.com/stats/scheduleleaguev2` is retired and intentionally never called)
- `GET stats.wnba.com/stats/leaguestandingsv3`, `/stats/commonplayerinfo`, `/stats/playercareerstats`, `/stats/commonteamroster` (standings/rosters/player profiles only)

League ID `"10"` lives in one place (`WNBAEndpoint.leagueID`), never scattered
across call sites. `WNBAStatsClient` is never called by the live poll loop —
`WNBAGameCenterService` only talks to `WNBALiveCDNClient`, so a `stats.wnba.com`
outage cannot affect live score/PBP.

## Refresh and cache

Reuses `BasketballGameCenterViewModel`'s adaptive interval, tuned per league:
live polling backs off on repeated failures the same way NBA's does; standings/
rosters/player profiles are cached in `WNBAStatsClient` at minute-plus TTLs and
fetched only by `WNBAProvider`'s discovery-layer calls, never by the Game Centre
poll loop. Atomic JSON snapshots live under `Caches/BannerTV/WNBA/v1`.

## Data and UI

Reuses the shared Basketball Game Centre wholesale: score header, quarter-score
grid, Overview/Play-by-Play/Box Score/Stats tabs, on-court lineups, game leaders
as supplied by the scoreboard (never independently computed), and playoff series
context (`seriesGameNumber`/`seriesText`/`seriesConference`/`poRoundDesc`/`seed`)
passed through verbatim from `WNBAGameMapper`.

Play-by-play reuses `NBADuration.clockText(seconds:)` for the shared sub-minute
tenths display (`"0:29.8"`), `BasketballCourtCoordinateTransformer` for the
optional shot chart, and `BasketballPlayDescriptionBuilder` for human-readable
play text — none of this is WNBA-specific, all of it is exercised by both the
NBA and WNBA test suites. Actions are merged by `actionNumber`/`orderNumber`/
`actionId`, never by description text, so a replay-review correction replaces
rather than duplicates.

Arbitrary overtime is supported structurally (quarter/period is just an int with
no cap), unlike a hardcoded single-OT assumption.

## Validation

- 27 offline Swift Testing tests pass (`WNBACoreTests`), covering scoreboard/box
  score/play-by-play mapping, status boundaries (scheduled/pregame/live/halftime/
  final/unknown), every documented play-action type including unknown-type
  survival, the sub-minute clock-tenths case, current on-court lineup population,
  playoff series metadata pass-through, and the reducer's anti-regression checks
  (stale score rejection, foreign-team-ID rejection, play-list never shrinking).
- `NBACoreTests` (58 tests) still passes unchanged after the A0 generalization —
  the regression gate for "extracting the shared layer didn't break NBA."
- Full `BuildProject` succeeds with WNBA wired into `SportsRepository`,
  `MatchDetailView`, and `TVMatchDetailView`.
- **Not verified this session**: any live response from `cdn.wnba.com` or
  `stats.wnba.com`. Both were probed directly from this sandbox —
  `cdn.wnba.com` returned an Akamai bot-detection 403 (the same failure class
  `cdn.nba.com` already exhibits and that `NBALiveCDNClient`/`WNBAAPIError.blocked`
  already handle), and `stats.wnba.com` served the marketing site's HTML instead
  of JSON. All WNBA JSON-shape assumptions come from the integration brief's
  explicit field list plus the already-shipped NBA parsing code the brief says
  WNBA mirrors — fixtures are disclosed as brief-derived, not live-captured.

## Known limits / remaining verification

- Live-network shape verification against the real WNBA CDN/stats hosts is
  outstanding (see above) — if the real payload differs from the documented
  shape in any field name, only `WNBA*` mapping files need to change, never
  the shared Basketball layer.
- The pre-existing ESPN-based WNBA fallback path noted in project memory should
  be checked for overlap with this native provider — not investigated as part
  of this pass.
- tvOS focus behavior and on-device polling/scroll behavior are unverified,
  consistent with the same disclosed gap in `NFL-INTEGRATION.md`/`NBA-INTEGRATION.md`.

## Files

Shared (`MyApp/Basketball/`, extracted from NBA-only code, now used by both leagues):
`Domain/{BasketballLeagueConfiguration,BasketballGame,BasketballBoxScore,BasketballPlay}.swift`,
`Mapping/{BasketballCourtCoordinateTransformer,BasketballPlayDescriptionBuilder,BasketballLegacyMapper,NBADuration}.swift`,
`Services/{BasketballGameCenterServing,BasketballGameCenterReducer,BasketballGameCenterViewModel,BasketballGameCenterCache}.swift`,
`UI/{BasketballGameCenterView,BasketballGameHeaderView,BasketballLineScoreView,BasketballGameLeadersView,BasketballPlayByPlayView,BasketballPlayRow,BasketballShotChartView,BasketballBoxScoreView}.swift`.

WNBA-specific (`MyApp/WNBA/`):
`API/{WNBAAPIError,WNBAEndpoint,WNBALiveCDNClient,WNBAStatsClient}.swift`,
`DTO/{WNBAValue,WNBAScoreboardDTO,WNBABoxScoreDTO,WNBAPlayByPlayDTO,WNBAScheduleDTO,WNBAStatsTableDTO,WNBAPlayerDTO,WNBARosterDTO}.swift`,
`Mapping/{WNBAStatusMapper,WNBAGameMapper,WNBABoxScoreMapper,WNBAPlayMapper}.swift`,
`Services/{WNBAGameCenterService,WNBAProvider}.swift`.

Tests: `WNBACoreTests/` (symlinked-source `swiftc`-direct package mirroring
`NBACoreTests`'s convention) — `DirectRunner.swift`, `run-tests.sh`,
`Tests/WNBACoreTests/{WNBATests,WNBAGameCenterReducerTests,WNBAServiceRoutingTests}.swift`,
`Tests/WNBACoreTests/Fixtures/*.constructed.json` + `Fixtures/README.md`.

App wiring: `MyApp/SportsCore/{SportsRepository,SportsDomain}.swift`,
`MyApp/MatchDetailView.swift`, `MyApp/TV/TVMatchDetailView.swift`.
