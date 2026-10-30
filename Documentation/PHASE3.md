# Phase 3 implementation audit

Baseline: clean working tree; Xcode BuildProject succeeded on 2026-10-29 in 6.123 seconds. Code inspection is not proof of real-provider playback.

| Dependency | Initial status | Evidence / work needed |
| --- | --- | --- |
| Sports Home, Following, scores, schedules, Game Centre | Implemented but incomplete verification | Existing HomeView, MatchesView, LiveView, league-specific services and regression suites; real feeds/device journeys unverified |
| News, podcasts, fantasy, standings | Implemented but incomplete verification | Existing Discover, podcast, fantasy services and sports search; external credentials/provider availability not verified |
| Sports channel matching and shared player | Implemented but incomplete verification | Existing StreamAvailabilityStore, event refresh, PlaybackController and matching tests |
| Mode preferences/navigation | Implemented and build verified | Sports and Live TV only; backward-tolerant preferences decoder and tab restoration |
| Channels, EPG, favourites, groups, live history | Implemented but incomplete verification | Shared playlist, guide, channel preferences, WatchStore; existing tests |
| VOD inventory, normalized identity, series/episodes | Implemented but incomplete verification | Real Xtream adapter, conservative M3U classification, canonical grouping |
| Metadata | Blocked by configuration for production | TMDB shared service has no token; provider metadata fallback exists |
| VOD playback/progress | Implemented but incomplete | Shared PlaybackController; five-second recording; lifecycle and continuation need improvement |
| Watchlist | Implemented but incomplete | IDs persist, but catalog eviction loses presentation information |
| Search | Implemented but incomplete | Separate entertainment and sports searches; no unified entertainment results in sports search |
| Complete Mode | Missing | Requires five-tab shell, Home, dedicated browsing and integration |

Execution order: extend existing preferences/navigation; repair shared continuation and watchlist retention; add source-backed Home and dedicated catalogs; unify discovery; run build/regression tests and report limits. No source credentials or existing preference keys are reset. Existing v1 records remain readable; additive persistence uses separate keys.

Portable contracts remain EntertainmentItem (provider ID plus validated metadata identity), EntertainmentSource (source UUID/item ID, no URL), ContentAvailability, EntertainmentProgress, and ViewingExperience. Android/Fire TV implementations are outside this repository.

## Implementation delivered

- Added persisted `ViewingExperience.complete` without changing the sports/liveTV raw values or defaults. Unknown future values still fall back safely. Navigation supplies Home, Live TV, Movies, Series, Sports; Settings/search move to header controls. Existing notification/game routes remain in use, and tab requests are translated within Complete Mode. A guarded selection binding prevents invalid selections while tab configurations change.
- Added Complete Home with deterministic available-inventory hero selection, unfinished movies/episodes, Up Next, current EPG broadcasts, distinctly labelled live-channel history, sports prominence controls, entertainment recommendations, browsing links, and supported-source guidance.
- Dedicated Movies/Series destinations reuse EntertainmentLibraryView and the same repository. Added featured/library exploration, source/year/availability filters, watchlist/history access, retained genre/category filters, and correct landscape episode artwork. Details retain provider-backed playback/source selection, cast, labelled ratings, metadata fallback, and season selection with actual playable episode counts.
- Extracted pure EntertainmentDiscovery policies for continuation, regular-episode ordering, cross-season advancement, future-date exclusion, deterministic recommendations, deduplication and exact-title search ranking. Unfinished unavailable episodes are not silently skipped. Specials do not interrupt automatic regular episode ordering.
- Preserved EntertainmentRepository, PlaylistStore, EPGRepository, WatchStore, PreferencesStore and BannerAppEnvironment.playbackController as shared owners. No second guide, player, sports repository or account backend was introduced.
- Added persistent watchlist and watched-history presentation snapshots so unavailable saved/watched titles remain identifiable. Legacy watchlist IDs remain intact. Added a separate Continue Watching suppression set: hiding a card preserves history/progress. Explicit Mark Watched/Unwatched actions are separate. Removed automatic eviction of old progress at 2,000 records.
- VOD player now saves on observed pause, scene deactivation and completion in addition to the existing interval/exit saves. Completion fraction is configurable in the policy API; invalid/unknown durations cannot imply completion. The player offers the next available episode and optional autoplay, disabled by default. Existing shared AVPlayer, native controls, retry and source selection are retained.
- Series inventory refresh failures now invalidate cached episode availability too. Rich cached metadata does not override unknown source availability.
- Extended existing global sports search with movies/series/loaded episodes, type filtering, bounded grouped results, exact matches, cached current EPG titles, and a route to the full guide. No metadata requests are issued per query. Existing team/league/event/news/podcast search is retained.
- Reused sports Game Centre navigation and score presentation, respecting spoiler preferences. Golf/motorsport/combat cards use event identity instead of fabricated two-team headings.
- Added a visible Done control to modal Settings after simulator review. New strings were extracted by Xcode into the existing String Catalog; existing translations were preserved.

