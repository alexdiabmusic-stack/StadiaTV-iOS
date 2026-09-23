# Native NBA integration

## Verification follow-up — 2026-09-23

- Full iOS simulator `BuildProject` passed again after the verification fixes, with no build errors.
- All **57 offline Swift Testing tests across 10 suites passed**. Two new regressions check that play-by-play returned for another game is rejected, for both CDN and stats responses. The service now validates returned game identity before assigning plays to the requested game.
- Native provider registration and iOS/tvOS Game Centre routing were inspected; NBA routes through `NBAProvider` and `NBAGameCenterView`.
- Live smoke failed: native URLSession timed out requesting the CDN scoreboard. An independent direct CDN probe returned HTTP 403, and the stats scoreboard probe timed out after 10 seconds with no response bytes. Real payload compatibility and populated Game Centre behavior remain unverified; offline fixtures do not establish those claims.
- NBA-scoped `git diff --check` passed. Unrelated pre-existing whitespace findings elsewhere were left unchanged.
- The generic tvOS simulator build passed. No runnable tvOS simulator is installed, so remote-focus interaction remains unverified.
- The verification also corrected NBA mapper actor isolation: shared `League` construction runs on the main actor, while player canonical identity and the pure stats-row accessor remain usable from nonisolated mapping code.
- iPhone 17 Pro installation and launch succeeded. Both screenshot/UI-hierarchy captures timed out before interaction; sessions were closed. Consequently iPhone screen behavior, iPad layout, and populated NBA Game Centre remain unverified. No mocked runtime data or substitute provider was introduced to mask these limits.


Status: implemented, iOS and tvOS builds pass, and the full offline Swift Testing suite passes. **Live NBA data has not been observed from any network this integration was built on** — both `cdn.nba.com`'s data paths and `stats.nba.com` were unreachable from the development machine (see Reachability below). This is not a claim that the integration works against live NBA data end to end; that specific claim is unverified pending the on-device check described below.

## Why this exists

`MyApp/NBA/` shipped as a half-finished slice — API/DTO/Mapping/Models were staged, but two mapper types (`NBAPlayDescriptionBuilder`, `NBACourtCoordinateTransformer`) were referenced and never defined, which broke the whole-app build (the project uses `PBXFileSystemSynchronizedRootGroup`, so every file under `MyApp/` compiles unconditionally). Both `NFL-INTEGRATION.md` and `F1-INTEGRATION.md` recorded their own final builds as blocked behind this. This work finishes NBA to the same standard as the existing NHL, MLB, NFL and F1 integrations, unblocking the build first.

## Architecture and runtime routing

`SportsRepository` registers `NBAProvider()` unconditionally alongside NHL/MLB/F1/NFL. `MatchDetailView` and `TVMatchDetailView` route `basketball/nba` matches into `NBAGameCenterView`, bypassing the generic summary poller (added to the `loadGameSummary()` exclusion list). Canonical IDs follow the existing convention: `game:league.basketball-nba:nba:{gameId}`, `team:league.basketball-nba:nba:{teamId}`, `player:league.basketball-nba:nba:{playerId}`. NBA's league identity (`League.all`, `SportsDataProviderID.nba`, `FantasySport.nba`) already existed before this work and required no changes.

The native path is `cdn.nba.com` / `stats.nba.com` → defensive DTOs (`NBAValue`) → basketball-normalized models (`BasketballGame`, `NBAPlayEvent`, …) → `NBALegacyMapper` bridges into the shared app models (`Match`, `Team`, `RosterAthlete`) → SwiftUI. `MatchLiveContext.basketball` — a pre-existing field with an existing consumer (`BasketballGameCentre` in `PlayerView.swift`) that nothing had ever populated — is now filled in by `NBALegacyMapper`. No ESPN request, API key, proxy, or backend is part of the primary NBA path.

## Two hosts, and why the routing isn't symmetric

- **`cdn.nba.com`**: today's scoreboard, per-game box score (combined with game state — there is no separate lightweight status endpoint), per-game play-by-play, and a current-season-only static schedule file. Reliable and cache-friendly (`URLCache`, ETag/Last-Modified) when reachable.
- **`stats.nba.com`**: schedule (any season), standings, play-by-play v3 (fallback), scoreboard v3 (fallback for non-today dates), player info/career stats, and team rosters. Column-oriented `resultSets` shape. Known to reject non-browser-looking traffic; the client backs off hard rather than retrying aggressively.

