# Stadia Sports Data Platform

## Current Dependency Map

```text
ESPN Site API scoreboard/news/teams
-> ESPNService
-> MatchesViewModel, HomeViewModel, LiveSportsViewModel, TV live/following/home surfaces, onboarding team pickers, highlights/news views
-> Match, TeamSide, ESPNArticle
-> SwiftUI screens
```

```text
ESPN Site/Web/Core premium endpoints
-> ESPNPremiumService extension on ESPNService
-> PremiumViews, RosterViews, MatchDetailView, TVStatsView
-> StandingsGroup, RosterGroup, AthleteOverview, LeaderBoard, LeagueInjury, GameSummary
-> SwiftUI screens
```

```text
ESPN Fantasy API and ESPN public roster endpoints
-> ESPNFantasyService / ESPNSportsDataProvider / FantasyEventLinker / FantasyPlayerResolver
-> FantasyStore / StadiaFantasyStore
-> FantasyDashboardView, MatchDetailView fantasy context
```

```text
MoneyLine odds API
-> OddsService
-> MatchDetailView / PickMatchDetailSheet
```

Direct ESPN concepts currently leaked outside adapters:

- `League.path` is an ESPN URL path and also acts as the app league ID.
- `Match.id`, `TeamSide.teamID`, `Team.id`, `StandingRow.teamID`, and roster/player IDs are ESPN IDs when sourced from ESPN.
- `FavoriteTeam.id` persists `leaguePath-teamID`, where `teamID` is currently ESPN-derived.
- `ESPNArticle` is the app news article model and appears in UI, persistence, and TV components.
- Fantasy resolution prefers `espnAthleteID` and creates fallback IDs with an `espn:` prefix.

## Provider Capability Matrix

This matrix reflects the attached `sportsdataverse-0.1.2` package plus the current Stadia codebase. Apple Sports, CBS, and broad Yahoo references were not present as attached source trees; only Yahoo CFB and FOX Bifrost references were discoverable in SportsDataverse.

| Provider | League | Scores | Schedule | PBP | Box Score | Standings | Rosters | Player Stats | Team Stats | Injuries | Leaders | News |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| NHL Web API | NHL | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Unknown | Yes | No |
| MLB StatsAPI | MLB | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Unknown | Yes | No |
| NBA Stats/CDN | NBA/WNBA/G League | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Limited/unknown | Yes | No |
| NFL Shield | NFL | Partial | Weeks/details | Unknown | Summaries/details | Yes | Yes | Unknown | Unknown | Yes | Unknown | No |
| FOX Bifrost | NBA/NHL/MLB/CFB/MBB/WBB/WNBA | Partial | Partial | Yes | Yes | Yes | Yes | Yes | Yes | Unknown | Yes | No |
| Yahoo Sports | CFB in attached package | Yes | Yes | Unknown | Unknown | Unknown | Unknown | Season stats | Season stats | Unknown | Unknown | Editorial CFB |
| ESPN | Many Stadia leagues | Yes | Yes | Yes via summary | Yes via summary | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Apple Sports | Not attached | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown |
| CBS Sports NAPI | Not attached | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown | Unknown |

## Attached Reference Findings

SportsDataverse is useful as endpoint discovery and parser guidance, not as a runtime dependency. It is Python, DataFrame-heavy, and includes thousands of wrappers Stadia does not need on-device.

Useful endpoint families:

- NHL: `https://api-web.nhle.com/v1/gamecenter/{game_id}/play-by-play`, `/boxscore`, `/landing`, `/schedule/{date}`, `/score/{date}`, `/standings/now`, `/roster/{team}`.
- MLB: `https://statsapi.mlb.com/api/v1/schedule`, `/api/v1.1/game/{gamePk}/feed/live`, `/api/v1/game/{gamePk}/feed/live/diffPatch`, `/api/v1/teams`, `/api/v1/standings`, team/person stats and leaders.
- NBA: `https://stats.nba.com/stats/scoreboardv3`, `scheduleleaguev2`, `boxscoretraditionalv3`, `playbyplayv3`, `commonteamroster`, `leaguestandingsv3`, plus browser-like headers and JA3/TLS concerns noted by the package.
- NFL: `https://api.nfl.com/football/v2/standings`, `/rosters`, `/teams/history`, `/weeks`, `/weeks/date`, `/injuries`, `/game-summaries`, `/weekly-game-details`; anonymous bearer token generation is required.
- FOX: `https://api.foxsports.com/bifrost/v1/{league}/...` with a public data-tier API key and web Origin/Referer headers.
- Yahoo: attached implementation covers CFB Graphite/editorial endpoints, not enough to treat Yahoo as a universal fallback yet.

## Normalized Domain

The first-pass code introduces Stadia-owned models in `SportsDataPlatform.swift`:

- League/team/player/game identity: `StadiaLeague`, `StadiaTeam`, `StadiaPlayer`, `StadiaGame`, `StadiaEntityID`, `ProviderEntityAlias`.
- Live game state: `StadiaGameStatus`, `StadiaScore`, `StadiaGameClock`, `StadiaPeriod`, `StadiaVenue`, `StadiaBroadcast`.
- Capability results: `StadiaSchedule`, `StadiaStandingGroup`, `StadiaStanding`, `StadiaBoxScore`, `StadiaPlayByPlay`, `StadiaRoster`, `StadiaInjury`, `StadiaLeader`, `StadiaNewsArticle`, `StadiaOdds`.
- Debugging: `DataProvenance`, `SportsProviderDiagnostics`.

Provider DTOs must remain inside provider adapters. The compatibility bridge converts `StadiaGame` back to current `Match` values until feature screens are migrated.

## Capability Protocols

Providers opt into small protocols instead of one giant interface:

- `ScoreProvider`
- `ScheduleProvider`
- `StandingsProvider`
- `GameDetailsProvider`
- `BoxScoreProvider`
- `PlayByPlayProvider`
- `TeamProvider`
- `PlayerProvider`
- `RosterProvider`
- `PlayerStatsProvider`
- `TeamStatsProvider`
- `InjuryProvider`
- `LeagueLeaderProvider`
- `SportsNewsProvider`

Every provider also exposes `SportsDataProviderMetadata` with ID, name, support level, supported sports/leagues, capabilities, auth type, enabled state, and timeout.

## Routing Configuration

Routes are centralized in `SportsProviderRouteConfiguration`. Routing is keyed by `league + capability`, not only by league.

Initial intended hierarchy:

- Soccer, F1, NASCAR Cup, PGA, LPGA, ATP, WTA, NCAA Football, NCAA Basketball, and WNBA baseline Apple capabilities: Apple Sports -> CBS -> Yahoo -> FOX -> ESPN.
- NHL core data: NHL Web API -> Apple Sports -> CBS -> Yahoo -> FOX -> ESPN.
- MLB core data: MLB StatsAPI -> Apple Sports -> CBS -> Yahoo -> FOX -> ESPN.
- NBA core data: NBA Stats/CDN -> Apple Sports -> CBS -> Yahoo -> FOX -> ESPN.
- NFL core data: NFL Shield -> Apple Sports -> CBS -> Yahoo -> FOX -> ESPN, pending Shield reliability/auth validation.
- Other sports score/schedule default: Apple Sports -> CBS -> Yahoo -> FOX -> ESPN when Apple maps that league; otherwise ESPN remains fallback.
- News: separate repository/provider track; ESPN remains current fallback where used.

Phase 2 registers `NHLProvider` ahead of `ESPNProvider` for NHL capabilities when `NHLProviderEnabled` is absent or enabled. Configured unavailable providers are skipped without feature code knowing.

## Identity Strategy

`SportsIdentityResolver` creates canonical IDs and stores provider aliases separately.

Current ESPN bridge behavior preserves compatibility by creating canonical IDs that contain the ESPN alias, for example `team:hockey/nhl:espn:10`. This makes migration safe for existing favourites and `Match` consumers. Future provider work should migrate toward stable IDs generated from league, abbreviation, normalized city/name, and curated alias maps.

Planned identity records:

```text
Stadia Team ID
- ESPN ID
- NHL/MLB/NBA/NFL first-party ID
- FOX ID
- Yahoo ID
- Apple ID
- CBS ID
```

Games should match on league, canonical participants, scheduled start bucket, season, and game type. Players should match on provider IDs where present, then full name, birthdate, team, position, and jersey number. Display names alone are insufficient.

## Cache, Fallback, and Health

Phase 1 adds:

- `SportsDataCache`: in-memory TTL cache with capability defaults.
- `SportsRequestDeduplicator`: coalesces identical in-flight requests.
- `ProviderHealthMonitor`: records latency, successes, failures, rate-limit/unavailable cooldown, and enabled/disabled state.
- `SportsProviderRouter`: chooses available providers by route, metadata capability, supported league, and health.
- `SportsRepository`: facade that current feature code can call without knowing the provider.

The first bridge changes `MatchesViewModel` to call `SportsRepository.shared.legacyScoreboard(...)` and `legacyScoreboards(...)`, which still render as existing `Match` rows. Phase 2 also adds repository-level `gameDetails`, `boxScore`, and `playByPlay` APIs plus `legacyGameSummary(for:)` so current detail UI can consume normalized stats/play-by-play before falling back to ESPN.

## NHL Phase 2 Adapter

`NHLProvider.swift` is the first first-party provider adapter. It uses `https://api-web.nhle.com/v1` and currently implements:

- Scores: `/score/now`.
- Schedule: `/schedule/{yyyy-MM-dd}` in seven-day windows, filtered to the explicit repository range.
- Standings: `/standings/now` grouped by conference/division.
- Teams: derived from standings for now.
- Rosters: `/roster/{teamAbbreviation}/current`.
- Game details: `/gamecenter/{gameID}/landing`.
- Play-by-play: `/gamecenter/{gameID}/play-by-play`.

The adapter keeps NHL DTOs local to the provider file and maps immediately into Stadia-normalized models with `.nhl` provenance. `NHLProviderEnabled` is the bundle kill switch; absent means enabled.

## Apple Sports Assessment

The supplied Apple Sports bundle confirms an undocumented/private, manifest-driven backend. `AppleSportsProvider.swift` is registered as `.experimental` behind the `AppleSportsProviderEnabled` kill switch. It fetches `https://api.sports.apple.com/v3/{locale}/manifest/3.0.0`, then follows the manifest-provided `cdn_base_url` and per-group `cdn_id` values. It does not implement push registration.

Observed manifest fields as of August 28, 2026:

- `version`: observed `3.0.109`.
- `cdn_base_url`: observed `https://api-sports.cdn-apple.com/v3/query`.
- `image_service_url`: observed `https://is1-ssl.mzstatic.com`.
- `groups`: competition/conference/tournament records keyed by `umc.csl.*`, commonly with `name`, `abbr`, `cdn_id`, and `canonical_id`.
- `teams`: team records keyed by `umc.cst.*`, commonly with `league_ids`, `group_ids`, `name`, `full_name`, `abbr`, `logo_token`, and sometimes `cdn_id`.
- `extensions`: active season, visibility, logo/color, team match, Top 25, and related manifest metadata.

Observed CDN document fields:

- League documents are available at `{cdn_base_url}/{cdn_id}` when the CDN ID is valid/current.
- `content.leagues[].members[].statistics` can support standings-like rows.
- `content.events[]` can support scores, schedules, status, venues, competitors, and leaderboard-like rows.
- `content.brackets` appears for ATP/WTA documents but is not normalized yet.

Implemented Apple capabilities:

- Scores, schedules, game status, game details, teams, standings/leaderboards where exposed in discovered documents.
- Generic box scores, team stats, player/individual competitor stats, and league-leader style rows from `scoreEntries`, `lineScore`, and exposed statistics.
- No Apple play-by-play, lineups, formations, bracket, weather, dedicated lap-time model, or hole-by-hole scorecard capability is claimed yet because those require fixtures and mapping beyond the baseline documents sampled.

Safety constraints retained:

- Global kill switch in provider registry/feature flags.
- Dynamic manifest discovery; no hardcoded Apple UMC/CDN IDs in source.
- Defensive/tolerant decoding and short timeout.
- Isolated DTOs and networking.
- Provider health integration so failures route to the next provider.
- No Apple IDs in Stadia canonical IDs except as aliases.

## Remaining ESPN Dependencies

Still direct after Phase 2 foundation/NHL adapter:

- News UI/persistence uses `ESPNArticle` and `ESPNService` news/article body calls.
- Premium views use `ESPNService` for standings, rosters, leaders, injuries, athlete overview.
- `MatchDetailView` uses ESPN for game summary, roster preview, multiscreen live-games lookup.
- `TVPlayerView`, `HomeView`, `LiveView`, `HighlightsView`, onboarding pickers, predictions, racing views, pick detail refresh still instantiate `ESPNService` directly.
- Fantasy imports and native fantasy player pool use ESPN IDs and ESPN public roster endpoints.
- `League.path` remains an ESPN path.
- `FavoriteTeam.teamID` remains a provider-specific ESPN team ID.

## Migration Risks

- Persisted favourites and fantasy mappings currently rely on ESPN IDs; migration needs dual-read/dual-write alias support.
- NBA Stats endpoints may require browser TLS fingerprints that URLSession cannot fully mimic.
- NFL Shield requires anonymous bearer tokens and may have stability/auth constraints.
- FOX/Yahoo/CBS/Apple are undocumented or web-private surfaces and need health/rate-limit protection.
- Provider disagreement should be exposed in diagnostics, not blended silently in production.
- Current screens can still over-fetch broad windows; repository APIs should increasingly require explicit `SportsDateRange` and team filters.
- Existing UI models are not all `Sendable`/`Codable`; normalized models should become the long-term persistence and concurrency boundary.

## Next Phase

Continue Phase 2 by adding offline NHL fixture mapping tests for real scoreboard/standings/roster/play-by-play payloads, then implement NHL box score normalization. ESPN should remain fallback until box score and detail parity is verified.
