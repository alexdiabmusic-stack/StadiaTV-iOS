# EPL native integration

Status: native discovery-to-Game-Centre data pipeline verified against the live Premier League PulseLive/SDP API; app builds clean on iPhone, iPad, and tvOS; 42 offline fixture tests pass in ~6.4s. Device/simulator visual interaction (screenshots, focus traversal, VoiceOver playback) was not performed in this session — the runtime correctness below was verified via direct code execution (`RunCodeSnippet`) against the real API and via the offline test suite, not by driving the UI on a simulator.

## Architecture and runtime routing

`SportsRepository` registers `EPLProvider` alongside NHL/MLB/F1/NFL/NBA (`leaguePath = "soccer/eng.1"`, matching the existing `League.all` entry). The provider layer speaks the app's legacy models (`Match`/`Team`/`StandingsGroup`/`RosterGroup`/`AthleteOverview`) exactly like every other native sport; the Game Centre layer speaks a separate, provider-independent canonical **Soccer domain** (`MyApp/Soccer/Domain/`) so a future MLS/Liga MX/La Liga/UCL provider can feed the same models and UI without changes to either.

```
PulseLive JSON → EPLValue (dynamic, defensive)
              → EPL mappers (Status/Clock/Match/Event/Lineup/Stats/Officials/Commentary)
              → canonical Soccer domain (SoccerMatch, SoccerMatchEvent, SoccerLineup, SoccerTeamMatchStats, ...)
              → EPLLegacyMapper (bridge into Match/Team/StandingsGroup/RosterAthlete, discovery only)
              → EPLGameCentreReducer → SoccerGameCentreSnapshot → SoccerGameCentreView (SwiftUI)
```

`MatchDetailView` (iOS/iPadOS) and `TVMatchDetailView` (tvOS) both route `soccer/eng.1` directly into `SoccerGameCentreView`, alongside the existing NHL/MLB/NFL/F1/NBA branches. No ESPN, no FPL, no backend, no API key, on any path.

**Identity.** PulseLive returns every identifier (`matchId`, team `id`, player `id`) as a **JSON string**, not a number — confirmed live, and the opposite of the reverse-engineered reference doc's assumption. `EPLLegacyMapper` mints canonical IDs as `game:league.soccer-eng-1:epl:{matchId}` / `team:...:epl:{teamId}` / `player:...:epl:{playerId}`; `SoccerGameCentreView` recovers the raw matchId via `SportsIdentityResolver.providerID(from:provider:.epl)`, the same pattern MLB/NBA use. FPL is not integrated at all in this pass (deferred per your earlier decision) — there is no code path that could confuse an FPL element ID with an SDP ID.

## Endpoints implemented

All verified live against `https://sdp-prem-prod.premier-league-prod.pulselive.com`, competition `8`, season `2026` (2026/27), 2026-09-23:

- `GET /api/v2/matches` — discovery, with `matchweek`, `team`, `period`, `kickoff>`/`kickoff<` range filters, `_sort`, `_next` cursor.
- `GET /api/v2/matches/{id}` — authoritative Match Centre score/clock/status.
- `GET /api/v1/matches/{id}/events` — goals/cards/subs, per-team buckets.
- `GET /api/v3/matches/{id}/lineups` — starters/subs/formation/managers.
- `GET /api/v3/matches/{id}/stats` — ~180 raw Opta metrics per side.
- `GET /api/v1/matches/{id}/officials`
- `GET /api/v1/matches/{id}/commentary` — cursor-paginated.
- `GET /api/v5/competitions/8/seasons/{season}/standings?live=` — official and live-projection tables.
- `GET /api/v1/competitions/8/seasons/{season}/teams`, `/api/v1/competitions/8/teams`
- `GET /api/v2/competitions/8/seasons/{season}/teams/{id}/squad`
- `GET /api/v1/players/{id}/basic`, `/api/v1/players/{id}`, `GET /api/v2/players-by-id?id=...` (batch)
- `GET /api/v1/competitions/8/seasons/{season}/players/{id}/stats`

No API key. Rate-limit headers (`x-ratelimit-*`, ~300/60s/IP) are read every response into `EPLRateLimitState` and logged in DEBUG; a 429 sets a client-side cooldown honoring `Retry-After` rather than retrying immediately. Requests use `.useProtocolCachePolicy` (never cache-busted) so CloudFront's `Cache-Control`/`stale-while-revalidate` is respected by `URLCache`.

