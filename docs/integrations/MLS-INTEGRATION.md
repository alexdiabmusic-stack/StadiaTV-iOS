# MLS native integration

Status: native discovery-to-Game-Centre data pipeline verified against the live MLS Sportec stats API; app builds clean on iPhone, iPad, and tvOS; 48 offline fixture tests pass in ~6.3s (plus the pre-existing 42 EPL tests, unaffected). Device/simulator visual interaction (screenshots, focus traversal, VoiceOver playback) was not performed in this session — runtime correctness below was verified via direct `curl` probes against the real API, the offline fixture test suite, and full-project builds on all three destinations, not by driving the UI on a simulator.

**The integration brief's endpoint list is stale.** Every route in it — the entire `stats-api.mlssoccer.com/v1/*` family and the Opta-ID `sportapi.mlssoccer.com/api/matches` / `/api/standings/live` routes — 404s live today. The real, current API was recovered from the MLS website's own webpack bundle (`scripts_react_shared_api_fetching_js`) and then verified request-by-request. It lives on the same `stats-api.mlssoccer.com` host but with **no `/v1` prefix**, and is keyed by **Sportec IDs** (`MLS-MAT-...`, `MLS-COM-...`), not the Opta numeric IDs the brief describes. Every endpoint below is what's actually live, not what the brief assumed.

## Architecture and runtime routing