## Architecture and persistence

New views: CompleteLibraryRoot, CompleteHomeView, CompleteTelevisionView, CompleteSportsView, CompleteToolbar, CompleteHero, CompleteContentRail, CompleteOnNowSection, CompleteProgrammeSearch, EntertainmentCollectionsView, EntertainmentSearchSections.

New pure policy namespace: EntertainmentDiscovery. Existing domain models remain authoritative. Canonical identity, metadata, source inventory and watch state remain separate. Movie edition grouping continues to require validated metadata identity and matching normalized provider title; title-only catalog merges are not added.

Persistence is additive: existing `banner.entertainment.progress.v1` and `banner.entertainment.watchlist.v1` remain readable and are not reset. New keys are `banner.entertainment.watchlistItems.v1`, `banner.entertainment.hiddenContinue.v1`, `banner.entertainment.historyItems.v1`, scene-scoped Home/Movies/Series navigation keys, `banner.complete.sportsVisibility.v1`, and `banner.playback.autoplayEpisodes.v1`. Existing catalog snapshots supply display data for legacy watchlist entries before source refresh can evict them. If old metadata is already gone, the ID is retained and shown as an unavailable saved title. No account/profile migration or credential migration was necessary.

Recommendations score genre overlap with locally watched/watchlisted inventory, then watchlist membership; ties use added date and stable ID. Availability and completion exclusions apply before bounded results. No AI/cloud recommendation provider was added. Ranking operates on background snapshots; Home groups episodes once by series, avoiding a series-by-entire-episode-catalog join. UI refresh keys use repository/user-state revisions rather than serializing history in view bodies.

Existing bounded metadata cache, request coalescing, image cache and disk catalog cache are reused. No bulk metadata enrichment was introduced. Provider errors remain sanitized and source references contain no playback URLs. Local watch state has no new network destination.

Portable contracts for future clients: ViewingExperience raw values; EntertainmentKind; ContentAvailability; EntertainmentItem.id/progressID; EntertainmentSource.sourceID/itemID; EntertainmentProgress fields; watchlist identity snapshots; deterministic policy inputs/outputs. Android and Fire TV code was not available or implemented. tvOS has a separate root and has not received or been verified for this Complete shell.

## Execution evidence

- Baseline BuildProject passed (6.123 s).
- Integrated BuildProject passed (29.178 s).
- Subsequent BuildProject passed (32.91 s).
- Full active test plan: 250 results, 249 passed, zero failed, one no-result test (`StreamLinkerBudgetTests/buildAndLinkBudgets()`). The no-result budget is explicitly guarded by `#if !DEBUG` (StreamLinkerBudgetTests.swift:8); it is absent from this Debug run, not a reported failure. A focused retry also returned no result. Release timing remains unmeasured. The opt-in real-fixture test returns without exercising providers unless LINKER_FIXTURE_DIR is supplied; its pass is not live-provider evidence.
- Focused final entertainment tests: 31/31 passed, including all 14 CompleteExperienceTests and 17 EntertainmentFoundationTests. Covers legacy preferences, all three modes, identity ambiguity, source grouping/editions, metadata failure, no invented episodes, secure source references, progress persistence, short/unknown duration, next episode, missing/future episodes, season transitions, specials, hidden continuation persistence, missing-provider watchlists, recommendation availability/deduplication, and 10k-title search.
- Initial measured policy timings: 10,000-title local search 0.031336584 s; conservative 22,000-entry classification producing 5,000 movies 0.116439875 s. These are simulator test observations, not startup/render/memory/playback benchmarks.
- Simulator build/install/launch succeeded. First capture attempt failed due to disk exhaustion; session cleanup was completed. After disk recovery, screenshots and accessibility hierarchy captures succeeded.
- Simulator interactions verified Live TV → Complete → Sports → Live TV; exact five Complete tabs; live EPG and recent history on Home; Movies/Series intentional empty states without Play buttons; profile Settings access; Sports Home rendering; preservation of one playlist, one followed team and three live-history entries. Original Live TV mode was restored. No new clipping/crashes observed in those screens.
- Manual verification found modal Settings lacked Done; the control was added afterwards. Final search changes and Done control are build-verified but were not part of that screenshot pass.
- `git diff --check` passed. No commits, deployment or destructive data actions were performed.

