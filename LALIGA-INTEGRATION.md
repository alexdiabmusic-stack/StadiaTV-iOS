# La Liga native integration

Status: official-API + FotMob dual-source data pipeline verified against both live hosts (`apim.laliga.com`, `www.fotmob.com`); 54 offline fixture tests pass in ~3.6s across 19 suites (`LaLigaCoreTests/run-tests.sh`); app-target diagnostics clean on every touched/new file via `XcodeRefreshCodeIssuesInFile`. Device/simulator visual interaction (screenshots, focus traversal, VoiceOver playback) was not performed in this session — correctness below was verified via direct `curl` probes against both real APIs, the offline fixture suite (built with real captured JSON, plus a handful of disclosed hand-modified variants), and per-file compiler diagnostics, not by driving the UI on a simulator or running a full Xcode build across all three destinations. A full `BuildProject` pass across iPhone/iPad/tvOS and a runtime smoke test are the two acceptance items still outstanding — see the bottom of this document.

La Liga is architecturally different from every prior native provider (EPL, MLS): it is the first **two-source** soccer provider. The official LaLiga website API supplies season/schedule/standings/squad data; FotMob supplies live Match Centre enrichment the official API doesn't document. No cross-provider ID reconciliation existed anywhere in this codebase before this integration — it's built from scratch here.

## Architecture and runtime routing

`SportsRepository` registers `LaLigaProvider` alongside NHL/MLB/F1/NFL/NBA/EPL/MLS (`leaguePath = "soccer/esp.1"`, new `League` entry in `Models.swift`). La Liga does **not** get its own Game Centre: it feeds the same canonical Soccer domain (`MyApp/Soccer/Domain/`) and the same `SoccerGameCentreView` that EPL/MLS use, with one additive change — a new optional `.shots` tab, gated behind a new `availableTabs:` parameter on `SoccerGameCentreView` that defaults to the pre-existing five tabs, so EPL/MLS are unaffected.

```
Official LaLiga API (apim.laliga.com)          FotMob (www.fotmob.com)
  → LaLigaValue (dynamic, defensive)              → FotMobValue (dynamic, defensive)
  → LaLiga mappers (Status/Match/Standings/         → FotMob mappers (Status/Clock/Match-overlay/
      Squad/Rounds/PlayerStats/AssetResolver)           Event/Lineup/Stats/Shot/Commentary/Momentum)
        │                                                  │
        └──────────────────┬───────────────────────────────┘
                            ▼
              LaLigaFotMobMatchResolver (Step 16/17/36)
              SoccerProviderMappingStore (persisted id map)
                            ▼
                  LaLigaGameCentreService
             (authority rule: official pre/post-match,
              FotMob score/clock/status kickoff→FullTime)
                            ▼
              SoccerGameCentreReducer → SoccerGameCentreSnapshot
                            ▼
              SoccerGameCentreView (SwiftUI, shared with EPL/MLS)

LaLigaProvider (discovery layer: scores/schedule/teams/standings/roster/playerOverview)
  → LaLigaLegacyMapper → Match/Team/StandingsGroup/RosterAthlete/AthleteOverview
  → SportsRepository → HomeView/MatchesView/LiveView/... (unchanged, generic)
```

`MatchDetailView` (iOS/iPadOS) and `TVMatchDetailView` (tvOS) both route `soccer/esp.1` into `SoccerGameCentreView` with `availableTabs: [.overview, .timeline, .lineups, .stats, .commentary, .shots]`, alongside the pre-existing branches. No ESPN, no backend, on any path — the one real dependency is the LaLiga website's own public APIM key, isolated in `LaLigaProviderConfiguration`.

**Identity.** Every La Liga ID this provider surfaces to the canonical domain is the official API's own numeric ID (as a string) — `opta_id` (`t###`/`p###`) is preferred as the stable cross-endpoint join key wherever the official API itself exposes multiple ID schemes (Step 6), and is what `LaLigaSquadMapper`/`LaLigaLegacyMapper.athlete` use for player identity specifically, since a squad row's own numeric `id` and a player-stats row's numeric `id` were confirmed live **not** to agree for the same person, while both rows' `opta_id` do. FotMob's own numeric match/team/player IDs are never persisted into the canonical domain — they only ever exist inside `SoccerProviderMatchIDs.fotmob` and `SoccerProviderMappingStore`.

