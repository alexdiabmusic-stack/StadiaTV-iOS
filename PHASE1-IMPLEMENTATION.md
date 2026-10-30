# Banner TV Sports Mode — implementation and verification

Phase 1 improves the existing Sports Mode incrementally. Verification scope and remaining provider/device limits are recorded below. No playback engine, playlist importer, account system, or persistence store was replaced. No dependencies or user-visible future modes were added.

## Repository assessment

| Area | Existing implementation and decision |
| --- | --- |
| Navigation | Native TabView, per-screen navigation and safe-area mini player. Preserve; extract tab metadata and Sports configuration. |
| Design | Theme, cards, chips, section headers, loading states and cached artwork already exist. Refine these rather than introduce a parallel system. |
| Sports | SportsRepository, native league providers, canonical identities, caches and sport-specific Game Centres. Preserve; share cached live requests and correct presentation. |
| Following | PreferencesStore, schedules, Fantasy, news and standings. Preserve integrations; persist selection and apply news relevance. |
| Television | Existing playlist services, off-main indexed channel filtering, favourites, groups and playback history. Preserve storage and player. |
| Guide | Virtualized timeline, cached row layouts and calendar-aware day windows. Preserve architecture; fix clipped programme geometry and improve labels. |
| Matching | Indexed StreamLinker with confidence tiers and guide evidence. Preserve thresholds; improve same-city NBA aliases and multiple-source choice. |
| Editorial | Existing RSS/API providers and podcast integration. Preserve clients; fix feed-derived labels, duplicate handling, attribution and unsupported editorial claims. |
| Tests | Swift Testing suites and existing stress fixtures. Extend integrity and 20,000-channel coverage; repair stale fixture and incorrect optional comparison. |

## Implemented behavior

- **Home:** a favourite live event takes priority, followed by other live events and relevant upcoming games. A compact featured card separates Game Centre and broadcast actions. Other live games use compact rows and exclude the featured game. Starting Soon can appear without a live game. Scheduled events are no longer marked live simply because their start time passed. History explicitly reopens the channel's current broadcast. Your Sports Day is a compact summary with a next-event alternative; empty schedule sections are omitted. Removed the obsolete oversized hero and synthetic calendar-to-match fallback: featured cards require real provider events.
- **Following:** selected team/league persists; team-related news follows the selection, all followed news leagues are loaded, and the featured upcoming game is omitted from the immediately repeated schedule. Existing Fantasy and standings integrations remain, with a full-standings navigation action. Team-news failure has explicit retry feedback. Team identities align even when names wrap. Summary counts stack at accessibility text sizes.
- **Live:** For You ranks followed teams and leagues first. Multiple confirmed sources open the existing chooser. Possible matches remain distinct from confirmed matches; labels do not claim technical stream verification.
- **Guide:** wider channel identity column, localized time formatting, readable programme labels and exact visible-window clipping. Short slots no longer expand over adjacent programmes. Invalid intervals are rejected; absolute-time geometry accommodates short DST days. Long programmes keep their titles visible as the timeline scrolls. Token-prefix search avoids matching TSN inside Sportsnet and searches loaded programme titles. Accessibility sizes use expandable programme rows, with watch, details, date and Now actions. Reminder labels fit and retain full accessibility descriptions. Player Up Next includes the programme starting exactly at the current programme's end. A small per-channel Observation revision makes newly fetched programme rows appear without invalidating every channel or rebuilding stream links.
- **Discover:** headline evidence overrides conflicting feed tags. Broad or ambiguous stories keep broad categories. WNBA no longer matches NBA by substring, NASCAR is not used as an F1 feed, and broad motorsports is not automatically F1. Canonical URLs retain case-sensitive paths while removing tracking. Unicode titles survive deduplication. Publishers, missing dates and explicit editorial content types are presented accurately.
- **Game Centre/shared events:** existing detailed destinations and sport-specific services remain. Shared score rows and featured cards present F1/golf as events, without fabricated team shields or scores. Exceptional statuses are resolved centrally for the new presentation. NHL, basketball, baseball and soccer show detail tabs only when corresponding content exists. Added the missing Champions League adapter using the existing FotMob client and soccer Game Centre infrastructure; scores, schedules, teams, standings and supported match detail now have a registered provider.
- **Design/accessibility:** semantic dark surfaces and accents, native type styles, adaptive featured actions, minimum action heights, accessible status labels and French strings for introduced labels. Shared text/status colors were checked against card/elevated surfaces in light and dark appearances. Large Text was exercised interactively; this is not a whole-app accessibility certification.