Routing table (implemented in `NBAAPIClient`, a façade over both clients):

| Capability | Primary | Fallback |
| --- | --- | --- |
| Today's scoreboard | CDN | stats scoreboard v3 (today) |
| Scoreboard for an arbitrary date | CDN static schedule, filtered, **iff current season** | stats scoreboard v3 |
| Box score | CDN | none — declared single-source |
| Play-by-play | CDN | stats play-by-play v3 (in `NBAGameCenterService`, tagged `playsSource: "stats"`) |
| Schedule, current season | CDN static schedule | stats schedule |
| Schedule, historical season | stats only | — |
| Teams | derived from the current season's schedule (no dedicated endpoint on either host) | — |
| Standings, roster, player info/career stats | stats only | — |

The CDN static schedule (`/static/json/staticData/scheduleLeagueV2_1.json`) and the stats schedule endpoint share the exact same `leagueSchedule.gameDates[].games` envelope, so this fallback needed no new DTO. Fallback only triggers on a host-level failure (`.blocked`, `.http`, `.rateLimited`) — a decoding failure means the response shape itself changed and is left to surface, never silently retried against the other host.

## The empty-vs-blocked contract

**Only an HTTP 200 that decodes successfully may report an empty result.** Every other failure mode throws. This matters concretely: today (deployment-relative) is well into the NBA offseason, and a genuinely empty scoreboard is the *correct* result on an offseason day — it must never be confused with a failed request.

- `NBAAPIError.blocked(host:status:)` is a distinct case from `.http`/`.rateLimited` — it covers a persistent Akamai edge block and an application-layer connection drop, neither of which a quick retry will resolve.
- `NBAProvider.scores(on:)` never catches a failure into `[]`; `SportsRepository.liveMatchSnapshot` turns a throw into a `failures` entry the UI already renders.
- `NBAGameCenterService` captures per-surface failures into `update.errors[key]` (never throws except on cancellation) and folds `.blocked`/`.rateLimited` into `update.retryAfter`.
- `NBAGameCenterView` shows a distinct, Retry-less message ("NBA data isn't available on this network") when every populated error is a host block, since retrying against a persistent 403 is futile.

## Reachability (read this before trusting any "it works" claim)

A live smoke test was run against both hosts from the development machine (egress IP a US datacenter address) on 2026-09-22:

- `cdn.nba.com/static/json/**` (todaysScoreboard, static schedule) → **HTTP 403**, Akamai "Access Denied", for every User-Agent and header combination tried, including the app's own headers and a full browser `Sec-Fetch-*` set.
- `cdn.nba.com/logos/*` and `cdn.nba.com/headshots/*` → **HTTP 200** from the same IP — the host itself is not banned; only the `/static/` data paths are protected.
- `stats.nba.com/stats/*` → **no response at all**. TCP connects (~0.1s), TLS completes (~0.13s), then the connection sits open with no data for 25+ seconds. `stats.nba.com/` (root) returns a normal 301.
- Controls: `www.nba.com`, `statsapi.mlb.com`, `api-web.nhle.com`, `example.com` all responded normally from the same network.

This is consistent with datacenter-IP reputation filtering. nba.com's own web client fetches exactly the blocked `/static/json/liveData/` URLs from ordinary browsers, so a residential or cellular connection is expected to succeed — **but this is an expectation, not a verified fact.** `NBAStatsClient`'s timeout was shortened to 8s and both clients now set a breaker (300s for the CDN 403, 120s for the stats block/timeout) specifically because of this observed behavior, so a blocked network degrades to an honest, rate-limited error instead of a repeated multi-second hang.

`MyApp/NBA/Services/NBAReachability.swift` is a `#if DEBUG`-only manual probe (surfaced as a button in the Sports Data diagnostics screen) that re-runs this exact check. **Run it on a physical iPhone on cellular before trusting that NBA data loads at all in production.**

## Refresh, correctness and caching