## Official endpoints implemented

All verified live against `https://apim.laliga.com/public-service`, header `Ocp-Apim-Subscription-Key`, 2026-09-24:

- `GET /api/v1/competitions` — competition registry; `primera-division` (id 1, `opta_id "23"`) selected, `segunda-division`/`primera-division-femenina`/etc. ignored.
- `GET /api/v1/subscriptions?offset=&limit=` — season-instance registry, 241 entries observed, **mixing every competition the site tracks** (Copa del Rey, UCL, Europa League, even Bundesliga). `LaLigaSeasonResolver` walks it page by page matching `competition.slug == "primera-division"` + `year`, never assuming the `laliga-easports-{year}` naming convention or trusting page order.
- `GET /api/v1/matches?subscription=&competition=primera-division&limit=<=100&offset=` — league fixture list. `laliga-easports-2026` returns exactly **380** rows with this filter (verified). `limit>100` returns HTTP 500 (verified) — every caller clamps to 100. Rows arrive in **descending** date order (offset 0 = the season's last gameweek) — never assumed ascending. `home_score`/`away_score` are **absent entirely** pre-match, mapped to `nil`, never `0`.
- `GET /api/v1/subscriptions/{slug}/standing` — full 20-row table (`played/won/drawn/lost/goals_for/goals_against/points/position` + nested `team{id,slug,name,nickname,shortname,opta_id,shield}`). No `live=true` equivalent exists — Overview/legacy standings are always labelled "LEAGUE TABLE", never "LIVE TABLE" (Step 30).
- `GET /api/v1/teams/{slug}/squad?subscription=` — squad rows nest player identity under `person` (`id`, `firstname`, `lastname`, `date_of_birth` as full ISO datetime, `country.id` as a bare code), with the row's own `opta_id`/`shirt_number`/`position{id,name}`/`role{slug}` as siblings. `role.slug == "jugador"` filters to players; `current == false` (loaned-out/historical) excluded by default.
- `GET /api/v1/subscriptions/{slug}/players/stats?limit=<=100&offset=` — season stat rows, `{id, opta_id, name, position, team, stats:[{name,stat}]}`, 564 players observed across 6 pages. Never fetched in bulk on Game Centre open — only on-demand per player (Step 9), joined on `opta_id`.
- `GET /api/v1/subscriptions/{slug}/rounds` — nests gameweeks inside a round phase; the single "Regular" round currently reports `num_gameweeks: 38`, flattened into `[SoccerRound]` without hardcoding that count (Step 7).

Not implemented — no documented route exists for any of it, and none was invented (Step 10): single-match-by-id, live events, lineups, live commentary, shot map, momentum.

## FotMob endpoints implemented

All verified live against `https://www.fotmob.com`, no auth, 2026-09-24, La Liga league id `87`:

- `GET /api/data/matches?date=yyyyMMdd&timezone=UTC` — day's fixtures grouped by league; La Liga's group filtered by `id == 87 || primaryId == 87`. Used only for match reconciliation (Step 16), not as a schedule replacement for the official API (Step 12).
- `GET /api/data/matchDetails?matchId=` — the primary live enrichment payload: `header.{teams,status}` (score/status/clock baseline), `content.matchFacts.events.events` (structured timeline), `content.lineup.{homeTeam,awayTeam}` (starters/subs/formation/coach/ratings), `content.stats.Periods.All.stats` (sectioned team stats), `content.shotmap.shots`, `content.momentum.main.data`, `content.liveticker.langs` (ticker existence signal, never an actual `ltcUrl` — see below).
- `GET /webcl/ltc/gsm/{fotmobMatchId}_{lang}.json.gz` (on `data.fotmob.com`, not `www.fotmob.com`) — the live ticker, derived per Step 14 since `matchDetails` never supplies a real `ltcUrl`. **Critical correction to the documented pattern**: the lang code embedded in `liveticker.langs` is `"en_gen"`, not the bare `"en"` the reference doc describes — the bare code 403s live. The response is genuine gzip binary (`1f 8b` magic bytes) despite a misleading `Content-Type: application/json` header and no `Content-Encoding` header, so `URLSession` never auto-decompresses it — `FotMobGZip` manually strips the gzip container and inflates via Apple's `Compression` framework (`COMPRESSION_ZLIB`, which is raw DEFLATE despite the name). Verified against a real captured `.gz` fixture, not just unit-level byte manipulation.

Not implemented: `/api/data/leagues` (Step 11) and `/api/data/heatmap/.../heatmaps` were verified reachable during exploration but no canonical domain surface consumes them yet (no heatmap UI exists in this Soccer domain to feed); `liveFixtureApiLink`/`pollFromUtc` on the league payload were confirmed **null** for La Liga at probe time, so `SoccerPollingPolicy.laliga` uses the same status-driven cadence as EPL/MLS rather than depending on those fields (Step 32).

## Season/subscription resolution (Step 2, 38)

`LaLigaSeasonResolver` is a network-resolved `actor` (like `MLSSeasonResolver`, unlike `EPLSeasonResolver`'s pure calendar math) because the correct subscription slug can't be blindly assumed from the `laliga-easports-{year}` naming convention without confirming a live subscription actually exists under that identity — Step 2 explicitly requires walking `/subscriptions` rather than trusting page order or the naming pattern. `startingYear(for:)` uses the same August-boundary rule as `EPLSeasonResolver`: September 2026 → year 2026 (2026/27); February 2027 → still year 2026 (2026/27) — verified this doesn't silently roll over in January.

## Match-ID reconciliation (Step 16, 17, 36, 37) — built from scratch

No prior art existed anywhere in this codebase for cross-provider identity matching (confirmed via full-repo grep for "fotmob": zero hits before this integration). `LaLigaFotMobMatchResolver`:

1. Never matches by score (Step 37) — only competition (implicit, since it only ever queries FotMob's league-87 group), both team names (normalized), and a ±6 hour kickoff window.
2. Requires **exactly one** candidate within that window; zero or multiple candidates both resolve to `nil` rather than guessing (Step 16).
3. Caches confirmed mappings via `SoccerProviderMappingStore` (JSON-on-disk, `Caches/BannerTV/Soccer/LaLiga/idmap/v1/mappings.json`, mirroring `SoccerGameCentreCache`'s per-provider convention) so the same fixture is never re-resolved every poll tick (Step 36).
4. As a side effect of a successful match resolution, also persists the home/away **team**-id mapping (Step 17) — both official and FotMob team IDs are already in hand at that point, so no separate team-resolution round trip is needed.

Team-name normalization (`LaLigaFotMobTeamAliases`) strips diacritics/punctuation/casing (verified live: official "Deportivo Alavés" vs FotMob "Deportivo Alaves" — diacritics silently dropped) plus a small explicit alias table for clubs that differ structurally, not just cosmetically (Athletic Club ↔ Athletic Bilbao, "Futbol Club Barcelona" ↔ "Barcelona", etc.). This is only the first-pass signal — once a match resolves, the confirmed mapping is what's trusted thereafter, never re-derived from names.

Player reconciliation (Step 18, explicitly optional) — `LaLigaFotMobPlayerResolver` matches on normalized full name + shirt number within the same team; ambiguous (duplicate name, no distinguishing shirt number) or no-match cases stay unresolved. This exists as a tested, callable pure function; it is **not yet wired into `LaLigaGameCentreService`'s live poll loop** (the shared reducer/snapshot have no per-player cross-ID field to persist it into — that would be a `Soccer*` domain addition beyond this pass's scope, and Step 18 marks player reconciliation as optional).

## Authority rule for live score/status/clock (Step 19, 37)

Once `LaLigaFotMobMatchResolver` resolves a FotMob id, FotMob becomes authoritative for score/clock/status from kickoff through FullTime; the official fixture remains authoritative before kickoff and once FullTime is confirmed. This is a pure function of the **official** match's own status (never FotMob's), decided fresh each poll from that one status check — never a per-poll coin flip and never toggling on transient FotMob hiccups, since a FotMob outage during the live window simply means `matchDetailsRaw` is `nil` that tick and the previously-established official/FotMob score stays wherever the last successful merge left it (the reducer's own "only overwrite `match` when `update.match != nil`" rule, unchanged from EPL/MLS, handles this without any new logic).

## What FotMob's payload doesn't cleanly hand over — heuristics disclosed

- **Lineup formation rows.** Unlike EPL/MLS, FotMob does not pre-group starters into goalkeeper-first pitch rows — each starter instead carries `verticalLayout.y`/`horizontalLayout` pitch-fraction coordinates. `FotMobLineupMapper` derives row grouping by sorting starters by `verticalLayout.y` (goalkeeper = smallest y, verified against one real lineup) and splitting the remaining 10 into buckets sized by the formation string's own line counts (`"3-5-2"` → `[3,5,2]`). This is a heuristic verified against exactly one real lineup, not a documented FotMob contract — a formation with a differently-oriented coordinate space would need this revisited.
- **Card severity.** `card == "Yellow"` confirmed live; `"Red"` inferred from the same match's one real red card and mapped to `.redCard`; a hypothetical second-yellow encoding (`card` containing both "yellow" and "red") is handled but never observed.
- **Penalty goals / VAR.** `goalDescriptionKey == "penalty"` and a non-null `VAR` field are both handled but never observed live — every goal sampled was open-play or a header, and every event's `VAR` field was `null`.
- **Shootouts.** Never implemented — La Liga league play (`primera-division`) never reaches penalties; events with `isPenaltyShootoutEvent == true` are explicitly dropped from the timeline (mirroring MLS's own disclosed gap here) rather than mapped incorrectly.
- **Team stats.** `tacklesWon` and `finalThirdEntries` have no matching FotMob key in the observed 8-section stat breakdown and are left `nil`, never guessed from an adjacent metric. `crosses` maps to FotMob's "Accurate crosses" (a completed-count, not an attempted-count) since no separate attempted-crosses key exists — disclosed in `FotMobStatsMapper`'s doc comment.
- **Live clock.** `FotMobClockMapper` looks for `liveTime.minute`, a field name inferred from community convention, never confirmed against a real in-progress match (every sample this session was pre-match or finished) — falls back to a static HT/FT/etc. label when absent, never a fabricated minute.

## Caching, polling, resilience (Steps 31–36)

- `SoccerPollingPolicy.laliga` mirrors EPL/MLS's cadence (10s live, 25s halftime, backing off pregame/on failure) — FotMob's own community-observed cache (~10s live) doesn't call for anything faster.
- `LaLigaGameCentreService`'s official-match baseline reuses `LaLigaProvider`'s own 5-minute season-match cache (via the new `LaLigaOfficialMatchSource` protocol seam) rather than re-paginating ~380 fixtures every poll tick — the official API has no single-match-by-id route, only the paginated list, so this was a deliberate design point, not an oversight.
- A stale match (FullTime more than 24h ago) skips reconciliation entirely — no FotMob call is ever made for it.
- Either source failing degrades independently (Step 34/35): a 401 from the official key trips a 10-minute circuit breaker (`LaLigaClient`) rather than retrying every request or asking the user for anything; FotMob failing leaves whatever it last supplied in place per-tab, with the official score/status/venue/matchweek still visible. Both are exercised in the offline test suite via a stubbed `URLProtocol`.
- Every request uses `.useProtocolCachePolicy` (Step 33) — no cache-busting query parameters anywhere in either client.

## Tests (`LaLigaCoreTests/`)

Mirrors the `MLSCoreTests` harness exactly: a standalone SwiftPM package with symlinked sources (not copies) from `MyApp/{LaLiga,FotMob,Soccer}/`, run via `run-tests.sh`'s direct `swiftc` invocation (bypassing SwiftPM's macro-plugin sandbox), plus `DirectRunner.swift`'s `--live-smoke` path. **54 tests across 19 suites, ~3.6s, all passing.**

Excluded from the symlinked sources — same boundary MLS drew, for the same reason (they depend on app-only legacy types not present in the standalone package): `LaLigaProvider.swift` (`NativeSportsProvider`/`Match`/`Team`/`StandingsGroup`/`RosterGroup`/`AthleteOverview`), `LaLigaLegacyMapper.swift` (`League`/`Match`/`Team`/`StandingsGroup`/`RosterAthlete`), `LaLigaPlayerStatsMapper.swift` (`StatValue`). This is why `LaLigaGameCentreService` depends on a new `LaLigaOfficialMatchSource` protocol rather than concretely on `LaLigaProvider` — the protocol has no app-only dependency, so the service itself stays testable outside the full app target; `LaLigaProvider` conforms to it in the app target, and both `MatchDetailView`/`TVMatchDetailView` pass `LaLigaProvider.shared` explicitly (no default parameter, so the default expression itself never has to resolve `LaLigaProvider` inside the symlinked file).

Fixtures: real captured JSON for official competitions/standings (20 rows)/rounds/matches (pre-match + finished)/squad (Real Madrid), and FotMob matchDetails (one full finished match — Alavés 3–0 Getafe, 24 shots, 10 subs, 9 cards, 3 goals) plus the real gzip-compressed live-ticker file for that same match. Two FotMob matchDetails variants (pregame, live-first-half) are **hand-modified from the real finished-match payload** — disclosed here and in the file's doc comment — since no La Liga fixture was pre-kickoff or in-progress at probe time this session.

Not covered by the offline suite (disclosed rather than silently skipped): `LaLigaProvider`/`LaLigaLegacyMapper`/`LaLigaPlayerStatsMapper` (excluded per the symlink boundary above — exercised only via app-target compilation, not unit tests); a genuinely live/in-progress match's real event/clock shape (no such match existed at probe time); FotMob sustained network-level blocking (`.blocked`, as opposed to a 500 or 403) wasn't exercised since simulating a `URLError` through the stub protocol wasn't attempted this pass.

## Acceptance status against the brief's criteria

**Done and verified:** competition/season/subscription resolution; all 380 fixtures paginate; standings (20 rows); rounds; squads; player-stats lookup path; 401 graceful degradation; match/team reconciliation with rejection of ambiguous cases; provider IDs kept separate; mappings cached to disk; score/clock/status/timeline/lineups/formations/stats/xG/shot map/ticker (when available) all map from real captured data; ratings labelled "FotMob Rating"; Overview/Timeline/Lineups/Stats/Commentary/Shots all wired through the shared `SoccerGameCentreView`; official failure doesn't kill FotMob-sourced data and vice versa; no ESPN dependency; no backend.

**Verified this session:** `BuildProject` succeeds clean on iPhone 17 Pro (iOS 27.2 simulator), iPad Pro 13-inch M5 (iOS 27.2 simulator), and Any tvOS Simulator Device (tvOS 27.2) — all three link successfully with zero errors. "Any tvOS Device (arm64)" (a real hardware target) fails, but only on code-signing/provisioning ("no devices from which to generate a provisioning profile") — a pre-existing environment limitation (no Apple Developer device registered), not a compilation error in any La Liga/FotMob/Soccer file.

**Outstanding (explicitly, not silently dropped):**
- No simulator/device runtime pass (Overview/Timeline/Lineups/Stats/Commentary/Shots opened against a real or cached La Liga match) has been performed yet.
- Optional player reconciliation is implemented and unit-tested but not wired into the live poll path (see above).
- VAR, penalty goals, and second-yellow mapping are implemented but unconfirmed against real occurrences — disclosed above, not claimed as verified.
