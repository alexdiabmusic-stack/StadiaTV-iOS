# CFL native integration

Status: implemented and unit-tested against real, live-captured CFL data; no
backend, no ESPN dependency, no committed API key. Play-by-play is a disclosed
gap — see below.

## Runtime architecture

CFL is layered onto a new shared `MyApp/Football/Domain/` module extracted from
the existing native NFL integration (Part B0). Because `echo.pims.cfl.ca`'s
schema shares no vocabulary at all with NFL's Shield API (unlike WNBA's CDN,
which mirrors NBA's), the generalization is narrower than the Basketball one:
only the genuinely league-agnostic leaf types moved to the shared layer —
`FootballLeagueConfiguration`, `FootballFieldGeometry`, `footballOrdinal(_:)`,
`FootballGameStatus`, `FootballTeamState`, `FootballFieldPosition`,
`FootballPlayType` (+ new `.single` case for the rouge), `FootballPlayParticipant`,
`FootballGameDrive`, `FootballPlay` (carries its own `totalDowns`, so a shared
play row can never borrow another league's down count). `NFLGameState` keeps its
own shape (it's genuinely NFL-specific: `week: NFLWeek`, a season+type+week
identity CFL's fixture-based schedule doesn't have) and `CFLGameState` is its
own top-level type — both are built from the same shared leaf types, and the
Football UI leaf views (`FootballFieldView`, `FootballQuarterScoreView`,
`FootballPlayRow`, `FootballDriveView`) are reused verbatim by both leagues'
Game Centres rather than forced through one artificial shared top-level
protocol. This is a deliberate deviation from the original plan's more literal
"`protocol FootballGameCenterServing` shared by both services" — enforcing that
would have meant fabricating a fake week/season identity for CFL's genuinely
different fixture-based schedule model, which is worse than two small,
parallel, honestly-different service types built on shared leaves.

Fixture ID (`echo.pims.cfl.ca`'s own `ID`, e.g. `6638`) is the canonical CFL game
identity — never derived from team+date, never compared against an NFL/ESPN ID.

## Endpoints — every one verified live this session

- `GET /api/seasons` — confirmed year 2026 → season `ID` 75, exactly matching the brief.
- `GET /api/teams`, `GET /api/venues`
- `GET /api/fixtures?season_id={id}&limit=300` — **`limit` is mandatory**: verified that `/api/seasons/{id}/fixtures` and a bare `?season_id=` (no `limit`) both silently truncate to 15 of a season's 95 fixtures.
- `GET /api/fixtures/{id}` — the only route exposing `game_status`/`game_clock`/`total_periods`; the list route doesn't.
- `GET /api/teams/{id}/roster`
- `GET /api/stats/teamrecords?season_id={id}` — season-cumulative only, confirmed by inspecting the real response (no `fixtures[]`/`fixture_id` on this endpoint, unlike player records).
- `GET /api/stats/playerrecords?season_id={id}` — has both fixture-scoped `fixtures[]` (with `fixture_id`) and cumulative `seasons[]`; only `fixtures[]` filtered to the active game is ever used for a box score.
- `GET /api/standings/{year}` — real East/West divisions.
- `GET api.stats.cfl.ca/stats/leaders/{year}` — separate host, offence/defence/special_teams groups; never called by the live Game Centre poll loop.

## CFL rules implemented (never inherited from NFL)

- **3 downs**, not 4: `FootballLeagueConfiguration.cfl.downs == 3`, distinct from NFL's `4`; `FootballPlay.totalDowns` travels with the play itself.
- **110-yard field, 20-yard end zones**, not NFL's 100/10: `FootballFieldGeometry.cfl` produces a genuinely different `ballOffsetFraction`/tick count than `.nfl` for the same "yards to goal" input (regression-tested directly).
- **Rouge/single** is `FootballPlayType.single`, a distinct case from `.extraPoint`, surfaced from team stats' real `singles`/`singlesFieldGoals`/`singlesKickoffs`/`singlesPunts` fields.
- **East/West divisions**, never AFC/NFC — read from the standings response's own `division_name`.
- **Grey Cup** renders as `"GREY CUP"`, never "Super Bowl"/"Championship Round".
- **No fabricated overtime**: `CFLGameState.isOvertime` is `totalPeriods > 4` read from the provider; nothing about CFL's overtime format (no coin toss/kickoff/sudden-death text) is invented.
- **`game_type_id` → CFL terminology**: 0 = preseason, 1 = regular season, 2/3 = the two conference semi-finals, 4/5 = the two conference finals, 6 = Grey Cup (all confirmed against the live 2026 schedule). Which of 2/3 (or 4/5) is East vs. West is **not** encoded in the id — `CFLGameTypeMapper.label` resolves that from the actual participating teams' `team_zone`, never a hardcoded 2→East guess, and correctly falls back to a generic "Division Semi-Final" while qualifiers are still undetermined (verified against the real, still-TBD 2026 Grey Cup fixture).

## Play-by-play: `CFLLivePlayProvider` — deliberately unimplemented this pass

`echo.pims.cfl.ca`'s per-fixture endpoint exposes score/status/clock but no
down/distance/field-position/play data at all (verified against both a
finished and a scheduled fixture) — this is a real gap in the keyless API, not
an oversight. Per the brief, PBP goes through `protocol CFLLivePlayProvider`
(`drives(fixtureID:)`/`plays(fixtureID:)`) rather than a silently-invented
endpoint or HTML scraping. No concrete conformer ships this pass: no verified
keyless PBP route exists, and the legacy authenticated `api.cfl.ca` v1
(`/v1/games/{season}/game/{gameId}`) requires a key that was never supplied and
must never be committed to source control. `CFLGameCenterService` accepts an
optional `livePlayProvider`; when absent, `CFLGameState.drives`/`.plays` simply
stay empty and `CFLPlaysView` shows "Detailed play-by-play is currently
unavailable" — Overview, Box Score, and Stats never depend on it and are fully
functional without it. The protocol carries an explicit comment warning any
future conformer to set `totalDowns: 3`, since copying NFL's mapper unchanged
would silently reintroduce the exact bug this generalization exists to prevent.

## Team/player stats — a disclosed data-availability constraint, not a shortcut

`/api/stats/teamrecords` has no per-fixture scoping in the real schema (only
`seasons[]`), so the Stats tab shows season-to-date team totals, ordered per the
brief's priority (First Downs, Total Offence, Passing/Rushing Yards, Turnovers,
2nd/3rd Down Conversions, Red Zone, Penalties, Time of Possession, Sacks first;
Field Goals/returns/rouge under "More Stats") — never mislabeled as "this
game's stats." Player box-score lines, by contrast, do use the real per-fixture
`fixtures[]` array filtered by `fixture_id`, exactly per the brief, and a
nonexistent fixture id correctly yields zero rows rather than falling back to
season cumulative totals (regression-tested).

## Rosters

`/api/teams/{id}/roster` has no explicit nationality/eligibility field in the
current schema — `state`/`roster_counter` are the closest real fields and are
surfaced as-is rather than interpreted into a National/International
designation that isn't actually present in the data.

## Logos

`logo_svg` is an inline SVG data URI (verified live on every team). The app's
existing team-logo pipeline only rasterizes PNG/JPG from a CDN URL and cannot
render SVG at all — `CFLFixtureMapper.team` resolves to no logo rather than
passing an unrenderable data URI into `TeamLogo`. Disclosed as a real gap, not
attempted this pass (would require a new SVG rendering path, out of scope).

## Refresh and cache

`echo.pims.cfl.ca` only exposes score/status/clock — no down-by-down state — so
`CFLGameCenterViewModel` polls less aggressively than NFL's: live 15s,
halftime 30s, delayed/suspended 45s, pregame 180s beyond 30 minutes / 45s near
kickoff, stopping on final. `CFLClient`/`CFLStatsClient` cache per-endpoint
(teams 1h, venues 24h, team/player records and leaders 15min, fixture list 5min,
single-fixture detail uncached). Atomic JSON snapshots under
`Caches/BannerTV/CFL/v1`.

## Validation

- 20 offline Swift Testing tests pass (`CFLCoreTests`), all built from **real,
  live-captured JSON** (not spec-derived): the 15-vs-95 fixture pagination trap,
  finished/scheduled/Grey-Cup-TBD fixture mapping, every `game_type_id` →
  terminology mapping, East/West-from-`team_zone` (not from the id) division
  labeling, real standings grouping, real league leaders grouping, fixture-scoped
  vs. season-cumulative player stats, season→ID resolution and caching (mocked
  network, real fixture bytes), and `CFLGameCenterService` gracefully degrading
  to empty plays/drives when a PBP provider is absent or fails — never taking
  the score/status load down with it. A separate `CFLRulesTests` suite directly
  compares CFL's config against NFL's (3 vs. 4 downs, 110 vs. 100 yard field
  geometry, distinct rouge/convert play types, per-play down count) so none of
  these could pass by accident if CFL silently reused NFL's config.
- `NFLCoreTests` (22 tests) still passes unchanged after the B0 generalization —
  the regression gate for "extracting the shared layer didn't break NFL."
- Full `BuildProject` succeeds with CFL wired into `SportsRepository`,
  `MatchDetailView`, and `TVMatchDetailView` (the `League(path: "football/cfl")`
  catalog entry already existed before this work).
- **Not verified**: a genuinely live in-progress game (none was in progress at
  capture time), so `game_status` values beyond `"Finished"` and "absent before
  kickoff" are unconfirmed for the exact in-progress string — `CFLFixtureMapper.status`
  maps a plausible superset and preserves anything unrecognized via `.unknown`.

## Known limits / remaining verification

- No play-by-play data source is wired in (see above) — this is the single
  largest functional gap and requires either a newly-discovered keyless PBP
  route or a user-supplied legacy API key before it can be addressed.
- Team Stats tab is season-to-date, not per-game, because the real endpoint
  doesn't support per-fixture scoping.
- Team logos don't render (inline SVG, no rasterizer in the app's image pipeline).
- tvOS focus behavior and on-device polling are unverified, consistent with the
  same disclosed gap in `NFL-INTEGRATION.md`.