- Live, final two minutes of a period at or past regulation: 8s. Live, end of quarter (detected from the newest play's type, falling back to a zero game clock): 20s. Live otherwise: 12s. Halftime: 60s (and does **not** stop polling — `.halftime` is deliberately not in `BasketballGameStatus.stopsPolling`, since halftime length is unpredictable). Pregame: 60s. Scheduled: 300s beyond an hour out, else 60s. Delayed/suspended: 30s. A full (box-score) refresh is forced at least every 120s. Failure backoff is capped at 300s, same shape as the sibling integrations.
- `NBAGameCenterReducer` is a pure, monotonic merge — every rejection returns the prior snapshot unchanged: period never decreases; the game clock (which counts down) can't jump backwards without corroborating evidence (a score change or new plays — a legitimate replay-review correction looks different from stale data); score never decreases unless a fresh box score lands in the same update (an official correction); no regression out of a terminal (`stopsPolling`) status; the play list only ever grows or replaces by matching id (never shrinks); a box score is rejected wholesale if either its own team-container id or any player row's team id doesn't match the game's actual two teams — checked at both levels, since a swapped envelope with zero players would otherwise slip past a player-only check (this exact gap was caught by `NBAGameCenterReducerTests.foreignTeamIDInBoxRejected` and fixed before this document was written).
- Atomic JSON snapshots under `Caches/BannerTV/NBA/v1/{gameId}.json`, the same convention as the sibling integrations. Cached data displays immediately and is labeled with its timestamp until a fresh snapshot lands.

## Data and UI

Score, period/clock, quarter-by-quarter line score, timeouts remaining, bonus indicator, team leaders (with a graceful fallback to the scoreboard's own lightweight leader fields before the box score loads), Overview / Play-by-Play / Box Score / Shot Chart tabs. Box score columns are defined once (`[(label, (NBAPlayerGameLine) -> String)]`) so iOS and tvOS can't render different columns, and a genuinely missing stat renders "—", never a fabricated 0. A half-court shot chart (`Canvas`, no `Charts` dependency) consumes `NBACourtCoordinateTransformer`'s output; shots beyond half-court are excluded from the drawing but counted and labeled rather than silently dropped.

Supported play types: made/missed shots (2 and 3 point, including a fix for a bug where a three with a descriptive `subType` — e.g. "Pullup Jump shot" — was scored as a two because the mapper consulted `subType` before `actionType`), free throws, rebounds, assists, turnovers, steals, blocks, personal/shooting/offensive/technical/flagrant fouls, substitutions, timeouts, jump balls, violations, period boundaries (with a distinct "Halftime" label), instant replay, game end, and an explicit `.unknown(rawValue)` case for anything else — humanized, never dropped. NBA's own live play-by-play `description` text is always preferred verbatim over anything composed from structured fields; composition is a fallback for the rare payload that omits it, and never claims more than the supplied fields say (a free throw, for instance, is never described as "made" or "missed" since the type can't tell the difference).

## Validation

- iOS simulator build: passed (`BuildProject`, iPhone 17 Pro simulator destination).
- tvOS build: passed (`BuildProject`, "Any tvOS Simulator Device (arm64, x86_64)" — no concrete tvOS simulator was runnable in this environment; see Outstanding below).
- Offline suite: **55 Swift Testing tests across 10 suites passed** in ~0.03s total execution (`bash NBACoreTests/run-tests.sh`, `DEVELOPER_DIR` pointing at an installed Xcode). Coverage: coordinate transformer (unit conversion, the zero/zero sentinel vs. a real rim shot, distance-label reconciliation in both directions, reject-don't-clamp for out-of-envelope points, invalid shot-value rejection); play description builder (verbatim preference, composition-on-absence, the halftime label, the full priority table, never dropping `.unknown`); play mapper (dedupe-by-id, the three-point scoring regression fix, sort stability); status/duration mappers; box-score mapper; fixture-driven mapping of scoreboard/schedule/box-score/standings/roster shapes, including one fixture that is a genuinely empty (offseason) scoreboard; a full guard-by-guard suite for the reducer's monotonicity rules; the CDN→stats façade fallback (and that it does *not* fall back on a decoding failure, and never consults stats for box score); and the game-center service's empty-vs-blocked distinction.
- One real defect was found and fixed by this suite before this document was written: the reducer's box-score team-id validation checked only player rows, so a box response with the wrong team ids and zero players would slip through undetected.
- `git diff --check` passed.

Run offline:
```sh
DEVELOPER_DIR='/Users/alexdiab/Downloads/Xcode-beta 2.app/Contents/Developer' bash NBACoreTests/run-tests.sh
```
Optional separate live smoke (network deliberately opt-in; expected to fail from a datacenter network per Reachability above):
```sh
DEVELOPER_DIR='/Users/alexdiab/Downloads/Xcode-beta 2.app/Contents/Developer' NBA_LIVE_SMOKE=1 bash NBACoreTests/run-tests.sh
```

## Fixture provenance

Every fixture under `NBACoreTests/Tests/NBACoreTests/Fixtures/` is **hand-constructed**, labeled `.constructed.json`, and documented in that directory's `README.md` with the mapper/DTO its field vocabulary was derived from. This is a direct consequence of the Reachability section above: nothing could be captured live. **The offline suite proves the mappers and reducer obey their own contracts; it does not prove the wire format matches NBA's actual responses.** Wire-format fidelity is unverified pending a live check from a network that can reach both hosts.

## Outstanding acceptance checks

This is not an end-to-end completion claim. Specifically unverified:
- Any actual response from `cdn.nba.com` or `stats.nba.com` — see Reachability.
- Device/simulator interaction: no concrete tvOS simulator was runnable in this environment (only the generic "Any tvOS Simulator Device" build destination), and no iPhone/iPad session was attempted for this feature. Layout, scrolling, and tvOS remote focus for the new UI are unverified.
- The exact `stats.nba.com` header names used in `NBAProvider.standings()` and `NBAProvider.roster(teamID:)` (`leaguestandingsv3` / `commonteamroster`) are sourced from public documentation of the endpoints' shape, not a captured response, and are called out as unverified in code comments at both call sites.
- Runtime click-through of `NBAGameCenterView` itself: not exercised, since there is no way to reach a real NBA match right now (regular-season offseason plus both hosts blocked from this network).

## Files created

- `MyApp/NBA/Mapping/NBACourtCoordinateTransformer.swift`
- `MyApp/NBA/Mapping/NBAPlayDescriptionBuilder.swift`
- `MyApp/NBA/Mapping/NBALegacyMapper.swift`
- `MyApp/NBA/DTO/NBARosterDTO.swift`
- `MyApp/NBA/Services/NBAProvider.swift`
- `MyApp/NBA/Services/NBAConnectivity.swift`
- `MyApp/NBA/Services/NBAGameCenterService.swift`
- `MyApp/NBA/Services/NBAGameCenterReducer.swift`
- `MyApp/NBA/Services/NBAGameCenterCache.swift`
- `MyApp/NBA/Services/NBAGameCenterViewModel.swift`
- `MyApp/NBA/Services/NBAFantasyAdapter.swift`
- `MyApp/NBA/Services/NBAReachability.swift`
- `MyApp/NBA/UI/NBAPlayRow.swift`
- `MyApp/NBA/UI/NBAPlayByPlayView.swift`
- `MyApp/NBA/UI/NBALineScoreView.swift`
- `MyApp/NBA/UI/NBABoxScoreView.swift`
- `MyApp/NBA/UI/NBAGameLeadersView.swift`
- `MyApp/NBA/UI/NBAShotChartView.swift`
- `MyApp/NBA/UI/NBAGameHeaderView.swift`
- `MyApp/NBA/UI/NBAGameCenterView.swift`
- `NBACoreTests/` — standalone production-source test harness, fixtures, and README.

## Existing files modified

- `MyApp/NBA/Mapping/NBAPlayMapper.swift` — the three-point scoring fix, and a shared `sorted(_:)` comparator now used by both the mapper and the reducer.
- `MyApp/NBA/API/{NBAAPIClient,NBAAPIError,NBAEndpoint,NBALiveCDNClient,NBAStatsClient}.swift` — the routing table, the `.blocked` error case, the CDN static-schedule and stats roster endpoints, and the shortened stats timeout with its own breaker.
- `MyApp/NBA/Mapping/NBAGameMapper.swift` — a `games(_:)` entry point for the raw per-game values `NBAAPIClient.scoreboard(on:)` returns.
- `MyApp/NBA/DTO/NBAStatsTableDTO.swift` — a `field(_:)` accessor on `[String: NBAValue]` rows.
- `MyApp/SportsCore/SportsRepository.swift` — NBA provider registration, box-score-based match enrichment, and the player-stats provider-id ladder.
- `MyApp/SportsCore/ConfiguredSportsProvidersView.swift` — an NBA diagnostics row and a `#if DEBUG` reachability probe section.
- `MyApp/MatchDetailView.swift`, `MyApp/TV/TVMatchDetailView.swift` — NBA Game Centre routing, and the `loadGameSummary()` native-league exclusion list.
- `MyApp/Fantasy/BannerFantasyServices.swift` — the NBA roster adapter hook (the NBA fantasy scoring strategy was already wired).

Existing intentional provider deletions and other pre-existing workspace modifications were not touched.