## What differs from the reverse-engineered reference doc (verified live, not assumed)

- IDs are strings, not integers (`"matchId":"2645195"`).
- `/v1/matches/{id}/events` has **no event ID** and groups by team into `goals`/`cards`/`subs` — not a flat list. Event identity is synthesized from `matchId|teamId|kind|playerId|timestamp|bucket-ordinal`.
- `clock` is a bare total elapsed minute (`"95"`), never pre-formatted stoppage text — `EPLClockMapper` derives `45+N'`/`90+N'` display from period + total.
- An **unannounced lineup returns HTTP 200 with an empty `players` array**, not a 404. `EPLLineupMapper` maps that to `nil` (not an empty `SoccerLineup`), which the UI reads as "not announced yet."
- Commentary returns the **same moment 2–3× (once per language)** with no per-entry language tag — only the opaque pagination cursor embeds a `lang_id`. `EPLCommentaryMapper` dedupes on `(timestamp, type)`.
- PulseLive's badge SVGs (`/badges/{id}.svg`) cannot be decoded by `AsyncImage`; a `.png` variant at the same host serves correctly and is what `EPLAssetResolver` falls back to for clubs without a bundled crest.
- Live match-state vocabulary (`FirstHalf`/`HalfTime`/`SecondHalf`) is **inferred** from the symmetric event-period field, since no match was in progress at probe time — `EPLStatusMapper` degrades any unrecognized value to `.unknown(raw)` rather than guessing wrong.
- Only `goalType: "Goal"` and card `type: "Yellow"` were directly observed; own-goal/penalty/second-yellow/red vocabulary is best-effort substring matching with `.unknown(raw)` fallback (see fixture `events-unknown-types.json`).
- Confirmed live: 3 of this season's 20 clubs (Coventry, Hull, Ipswich) have no bundled crest — validates the "never hardcode the club list" requirement concretely.

## Match identity, status, and clock

- `EPLMatchID`/team/player identity are preserved verbatim as strings end-to-end; never reconstructed from team names + date.
- `SoccerMatchStatus`: `scheduled, pregame, firstHalf, halftime, secondHalf, stoppageTime, delayed, suspended, postponed, cancelled, fullTime, abandoned, unknown(String)`. Unknown provider values never crash.
- `SoccerMatchClock`: `minute`/`addedMinute`/`display`, derived from the raw total-minute clock + period; `45+2'`, `90+4'`, `HT`, `FT` all verified against fixtures.
- The `/v2/matches/{id}` payload is the **sole** score/clock/status authority everywhere in the pipeline — `EPLEventMapper`/events never feed the score, satisfying the VAR/own-goal/correction-resilience requirement by construction, not by special-casing.

## Events

Types supported: `goal, ownGoal, penaltyGoal, yellowCard, secondYellow, redCard, substitution, unknown(String)`. (`missedPenalty`, `varEvent`, `periodStart`/`halftime`/`periodEnd` are modeled in `SoccerEventType` for future/other-provider use but are never emitted by the EPL mapper today, since no structured PulseLive field supports them — per your instruction not to infer from commentary text.) Identity is synthesized (no provider event ID exists); ordering is timestamp → minute → per-bucket ordinal, never minute alone. The reducer merges by identity so a VAR-corrected event (same id, different type) replaces in place instead of duplicating — covered by test and by the live probe (same-minute multi-substitution case).

## Lineups and formation

`/v3/matches/{id}/lineups` supplies `formation.lineup` as a nested array of player-ID rows (goalkeeper first, then each tactical line) that already matches the formation string — `SoccerFormationPitchView` renders directly from that structure, with zero string parsing and no hardcoded formation list. A genuinely missing `formation` object (fixture: `lineups-missing-formation.json`) now falls back to treating every listed player as a starting-XI entry (fixed during this pass — the original mapper silently dropped the roster in that case, since starter/sub membership had no other signal without the formation grouping). An unannounced lineup (empty `players[]`, real HTTP 200 shape) maps to `nil`, read by the UI as "not announced yet."

## Match statistics