## Architecture and persistence

New `FeaturedGameCard` and `CompactGameRow` reuse the existing Card, Theme, TeamLogo and navigation destinations. `ArticlePresentation` consolidates editorial formatting and team relevance. `GuideProgrammeGeometry` isolates pure clipping calculations for tests. `EventStatusPresentation` bridges existing legacy state without changing provider schemas. `NavigationConfiguration.sports` supplies the current five tabs with stable IDs.

News HTTP requests coalesce in flight and use a five-minute memory cache. Live snapshots reuse the existing scoreboard cache. Schedule requests normalize the local calendar day and coalesce through the existing cache, so different tabs requesting the same day share a fetch. Article metadata adds optional sport/publisher/category/team fields; the canonical article's new sport field is optional for backward decoding. Following selection adds a preference key. Existing playlists, favourites, groups, history and account keys are unchanged; no reset or migration is required.

Future TV-first or Complete configurations can reuse tab destinations and shared streaming stores. Movies, series and mode-selection UI are intentionally absent. This is a configuration foundation, not a completed modularization of the whole application.

## Before and after

| Before | Implemented result |
| --- | --- |
| Feed request could label basketball content NHL | Content evidence corrects the label; ambiguous stories remain broad |
| F1 could appear as empty opposing teams | Event title and session/status presentation |
| Time passing could imply a game was live | Provider state determines live eligibility |
| Featured and live sections repeated the same event | Featured event excluded from compact live list |
| Multiple confirmed sources silently chose one | Existing stream chooser opens |
| Short guide slots could overlap adjacent slots | Geometry preserves actual clipped duration |
| Missing article dates implied freshness | Missing/future dates do not claim “just now” |

## Scoped accessibility and localization audit

| Check | Result and evidence |
| --- | --- |
| Shared-token text contrast | PASS for checked foregrounds on card/elevated backgrounds. Dark elevated: accent 4.58:1, live 4.55:1, tertiary 4.96:1; light live/elevated 5.35:1; white/live-fill 4.78:1. This is not a certification of every legacy view or artwork overlay. |
| Following summary at accessibility size | PASS on interactive recheck: counts and labels stack and scale without broken words. |
| Featured Home and Discover at accessibility size | PASS for inspected scrolling cards; content remained readable. |
| Guide accessibility layout | PASS on final interactive recheck: full date, current programme, upcoming programmes and Now label readable; fetched programmes appeared without leaving the tab. |
| VoiceOver | Code review confirms shared status/action labels and native control semantics. Manual VoiceOver navigation was not performed; no whole-app PASS is claimed. |
| Localization | All 42 newly extracted catalog keys have French translations; existing catalog retained. |
| Reduce Motion | Shared score transitions honor Reduce Motion; guide selection uses the existing motion policy. |

## Provider and verification limits