## Files

Shared (`MyApp/Football/Domain/`, extracted from NFL-only code, now used by both leagues):
`FootballLeagueConfiguration.swift`, `FootballPlay.swift`.

Shared UI (`MyApp/Football/UI/`): `FootballFieldView.swift` (also defines
`FootballQuarterScoreView`, `FootballPlayRow`, `FootballDriveView`).

NFL files modified for the generalization (types renamed to the shared ones,
behavior unchanged, regression-tested): `Models/{NFLGameState,NFLPlayerStatistics}.swift`,
`Mapping/{NFLGameMapper,NFLPlayMapper,NFLLegacyMapper}.swift`,
`UI/{NFLGameHeaderView,NFLPlaysView,NFLGameCenterView,NFLBoxScoreView}.swift`.

CFL-specific (`MyApp/CFL/`):
`DTO/CFLValue.swift`,
`API/{CFLAPIError,CFLEndpoint,CFLClient,CFLStatsClient}.swift`,
`Models/CFLGameState.swift`,
`Mapping/{CFLFixtureMapper,CFLSeasonIdentity,CFLStandingsMapper,CFLRosterMapper,CFLTeamStatsMapper,CFLPlayerStatsMapper,CFLLeadersMapper,CFLLegacyMapper}.swift`,
`Services/{CFLLivePlayProvider,CFLGameCenterService,CFLGameCenterViewModel,CFLProvider}.swift`,
`UI/{CFLGameHeaderView,CFLPlaysView,CFLBoxScoreView,CFLGameCenterView}.swift`.

Tests: `CFLCoreTests/` (symlinked-source `swiftc`-direct package mirroring
`NFLCoreTests`'s convention) — `DirectRunner.swift`, `run-tests.sh`,
`Tests/CFLCoreTests/{CFLMappingTests,CFLRulesTests,CFLServiceTests}.swift`,
`Tests/CFLCoreTests/Fixtures/*.json` (all real, live-captured) + `Fixtures/README.md`.

App wiring: `MyApp/SportsCore/{SportsRepository,SportsDomain}.swift`,
`MyApp/MatchDetailView.swift`, `MyApp/TV/TVMatchDetailView.swift`.