Evidence root: `/var/folders/1y/sv89fsys2gj80vtgv6lwswww0000gn/T/ActionArtifacts/14957AC5-28E1-4246-98C4-52B378ED92F6/`.

Full test result: `RunAllTests/BB532C63-1BBE-46DF-A777-D401E3D09AF0.txt`.
Focused result: `RunSomeTests/2CD438CD-F27D-4727-8193-99F4CE283E25.txt`.
UI evidence: `DeviceInteractionSynthesize/Complete UI Retry-15_19_14_887-screenshot.png` (Home), `15_19_41_175` (Movies), `15_19_46_850` (Series), `15_19_58_757` (Settings), `15_20_31_953` (Sports), `15_20_51_048` (restored mode), `15_21_07_978` (preserved source/team). Each has a matching hierarchy file and the same `Complete UI Retry-` prefix.

## Release status and remaining work

| Feature | Status | Practical limit |
| --- | --- | --- |
| Three-mode preference/navigation | Implemented and verified for listed simulator paths | Home/Movie/Series content-ID paths are scene-restored; scroll restoration and legacy screen paths remain partial; selected tab restoration is in-memory |
| Shared entertainment state | Implemented and unit verified | Single local profile; snapshots cannot recover metadata already lost before upgrade |
| Complete Home | Partially implemented; live/empty UI verified | No populated VOD hero review; no dedicated Recently Added rail, rich genre rails or complete contextual ordering across all stated scenarios |
| Movies/Series browsing and details | Implemented but populated playback journey unverified | Test simulator source supplied no VOD; rich official metadata/artwork requires configured provider |
| Continue Watching/Next Episode | Policy and persistence verified; player integration build-verified | Real stop/resume/completion/season-transition playback not executed; catch-up is not unified into this queue |
| Watchlist/history | Persistence and missing-source fallback verified | Collection offers ascending/descending title order, type/availability filters and search; full source-variant identity migration remains |
| Global search | Partially implemented and policy tested | Loaded episode inventory only; current EPG titles inline, broader EPG through guide; cancellation suppresses stale UI but detached work is not immediately terminated; existing sports index performance was not redesigned |
| Recommendations | Implemented and policy tested | Basic deterministic genre/watchlist scoring; no TMDB-related-title intersection, diversity quotas or sophisticated usage-context ordering |
| Live TV/Sports reuse | Navigation/live Home verified | Actual live/sports streaming and every league-specific journey not retested |
| Player | Shared architecture retained; progress/next option implemented | Equivalent-source recovery UI is implemented but not stream-tested; VOD screen dismissal still stops its session; mode changes during active VOD/PiP not verified |
| Metadata | Blocked by production configuration | TMDB.shared has no authorized token; licensing/approved logo requirements must be resolved before enabling production TMDB |
| Accessibility/localization | Partial | Standard labels/fonts and simulator hierarchy checked; no full VoiceOver, largest Dynamic Type, contrast or French translation completion audit |
| Large-library performance | Partial measurements | No measured cold launch, sustained scrolling, memory pressure, metadata counts or playback stability under discovery load |
| Automated UI tests | Not added/executed | Manual device-tool navigation evidence only |
| Other devices/profiles | Not implemented in this phase | iPad layout uses adaptive components but not device-tested; tvOS, Android TV, Fire TV, profile isolation and sync remain unverified/unimplemented |

The complete Phase 3 definition of done is **not yet satisfied**. This is an implemented, tested integration milestone, not a production-release certification. Release still requires authorized VOD/TMDB configuration where applicable, real movie/series/live/sports playback journeys, remaining P0 navigation/playback recovery validation, broader UI/accessibility/performance tests, and the partial feature work listed above. No fake catalogs or placeholder playback sources were added to mask those gaps.

Additional completion checks: equivalent-source recovery, collection sorting/filtering, retained history identities and scene-scoped content-ID navigation were implemented after the manual device pass. BuildProject passed after these changes (14.514 s); final focused tests passed 31/31, including new history-retention and bounded-navigation restoration tests. The final test action rebuilt the app and tests successfully after the episode-enrichment guard change.
