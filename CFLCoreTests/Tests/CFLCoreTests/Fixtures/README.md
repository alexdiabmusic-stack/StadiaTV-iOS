# CFL fixture provenance

Unlike `WNBACoreTests`' fixtures (spec-derived, host unreachable from the sandbox),
every fixture here is a **real response captured live this session** against
`echo.pims.cfl.ca` / `api.stats.cfl.ca` — no field was hand-constructed.

| File | Source | Notes |
|---|---|---|
| `seasons.json` | `GET /api/seasons` | Trimmed to years 2029/2026 — confirms year 2026 → season `ID` 75. |
| `teams.json` | `GET /api/teams` | All 9 teams; `logo_svg` (inline SVG data URI, tens of KB each) stripped — unrelated to any mapper under test. |
| `venues.json` | `GET /api/venues` | All 15 venues. |
| `fixtures-season75.json` | `GET /api/fixtures?season_id=75&limit=200` | All 95 fixtures for the 2026 season — this is also the regression fixture for the pagination trap: `/api/seasons/75/fixtures` and a bare `?season_id=75` (no `limit`) both silently truncate to 15 rows. |
| `fixture-finished.json` | `GET /api/fixtures/6638` | A completed regular-season game — `game_status: "Finished"`, real score, `total_periods`, `game_clock`. |
| `fixture-scheduled.json` | `GET /api/fixtures/6671` | A not-yet-played regular-season game — confirms `game_status` is *absent* (not `"Scheduled"`) before kickoff. |
| `fixture-greycup-tbd.json` | `GET /api/fixtures/6676` | The 2026 Grey Cup fixture (`game_type_id: 6`) — `home_team_id`/`away_team_id` still `null` this season since qualifiers aren't decided yet. |
| `standings-2026.json` | `GET /api/standings/2026` | Real East/West divisions, `place`/`wins`/`losses`/`points_for` etc. |
| `leaders-2026.json` | `GET /api/stats/leaders/2026` (`api.stats.cfl.ca`) | Real offence/defence/special_teams groups. |
| `teamrecords-sample.json` | `GET /api/stats/teamrecords?season_id=75&limit=1` | One team's full ~150-field season record (Argonauts), confirming the schema has no per-fixture scoping. |
| `playerrecords-sample.json` | `GET /api/stats/playerrecords?season_id=75&limit=1` | One player record showing the `fixtures[]` (per-game, has `fixture_id`) vs `seasons[]` (cumulative) split. |
| `roster-team19.json` | `GET /api/teams/19/roster` | Trimmed to the first 6 roster entries — real shape, no `nationality` field present. |

Not captured: a genuinely live in-progress game (none was in progress at capture
time), so `game_status` values beyond `"Finished"` and absent-before-kickoff are
unverified — `CFLFixtureMapper.status` maps a plausible superset and preserves
anything unrecognized via `.unknown` rather than asserting confidence in values
never observed.