`EPLStatKeyMapper` normalizes the raw Opta payload (confirmed keys: `possessionPercentage`, `totalScoringAtt`, `ontargetScoringAtt`, `expectedGoals`, `expectedGoalsOnTarget`, `bigChanceCreated`, `bigChanceMissed`, `totalPass`, `accuratePass`, `totalCross`, `totalTackle`, `wonTackle`, `interception`, `totalClearance`, `aerialWon`, `duelWon`, `touchesInOppBox`, `finalThirdEntries`, `saves`, `yellowCard`, `redCard`, `totalOffside`, `fkFoulLost`) into `SoccerTeamMatchStats`. `shotsOffTarget`/`blockedShots` use best-effort alternate key names since those two weren't directly confirmed in the probe payload — everything else was. Every field is optional and hides its row rather than showing a fake `0`/`0.00`; the full raw ~180-key dictionary is preserved on the model for future expansion. Pass accuracy is computed as a ratio of two real supplied counts (never a fabricated metric).

## Commentary, officials, standings

Commentary paginates on the opaque `_next` cursor (never reconstructed), dedupes multi-language duplicates, and is capped at 500 stored entries with older pages loadable on demand via `loadMoreCommentary()`. Officials map role labels verbatim (`Referee`, `Assistant Referee#1/#2`, `Fourth official`, `Video Assistant Referee`, `Assistant VAR Official` — all 6 roles observed live). Standings support both the official table (`live=false`) and a live-projection table (`live=true`) as **distinct** snapshot slots that can never overwrite each other.

## Polling and caching

Single poll loop per match (`EPLGameCentreViewModel`), adaptive cadence: 10s live (first/second half/stoppage), 25s halftime, 25–300s pregame depending on time to kickoff, 30s delayed/suspended, exponential backoff on repeated failures, stopped entirely once `SoccerMatchStatus.stopsPolling`. A `full` flag forces match+events+lineups+stats+officials+commentary+ (while live) live-standings every ~120s; lighter ticks fetch match+events always and lineups/stats only while relevant, with lineups specifically gated on "not yet loaded" rather than tab selection, so an already-announced lineup isn't re-fetched every 10s just because the user is looking at that tab. Foreground/connectivity-restore forces an immediate full refresh; background stops the loop via `scenePhase`. This is an approximation of fully independent per-resource timers (Steps 57–59's intent), not a literal separate scheduler per endpoint — disclosed, not hidden.

Atomic JSON snapshot cache (`EPLGameCentreCache`, actor, `Caches/BannerTV/EPL/v1/{matchId}.json`), identical shape to the NHL/MLB/NBA cache convention. Discovery caches: same-day scoreboard 10s, date-range schedule 120s, teams 24h, standings 15min, squads/player overview 1h — mirrors `MLBProvider`'s cadence.

## Game Centre UI