`SportsRepository` registers `MLSProvider` alongside NHL/MLB/F1/NFL/NBA/EPL (`leaguePath = "soccer/usa.1"`, matching the pre-existing `League.all` entry — MLS was already a first-class league in the app's ontology, just unserved). MLS does **not** get its own Game Centre: it feeds the same canonical Soccer domain (`MyApp/Soccer/Domain/`) and the same `SoccerGameCentreView` that EPL uses.

Making that literal (rather than "MLS reuses EPL's leaf views but forks the shell") required one refactor: `SoccerGameCentreView` used to concretely own an `EPLGameCentreViewModel` and gate on `"soccer/eng.1"`. The polling/reducer/cache plumbing (`EPLGameCentreReducer`, `EPLGameCentreCache`, `EPLGameCentreViewModel`) is now promoted to provider-agnostic `Soccer*` types in `MyApp/Soccer/Services/` (`SoccerGameCentreUpdate`, `SoccerGameCentreReducer`, `SoccerGameCentreCache`, `SoccerGameCentreViewModel`, `SoccerPollingPolicy`), and `SoccerGameCentreView` takes its provider identity (league path, service, cache, polling policy, seed closure) as init parameters. `EPLGameCentreService` now conforms to the shared `SoccerGameCentreServing` protocol instead of defining its own; `MLSGameCentreService` is the second, symmetric conformance. This is the only change to in-flight EPL code in this pass, and the full 42-test EPL suite was re-run clean after it.

```
MLS Sportec JSON → MLSValue (dynamic, defensive)
                → MLS mappers (Status/Clock/Match/Event/Lineup/Stats/PlayerStats/Officials/Commentary/Standings/Shootout)
                → canonical Soccer domain (SoccerMatch, SoccerMatchEvent, SoccerLineup, SoccerTeamMatchStats, SoccerPenaltyShootout, ...)
                → MLSLegacyMapper (bridge into Match/Team/StandingsGroup/RosterAthlete, discovery only)
                → MLSGameCentreService → SoccerGameCentreReducer → SoccerGameCentreSnapshot → SoccerGameCentreView (SwiftUI, shared with EPL)
```

`MatchDetailView` (iOS/iPadOS) and `TVMatchDetailView` (tvOS) both route `soccer/usa.1` into `SoccerGameCentreView`, alongside the pre-existing NHL/MLB/NFL/F1/NBA/EPL branches. No ESPN, no backend, no API key, on any path.

**Identity.** Every MLS ID this provider uses is a Sportec string (`MLS-MAT-...` match, `MLS-COM-...` competition, `MLS-SEA-...` season, `MLS-CLU-...` club, `MLS-OBJ-...` person) — confirmed live. The brief's Opta numeric family (competition `98`) is real (it's still referenced in the site's own embedded config) but **no verified-live route accepts it**; it's carried only as an optional diagnostic on `MLSProviderIDs`, never sent into a Sportec-ID route. `MLSLegacyMapper` mints canonical IDs as `game:league.soccer-usa-1:mls:{matchId}` / `team:...:mls:{clubId}` / `player:...:mls:{personId}`; `SoccerGameCentreView` recovers the raw match ID the same way every other native provider does, via `SportsIdentityResolver.providerID(from:provider:.mls)`.

## Endpoints implemented

All verified live against `https://stats-api.mlssoccer.com` (no `/v1`), competition `MLS-COM-000001` (Regular Season), season `MLS-SEA-0001KA` (2026), 2026-09-23:

- `GET /competitions` — competition registry (regular season, cup playoffs, MLS NEXT Pro, Leagues Cup, CONCACAF competitions, ...).
- `GET /competitions/{id}/seasons` — season registry; current season resolved dynamically (highest `season` year), never hardcoded.
- `GET /clubs/competitions/{c}/seasons/{s}` — club list (`club_id`/`club_name`/`club_short_name`/`club_three_letter_code`).
- `GET /matches/seasons/{seasonId}?match_date[gte]=&match_date[lte]=&competition_id=&team_id=&per_page=&sort=&page_token=` — schedule/scoreboard discovery.
- `GET /matches/{matchId}` — authoritative Match Centre score/clock/status, **and** lineups, formation label, managers, officials, venue, all bundled in one response.
- `GET /matches/{matchId}/key_events?event=&per_page=` — structured timeline (goals/shots/cards/subs/corners/offsides/fouls/kickoff/final whistle); `event=` filters to one bucket, omitted returns all.
- `GET /matches/{matchId}/commentary?language=en&page_token=` — free-text commentary feed, cursor-paginated, per-entry `version` for corrections.
- `GET /competitions/{c}/seasons/{s}/standings?category=&type=&is_live=` — `category=conference` returns Eastern/Western tables; omitted returns the combined/Supporters'-Shield table.
- `GET /statistics/clubs/matches/{matchId}?scope=` — team match statistics (~150 metrics incl. `xG`, `possession_ratio`, `attacking_zones`).
- `GET /statistics/players/matches/{matchId}?per_page=` — every player's match statistics in one call.
- `GET /statistics/clubs/competitions/{c}/seasons/{s}`, `GET /statistics/players/competitions/{c}/seasons/{s}` — season aggregates.
- `GET /statistics/players/{personId}/matches?competition_id=&page_token=` — a player's match log, used for `playerOverview`.

No API key, no auth header observed. No rate-limit headers were observed on any response in this probe session (unlike PulseLive's `x-ratelimit-*`), so `MLSStatsClient` has no rate-limit-state tracker — it still handles a 429 with `Retry-After` client-side cooldown in case one occurs under load, it just doesn't have anything to log proactively. Requests use `.useProtocolCachePolicy`.

## What differs from the reverse-engineered reference doc / brief (verified live, not assumed)

- The entire brief-documented endpoint family (`/v1/*`, Opta-ID `sportapi.mlssoccer.com/api/matches`, `/api/standings/live`) is dead — confirmed by direct request, not inferred. The live API is Sportec-ID based with no `/v1` prefix, recovered from the site's own JS bundle.
- Lineups, formation label, managers, and officials all arrive **bundled in the match overview response** — unlike EPL (and unlike the brief's assumption of separate `/players/matches`, `/managers/matches`, `/officials/matches` routes), MLS needs zero extra requests for any of these.
- `shot_at_goals` key events carry **no `team_id` of their own** — the only event type with this gap. `MLSEventMapper` resolves it via a `person_id → team_id` map built from the same match-overview response, since that's fetched every tick anyway.
- `starting`/`is_on_field` in the lineup payload are the **literal strings** `"true"`/`"false"`, not JSON booleans — `MLSValue.bool` tolerates both forms.
- `attacking_zones[].entries`/`.ratio` are strings (`"6"`, `"11"`) despite being numeric — `MLSValue.double`'s string-parsing path handles it, same mechanism PulseLive needed for its string-encoded IDs.
- No possession time-series exists in this API (the brief's Step 15 5-minute-interval route is gone). Only a single `possession_ratio` per team, plus a 4-zone `attacking_zones` entry-count breakdown — the Overview/Stats UI shows the real zone counts and possession split, and nothing invented in their place.
- Officials' main-referee role is lowercase `"referee"` (not EPL's `"Referee"`), and managers come from `trainer_staff[].role == "headcoach"` — a different field entirely from EPL's officials list.
- `key_events`' `game_section` is camelCase (`"firstHalf"`) vs. EPL's PascalCase (`"FirstHalf"`) for the same concept — `SoccerTimelineView`'s half-grouping and `SoccerEventRow`'s stoppage-minute math were both hardcoded to exact-match EPL's casing; fixed to compare case-insensitively so both providers group correctly through the one shared view.
- Match-level card counts (used for the score-header red-card badge) aren't present in the overview payload at all — defaults to `0` there, same fallback EPL uses when a count isn't otherwise available; the Timeline still shows every red card individually from `key_events`.
- No MLS crest URL is constructible from a bare club ID — the site serves crests from per-club, per-upload Cloudinary hashes with no derivable pattern, and no endpoint in the verified surface returns a logo URL. `MLSAssetResolver.logoURL` returns `nil` unconditionally; MLS team crests don't render until this changes.

## Match identity, status, and clock

- `SoccerMatchStatus` gained four cases for this integration: `extraFirstHalf, extraHalftime, extraSecondHalf, penalties` — additive to the existing enum, so EPL (which never emits them) is unaffected. Only `"scheduled"` and `"finalWhistle"` were directly observed live (one completed regular-season match); every other status string is inferred from MLS's own camelCase convention and matched case-insensitively, falling back to `.unknown(raw)` for anything unrecognized.
- `SoccerMatchClock` parses MLS's own already-stoppage-formatted `minute_of_play` (`"90+7"`, `"45+2"`) directly — never recomputed from wall-clock time, same authority rule as EPL.
- `/matches/{matchId}` is the **sole** score/clock/status authority; `key_events` never feeds the score.

## Events

New `SoccerEventType` cases added for this integration (additive, EPL's mapper never emits them): `shotSaved, shotBlocked, shotOffTarget, woodwork, corner, offside, foul, penaltyWon, penaltySaved`, plus a `priority` (high/medium/compact) used by the Timeline's visual weighting. Confirmed live top-level `key_events` buckets: `kick_off, shot_at_goals, cards, substitutions, corner_kicks, offsides, fouls, final_whistle`. `shot_at_goals`' `shot_result` maps `SuccessfulShot→goal` (or `penaltyGoal` if `origin` mentions "penalty"), `SavedShot→shotSaved`, `BlockedShot→shotBlocked`, `ShotWide→shotOffTarget`; anything else (including post/crossbar, never observed) becomes `.unknown("shot_at_goals:<value>")` rather than a guess. No own-goal, second-yellow, VAR-review, or penalty-won/lost event occurred in the captured match — those branches fall through to `.unknown(type)` and are disclosed as unconfirmed, not silently dropped. Event identity is the provider's own numeric `event_id` (unlike EPL, which has none and must synthesize one); `kick_off`/`final_whistle` are intentionally never emitted as timeline events since they carry no team of their own.

Unlike EPL, MLS needs no separate player-lookup call: every `key_events` entry inlines the name of every player it references, so `MLSEventMapper.playerDirectory(fromKeyEvents:)` hydrates the match's player directory straight from the same response already fetched for the timeline.

## Lineups and formation

MLS supplies only a formation **label** (`latest_line_up`: `"4-3-3"`) with no per-player pitch coordinates or tactical-row grouping at all — a stricter gap than EPL's "missing formation" case, which still had a `players[]` list to fall back on for starter/sub membership. `MLSLineupMapper` builds `SoccerFormation(raw: "4-3-3", rows: [])` — the label displays, `SoccerFormationPitchView` (which already falls back to a starting-XI list whenever `rows.isEmpty`, unchanged) simply never renders a pitch for an MLS match. Starters/substitutes group by `playing_position` when supplied, or one undivided list when it isn't; nothing is positioned that wasn't given. An unannounced lineup (empty `players[]`) maps to `nil`, same convention as EPL.

## Match statistics

`MLSStatKeyMapper` maps confirmed Sportec keys (`possession_ratio`, `xG`, `shots_at_goal_sum`, `shots_on_target`, `shots_at_goal_wide`, `shots_at_goal_blocked`, `corner_kicks_sum`, `passes_sum`, `passes_successful_sum`, `crosses_sum`, `interceptions_sum`, `defensive_clearances`, `tackling_games_air_won` → `aerialDuelsWon`, `fouls_sum`, `offsides`, `goalkeeper_saves`, `cards_yellow`, `cards_red`, `distance_covered`, `advanced_stats.ball_recovery_time`) into `SoccerTeamMatchStats`, plus the new `attackingZones`/`distanceCovered`/`ballRecoveryTime` fields added to that struct for this integration (additive, nil/empty for EPL). `tackling_games_air_*` is genuinely aerial-duel data despite the "tackling" name — a Sportec naming quirk, not a bug — and there is no confirmed ground-tackle count in this payload, so `tackles`/`tacklesWon`/`duelsWon`/`bigChancesCreated`/`bigChancesMissed`/`touchesInOppositionBox`/`expectedGoalsOnTarget` stay `nil` rather than guess. `MLSPlayerStatsMapper` does the same for the new `SoccerPlayerMatchStats` type (goals, assists, shots, passes completed, fouls, cards confirmed; shots-on-target, pass accuracy, tackles, interceptions, duels, and saves unconfirmed at player scope and left `nil`).

## Commentary, officials, standings, shootout

Commentary paginates on `next_page_token`; correction is via a per-entry `version` field, which the existing identity-based reducer merge already handles correctly (a later poll's entry for the same `event_id` simply replaces the earlier one — no new reducer logic needed). Officials come bundled in the match overview (`referees[]`); all 6 roles from one real match confirmed live: `referee, firstAssistant, secondAssistant, fourthOfficial, videoReferee, videoRefereeAssistant`. Standings split into Eastern/Western conference tables via `category=conference` (each table's own `group` field is already the display label) or a combined table when omitted — `SoccerStandingsTable` gained an additive `groupLabel` field for this, and `SoccerLiveTableView`/`MLSLegacyMapper.standingsGroups` both use it so MLS is never forced into a single EPL-style 1–30 table.

**Penalty shootout support is unverified against real data.** No MLS playoff/shootout match was available to capture during this integration. The route (`key_events?event=penalties`) and its empty-response shape (`{"events":[],...}`) were confirmed live for a non-shootout match; the per-kick outcome field name is a best-effort guess among several candidates (`scored`, `penalty_result`, `outcome`). This ships as a disclosed gap, not a confirmed feature — `MLSShootoutMapper`'s doc comment says so explicitly, and `SoccerPenaltyShootout`/`SoccerPenaltyKick` (new, additive domain types) and `SoccerPenaltyShootoutView` (new, shared — reusable by any competition that can go to penalties, not MLS-specific) are otherwise ready the moment real data can be captured and the field name corrected.

## Polling and caching

Same `SoccerGameCentreViewModel` loop EPL uses, parameterized by a `SoccerPollingPolicy` (new, additive — `.epl` and `.mls` presets currently identical: 10s live, 25s halftime, 25–300s pregame by time-to-kickoff, 30s delayed/suspended, exponential backoff on failure, stopped entirely once `stopsPolling`). `MLSGameCentreService.fetch()` gates each resource independently: match overview every tick; key events on the Timeline/Overview tab or a full refresh; team stats on Stats/Overview/full; player stats only on Stats/full (never every live tick regardless of tab, per the brief's "don't overfetch" instruction); conference standings only while live and only on a full refresh; shootout only when `status == .penalties`. A full refresh of a finished match makes exactly 5 requests (overview, events, team stats, player stats, commentary) — confirmed by the mocked network test's exact response-queue ordering.

Cache: `SoccerGameCentreCache` (promoted, additive `provider:` parameter) namespaced per provider on disk — `Caches/BannerTV/Soccer/MLS/v1/{matchId}.json` for MLS, `Soccer/EPL/v1/...` for EPL, so the two can never collide. Discovery caches in `MLSProvider`: same-day scoreboard 10s, date-range schedule 120s, teams 24h, standings 15min, season-ID resolution 24h (network-backed, unlike EPL's pure calendar math, since Sportec season IDs are opaque strings with no derivable pattern).

## Game Centre UI

Reuses every existing Soccer Game Centre view unchanged in structure — `SoccerScoreHeaderView`, `SoccerOverviewView`, `SoccerLineupsView`/`SoccerFormationPitchView`, `SoccerStatsView`, `SoccerCommentaryView` — with additive extensions where MLS genuinely needs more than EPL: `SoccerOverviewView` now shows manager names (from lineup data) and renders conference standings tables instead of a single flat one when present; `SoccerStatsView` gained an "Attacking Zones" section (entry counts, shown only when a provider supplies them); `SoccerLiveTableView` shows a conference/group label when one exists instead of a plain "TABLE"; `SoccerTimelineView` gained an All/Goals/Shots/Cards/Subs/Set Pieces filter (default "All" — the clean default view is unaffected) and extra-time sections alongside the existing half grouping; `SoccerEventRow` renders the new shot/set-piece event types as compact rows. One new shared view, `SoccerPenaltyShootoutView`, renders only when `SoccerGameCentreSnapshot.penaltyShootout` is non-nil. `SoccerGameCentreView` itself is no longer EPL-specific — it takes provider identity as parameters, so both league branches in `MatchDetailView`/`TVMatchDetailView` construct the exact same view type.

**Accessibility.** Not independently re-audited in this pass beyond what the EPL work already fixed in the shared views (which MLS inherits unchanged): score digits scale with Dynamic Type, goal/substitution player links remain independently reachable, Timeline section headers carry `.isHeader`. The new MLS-specific additions (attacking-zone rows, conference table labels, shootout kick rows) follow the same patterns as their EPL-shared siblings (`accessibilityLabel` on shootout kicks states player name and scored/missed explicitly) but were not run through a VoiceOver/Dynamic Type audit tool in this session — disclosed, not silently skipped.

## Platforms

iPhone, iPad, and tvOS all build clean (`BuildProject` verified on iPhone 17 Pro, iPad Pro 13-inch, and the tvOS Simulator generic destination in this session). A second `SoccerGameCentreView` call site existed on tvOS (`TVMatchDetailView.swift`) that the initial iPhone-only build didn't catch — found and fixed via the tvOS build, not assumed correct by inspection. Visual/interactive verification on an actual simulator session (screenshots, focus traversal, scrolling) was not performed.

## Tests

`MLSCoreTests/` — a standalone SwiftPM package mirroring `EPLCoreTests/`/`MLBCoreTests/` exactly: production sources symlinked (not copied) into `Sources/MLSCore`, Swift Testing, offline, no live servers required. Symlinks cover the MLS API/Mapping/Services layer plus the shared Soccer domain and the newly-promoted Soccer services — deliberately excluding `MLSLegacyMapper`/`MLSAssetResolver`/`MLSProvider`, which bridge to app-wide `Match`/`Team`/`League` models unavailable standalone, mirroring EPLCore's identical exclusion of `EPLLegacyMapper`/`EPLAssetResolver`/`EPLProvider`. **48 tests across 9 suites, ~6.3s** (the pre-existing 42 EPL tests re-run clean after the Phase 1 refactor, unaffected — 90 tests total across both packages). Fixtures are real captured payloads from one live match (Inter Miami CF 2–2 San Diego FC, `MLS-MAT-0009LX`, 2026-09-20) plus a 5-entry schedule window and a 3-club page: schedule, match overview, 78-event key-events feed, commentary, team match stats, all-40-players match stats, club list, and both standings shapes (conference-split and combined). Coverage: status/clock mapping (confirmed + inferred statuses, stoppage-time parsing, case-insensitivity), match fixtures (schedule + overview normalization, player-team map, club mapping), events (real 78-event match, team resolution for the team-id-less `shot_at_goals` bucket, structured sub player-in/out never aliasing, stable/unique event identity, unknown-type preservation, directory hydration from inline names), lineups (real formation label with deliberately-empty rows, not-announced → nil, head-coach-role manager), stats (real xG/possession/attacking-zones, unconfirmed metrics staying nil), officials/commentary (real 6-official list, stable commentary identity, blank-text skip), standings (combined vs. conference-split, group labels), reducer (stale/mismatch rejection, event merge/correction, lineup regression guard, officials-never-cleared, commentary sort, player-directory merge, **and** the three new merge behaviors this integration added — conference standings independence, player-match-stats replace, penalty-shootout presence), and networking (429/no-local-retry, MLS's `error_code`/`message` 400/404 shape, malformed-JSON decode error, bounded 503 retry, cancellation, one-resource-failure-doesn't-fail-the-whole-fetch with the exact 5-call ordering a full MLS refresh makes).

Run offline:
```
./MLSCoreTests/run-tests.sh
```
Optional live smoke (hits the real API — resolves the current season, finds a recent finished match, runs a full `MLSGameCentreService.fetch`):
```
MLS_LIVE_SMOKE=1 ./MLSCoreTests/run-tests.sh
```
The live-smoke path was not exercised in this session (same sandboxed-shell network restriction noted in `EPL-INTEGRATION.md`) — the identical live connectivity was independently proven throughout this session via direct `curl` probes against every endpoint listed above, using real match/season/competition IDs.

Not covered by fixtures (disclosed gap, not silently skipped): abandoned/postponed/suspended/delayed match states (no real MLS match in any of those states was available to capture — covered only by inline synthetic `MLSValue` literals for the status-string mapping logic itself, not end-to-end fixture flows), extra-time and penalty-shootout states end-to-end (modeled on the shared domain for future cup/playoff competitions but never exercised against real MLS extra-time/shootout data), and the true concurrent game-switch race (the reducer's `matchID`-mismatch and stale-timestamp guards are unit-tested individually; the generation-token race guard in `SoccerGameCentreViewModel.run()` is shared, unchanged code already relied upon by EPL/MLB/NBA, not independently re-exercised here).

## Unmapped / unconfirmed provider fields

- Every non-`"scheduled"`/`"finalWhistle"` `match_status` value (in-play halves, extra time, penalties, postponed/suspended/delayed/abandoned/cancelled) is inferred from MLS's camelCase naming convention, not directly observed live.
- Own-goal, second-yellow, VAR-review, and penalty-won/lost/saved raw event vocabulary in `key_events` is unconfirmed — no such event occurred in the one match captured.
- The penalty-shootout per-kick outcome field name is an unconfirmed guess among several candidates — see the dedicated callout above.
- `tackles`/`tacklesWon`/`duelsWon`/`bigChancesCreated`/`bigChancesMissed`/`touchesInOppositionBox`/`expectedGoalsOnTarget` have no confirmed key in the team-stats payload.
- `shotsOnTarget`/pass-accuracy/tackles/interceptions/duels/saves have no confirmed key in the *player*-stats payload (team-stats equivalents are confirmed).
- No MLS roster/squad-list endpoint was found in the verified surface — `MLSProvider.roster(teamID:)` returns an empty result rather than guessing at an unverified route; season club/player statistics endpoints exist and are used for `playerOverview` instead.
- No crest/logo URL field or derivable pattern exists anywhere in the verified surface — `MLSAssetResolver` returns `nil` unconditionally.

## Production / licensing

`stats-api.mlssoccer.com` is undocumented, unauthenticated private web infrastructure behind mlssoccer.com — not a published commercial API. This implementation keeps every MLS-specific detail (host, paths, response shapes, key names) inside `MyApp/MLS/`; the canonical Soccer domain and Game Centre UI never reference it directly, so a licensed feed could replace `MLSProvider`/`MLSGameCentreService` without touching the domain models or any view — the same isolation guarantee `EPL-INTEGRATION.md` makes for PulseLive. Before any production/commercial use of this path, a data license should be reviewed independently of this code change.