- Champions League uses the existing FotMob transport and validates competition identity. Its league endpoint returned genuine fixtures/table data during verification; upstream schemas may change. Standalone roster and player-profile capabilities are explicitly unsupported. Live minute vocabulary in the existing FotMob mapper remains partly inferred; absent timing is not invented.
- Existing Fantasy, podcasts, account management, sport-specific statistics and standings remain integrated. This pass did not authenticate every external Fantasy service or verify every league against a live in-progress fixture.
- Shared request caches reduce duplicates; the application still has existing screen view models rather than a new single observable event store. Introducing a competing repository was avoided.
- News team relevance depends on structured metadata and conservative name matching. Ambiguous mixed-sport roundups use Sports, and removing misleading feed classifications can reduce league-specific results.
- Programme search covers cached/imported guide information; it does not download every remote programme merely because the user types a query.
- No physical device, iPad, tvOS, macOS target, full VoiceOver session, PiP, or exhaustive recovery/orientation matrix was exercised. Native tab safe areas, navigation, landscape playback and Large Text received the iPhone coverage listed below.
- The player orientation button was not conclusively verified by automation. Device-driven landscape rotation worked. Playback Back works when its auto-hiding controls are revealed and tapped promptly.
- No production account data or persistence schemas were reset. The supplied test account exists only in the fresh simulator installation; credentials are absent from source and this report.

## Verification results — 2026-10-28

Final suite and accessibility recheck results are recorded below when completed.

### Completed automated and performance checks

- Xcode BuildProject succeeded, including test targets. Latest pre-final build: 09:37:03.
- Prior complete suite: **220 total, 219 passed, 0 failed, 1 not run**. The remaining no-result case is the existing Release-only 22,000-channel performance budget excluded from Debug; final regression suite pending after the last accessibility/search changes.
- MatchLinker package Release suite: **12 tests passed**.
- Standalone optimized benchmark using the existing synthetic workload: **22,000 streams / 115,000 programmes; index construction 0.1210 seconds; median of 50 event lookups 0.01395 milliseconds** on the development Mac. These measurements do not establish device frame rate or memory budgets.
- New coverage includes conservative article classification, Unicode/canonical URL deduplication, event-specific presentation, exceptional states, guide clipping and DST windows, 20,000-channel correctness, token-prefix search, adjacent programme boundaries, and shared schedule fetches.
- Corrected stale test fixtures and an Optional.none comparison; preserved the documented possible-match confidence for fixture names without kickoff evidence.
- Real-fixture integration returns early without LINKER_FIXTURE_DIR; its reported pass does not validate an exported playlist fixture. The separate interactive test below uses the actual supplied playlist.
- `git diff --check` passed before final verification.

### Interactive iPhone verification

Fresh **iPhone 17 / iOS 27 simulator**, actual application build and supplied IPTV account:

- Imported **21,972 channels**; provider Connected.
- Search for TSN returned 271 channels. TSN 1 HD visibly played moving video; a single debug observation reported first frame 4.83 seconds and ready 5.94 seconds. This is one sample, not a performance guarantee.
- Favourite channel persisted through reinstall, and watch history appeared.
- Populated guide: readable identities, synchronized horizontal ruler/rows, correctly positioned Now marker, future programme details and reminder picker.
- Sportsnet East launched from the guide; returning preserved guide query/position.
- Long programme title visibility, compact reminder labels and adjacent Up Next programme were fixed and rechecked.
- Following selection persisted, team logos aligned, repeated Tomorrow label removed, upcoming NHL Game Centre omitted empty detail tabs.
- Mixed-sport editorial content displayed Sports and podcast artwork aligned.
- Landscape playback at 874×402 showed no steady clipping. Player dismissal succeeded using visible controls.
- Large Text at the second-largest accessibility setting exposed guide/summary clipping; fixes passed the final recheck. The guide displayed the full date, current TSN1 SportsCentre 9:30–10:30 and the following 10:30–11:30 programme with readable titles/times/Now labels. Newly fetched programmes appeared automatically. Final system-settings cleanup is recorded separately.

Safe screenshots are in the Xcode ActionArtifacts directory under `BF239465-4A7A-4CD6-97F0-69CB4A70295A/DeviceInteractionSynthesize`. Credential-entry captures were removed.

## Future-phase readiness

Only Home, Following, Live, Discover and Settings are active. Stable tab metadata and `NavigationConfiguration.sports` provide the configuration point for later TV-first or Complete presentations. Existing player, playlists, guide, preferences and history remain reusable shared infrastructure. No unfinished movie/series interfaces or nonfunctional mode switch were added.