Score hero (largest emphasis on score, pregame "vs" never a fake 0–0, subtle red-card counts using icon+text not color alone), Overview (goals/cards summary, key stats, lineup/officials status, match info, live table preview), Timeline (grouped by half, goal/card/substitution rows with distinct visual weight, generic fallback row for unmapped types, two-column "Timeline | Match Context" layout on iPad and tvOS with Siri Remote focus surfacing the focused event's own detail), Lineups (formation pitch rendered from real row data, home/away toggle on iPhone, side-by-side on iPad/tvOS, fallback starting-XI list when formation is missing), Stats (paired bars, show-more for secondary metrics, never a fake zero), Commentary (live feed, jump-to-live, load-older pagination). Player taps navigate via the existing `PlayerDetailView` using the real provider ID, never a name string. Premium gating, spoiler-free score blur, and cache/error states reuse the exact same components as MLB/NBA/NFL/NHL.

**Accessibility.** VoiceOver and Dynamic Type audits found and fixed real issues, not just a pass/fail note: the score digits used a hardcoded `size: 40` font (now `.largeTitle`, scales with Dynamic Type); goal and substitution rows combined two independently-tappable player links into one non-actionable VoiceOver element (now left uncombined so both the scorer/assist and the incoming/outgoing player remain independently reachable and activatable); Timeline section headers lacked the `.isHeader` trait; formation-pitch player tokens announced only a shirt number and surname (now a full "Number 9, Erling Haaland, Forward, captain"-style label, since the visual badge is intentionally exempt from Dynamic Type as a spatial diagram — Apple's own guidance for graphical position indicators). A contrast check on the two custom-color views introduced by this feature (pitch green background, red-card icon) passed WCAG thresholds in both light and dark. Not done: a full VoiceOver playback pass on a simulator/device, and the fixed-width numeric-label recommendation (minute/stat columns) noted by the Dynamic Type audit as informational, not fixed.

## Platforms

iPhone, iPad, and tvOS all build clean (`BuildProject` verified on each destination in this session). iPad gets the two-column Timeline; tvOS gets the same two-column layout via Focus Engine (`@FocusState` + `.focusable()`, gated `#if os(tvOS)`) with no touch-only gestures anywhere in the new UI. One real tvOS-only compile error was caught and fixed (`.listRowSeparator` is unavailable on tvOS). Visual/interactive verification on an actual simulator session (screenshots, focus traversal, scrolling) was not performed.

## Tests

`EPLCoreTests/` — a standalone SwiftPM package mirroring `MLBCoreTests/`/`NBACoreTests/` exactly: production sources symlinked (not copied) into `Sources/EPLCore`, Swift Testing, offline, no live servers required. **42 tests across 9 suites, ~6.4s.** Coverage: status/clock mapping (known + unknown periods, stoppage-time math), match fixtures (fulltime, prematch with omitted score fields, first/second-half stoppage, halftime, postponed), events (real 14-event match, unknown goal/card types, same-minute multi-substitution, assist/sub slots never aliasing the same player), lineups (real announced squad, not-announced → nil, missing-formation fallback), stats (with/without xG, never a fake zero), officials, commentary (multi-language dedupe against real captured duplicates, blank-time handling, real two-page pagination), standings (official vs. live-projection staying distinct), reducer (stale/out-of-order rejection, matchID-mismatch rejection — the structural half of the Step 77 game-switch guard, event-correction-in-place, lineup-regression guard, officials-never-cleared-by-empty-response, commentary merge+sort, player-directory additive merge), and networking (429/Retry-After, 400/404 RFC7807 detail parsing, malformed-JSON decode error, bounded 503 retry, cancellation, one-resource-failure-doesn't-fail-the-whole-fetch).

Run offline:
```
./EPLCoreTests/run-tests.sh
```
Optional live smoke (hits the real API):
```
EPL_LIVE_SMOKE=1 ./EPLCoreTests/run-tests.sh
```
In this session the live-smoke path timed out from the sandboxed shell (a standalone compiled binary under this environment's network restrictions) — this is an environment limitation, not a product defect: the identical live connectivity was independently proven multiple times in-session via `curl` probes and via `RunCodeSnippet` executed inside the actual app target (real matches, standings, rosters, lineups, stats, officials, and commentary all fetched and mapped correctly against `https://sdp-prem-prod.premier-league-prod.pulselive.com`).

Not covered by fixtures (disclosed gap, not silently skipped): abandoned-match state, extra-time/shootout fields (modeled on `SoccerMatch` for future cup competitions but never exercised since EPL league play never sets them), the true concurrent game-switch race (Step 77's full scenario — two in-flight requests resolving out of order for two different matches). The reducer's `matchID`-mismatch and stale-timestamp guards are unit-tested individually; the generation-token race guard in `EPLGameCentreViewModel.run()` reuses the identical pattern already shipped and relied upon by MLB/NBA, but wasn't independently exercised with a timed mock harness here.

## Unmapped / unconfirmed provider fields

- `shotsOffTarget`/`blockedShots` Opta key names are best-effort guesses, not directly confirmed in the probed payload.
- Live match-period vocabulary beyond `PreMatch`/`FullTime` (i.e. the exact strings for `FirstHalf`/`HalfTime`/`SecondHalf`/`Suspended`/`Delayed`/`Abandoned`) is inferred from the events endpoint's symmetric field, not directly observed on the match endpoint during a live game.
- Own-goal/penalty-goal/second-yellow raw string vocabulary is unconfirmed (only `"Goal"`/`"Yellow"` seen live).
- `missedPenalty`/VAR events have no known structured PulseLive field and are therefore never emitted, only modeled for future use.
- ~150 of the ~180 raw Opta match-stat keys are preserved in `SoccerTeamMatchStats.raw` but not individually mapped to a canonical field (by design — only the Stats-tab's displayed metrics are canonicalized, per the "don't overwhelm the default view" instruction).

## Production / licensing

PulseLive is undocumented, unauthenticated private web infrastructure behind premierleague.com — not a published commercial API, and its terms restrict automated/commercial redistribution. This implementation keeps every PulseLive-specific detail (host, paths, response shapes, key names) inside `MyApp/EPL/`; the canonical Soccer domain and Game Centre UI never reference PulseLive directly, so a licensed feed (Opta/Stats Perform direct, or another provider) could replace `EPLProvider`/`EPLGameCentreService` without touching the domain models or any view. Before any production/commercial use of the PulseLive path specifically, a proper data license should be reviewed independently of this code change.
