# Banner TV Phase 2 implementation report

Date: 2026-10-29

## Status

Phase 2 is implemented substantially in the existing application, but is **not production signed off** against every requested journey. The application builds and regression tests pass. Real source-backed series browsing was verified. Successful movie/episode playback and resume remain unverified against the configured provider; episode inventory requests failed during simulator verification. TMDB production access remains disabled pending licensing and authorized runtime configuration.

## Existing architecture preserved

The audit identified the shared RootView/navigation shell, PreferencesStore and cloud preference synchronization, PlaylistStore, KeychainStore, WatchStore, indexed channel browser, EPG repository/grid, SportsRepository, shared design tokens/CachedImage, and PlaybackController. The implementation extends these systems. It does not replace the application, recreate sports services, migrate away existing playlists or change channel identities. Preexisting Phase 1 workspace changes remain intact.

## Implemented features

- Sports and Live TV experience preferences, backward-compatible Sports default, onboarding choice, Settings selection, and configuration-driven navigation. Complete Mode is not exposed.
- Live TV tabs: Home, Channels, Guide, Library, Settings. Sports retains Home, Following, Live, Discover, Settings. Mode-specific selected tabs and shared deep-link routing remain in the common shell.
- Television-first Home with current programme information, recent channels, favourites, On Now, upcoming programmes, categories, Library access and contextual sports routes. Empty sections are omitted; launch does not autoplay.
- Hidden/Compact/Full sports preferences. Hidden gates sports refresh and player sports overlays without deleting teams or sports settings.
- Channel list/grid preference, cached logos, recent and HD/4K scopes, normalized debounced local searching, custom-group/category/cached current-programme search terms, favourite/custom-group reordering, and hidden-channel restoration.
- Existing virtualized guide and timeline are reused with programme detail/playback routes. Existing capability checks control reminders/catch-up. This is not a wholesale EPG rewrite.
- Source-backed Movies/TV Shows Library with search, category/genre filters, watchlist, recent sorting, provider artwork, details, season/episode browser, source selection and availability checks.
- On-demand integration through the existing PlaybackController using native AVKit controls. Live and on-demand URL/seek semantics are distinct. Persistent progress, resume/start-over, completion and next-available-episode selection are implemented.
- English-ready strings and 82 scoped French translations. Dynamic Type layout and selected-state accessibility improvements were made; exhaustive accessibility certification was not performed.

## New domain and service boundaries

| Component | Responsibility |
|---|---|
| ViewingExperience.swift | Mode and sports-integration contracts/settings |
| EntertainmentModels.swift | Typed content, season, episode, metadata, source reference, availability, confidence, provenance and progress contracts |
| EntertainmentSourceAdapter.swift | Xtream inventories/details/episodes and credential-time playback resolution |
| EntertainmentMetadataService.swift | Provider-neutral metadata protocol and injectable TMDB implementation |
| EntertainmentRepository.swift | Cached inventories, source synchronization, conservative canonical grouping, details, watchlist/progress and playback resolution |
| TelevisionHomeView.swift | TV-first Home and scoped local search |
| EntertainmentLibraryView.swift | Library, details, episodes and shared-controller VOD presentation |
| HiddenChannelsView.swift | Non-destructive restoration |

Content identity, provider identity and playback resolution remain separate. Normalized source records and progress contain no playback URLs or credentials. Xtream credentials are fetched from existing Keychain storage only for source requests/resolution. New adapter requests use an ephemeral session, 30-second request and 45-second resource limits; failures use sanitized errors. Automatic failed-sync attempts have a five-minute cooldown; explicit Retry bypasses it.

Provider inventory remains authoritative. Metadata enrichment never manufactures available episodes. Uncertain matching preserves original records. Canonical grouping requires verified/high-confidence metadata plus compatible provider titles; alternate cuts are retained. M3U classification requires explicit movie/series groups and supported file/numbering evidence. Ambiguous entries remain in the original channel inventory.

Persistence adds versioned bounded entertainment disk snapshots and bounded local progress/watchlist storage. Existing preference persistence and cloud synchronization carry mode preferences. Progress is local; cross-device VOD synchronization is not implemented.

## Integration status

| Integration | Actual status |
|---|---|
| Existing live IPTV/M3U/EPG | Reused; real 21,986-channel source and guide observed in simulator |
| Xtream VOD inventories/categories/details | Implemented; fixture tested; real TV Shows catalog and provider details observed |
| Xtream episode availability | Implemented and fixture tested; real provider detail lookup failed during verification; no fabricated Play action |
| M3U VOD classification | Conservative movie/numbered-series import tested with synthetic data |
| TMDB | Injected client and matching/season/image/localization boundaries tested with fixtures; production shared service disabled |
| Stremio | No marketplace or concrete addon adapter implemented; generic inventory/metadata/playback protocols are extension points |

TMDB supports details, search/IMDb resolution, credits/images through append-to-response, season metadata, configuration-based artwork URLs, bounded concurrency, in-flight deduplication, memory cache and bounded retries. French metadata requests fall back to English synopsis. Production token composition/proxy and licensing approval remain outstanding; supplied credentials were not embedded in source. Full discovery/recommendation endpoints, persistent TMDB response caching and manual matching UI are not implemented. Enriched inventory snapshots persist with the repository.

Official references: [TMDB authentication](https://developer.themoviedb.org/reference/authentication), [season details](https://developer.themoviedb.org/reference/tv-season-details), [image configuration](https://developer.themoviedb.org/docs/image-basics), [usage and attribution FAQ](https://developer.themoviedb.org/docs/faq). Settings includes attribution text and explains disabled external metadata. No commercial licensing verification is claimed.

## Verification

- Final Xcode BuildProject: successful, no build errors, 17.59 seconds (14:27 local).
- Full test suite earlier in implementation: 237 passed, 0 failed, 1 not run, 238 total. The not-run case was an existing Release-only budget test.
- Final focused regression run after latest changes: 65 passed, 0 failed, covering entertainment, channel browser, player and sports experience suites.
- Fixture tests cover numeric/string Xtream fields, secure references, identifier validation, ambiguity/remakes, season zero, authoritative episode availability, disabled metadata, localized fallback, artwork URLs, persistence and completion.
- Measured synthetic classification: 22,000 entries including 5,000 movies in 0.209 seconds on the development simulator host. This is a classification measurement, not a UI frame-rate or memory guarantee.
- Simulator interaction verified mode persistence, Sports→TV→Sports preservation, Hidden preference persistence, provider guide/current marker, source-backed TV Shows catalog and provider details. Unavailable episode details did not expose Play.
- Live playback controller reported readiness and first-frame timing around 10.9 seconds, but screenshots remained black; visible video/audio was not independently confirmed.
- Movie/episode playback/resume, Full sports integration, largest Dynamic Type sizes and physical-device behavior are not end-to-end verified. Simulator interactions are exploratory checks, not a new comprehensive XCUIAutomation suite.
- Final timeout/retry/loading-state refinements compiled and passed focused tests; they were not re-observed in the simulator after the last build.

Artifacts are under `/var/folders/1y/sv89fsys2gj80vtgv6lwswww0000gn/T/ActionArtifacts/B0FF2EC7-A2E8-4CA9-AD03-7F79186D8906/`, including final BuildProject log, RunSomeTests result bundle and `DeviceInteractionSynthesize/Verify Phase Two Final Retry-*` screenshots.

## Remaining work and limits

1. Obtain successful provider movie/episode playback and resume verification, including codec, interruption, subtitle and device coverage. The provider returned partial availability failures; do not equate implemented resolution with proven playback.
2. Complete licensed metadata runtime configuration, approved attribution assets and real API validation before enabling production enrichment.
3. Series detail loading currently resolves the first source of a canonical series; multi-source episode union and explicit per-source refresh need expansion.
4. Shared Home search covers channels and titles and routes to guide search; cached episode and sports results are not yet unified into one search surface.
5. EPG metadata enrichment, manual identity correction, full alternate-title matching, provider capability negotiation and fine-grained incremental VOD deltas are not implemented.
6. Broader performance profiling is still required for multi-thousand-series libraries and large guide windows. New classification and filtering run off-main, but canonical repository rebuilds warrant profiling at extreme sizes.
7. VOD Picture in Picture continuity across presentation dismissal, multi-device progress synchronization and exhaustive active-playback mode-switch testing remain outstanding.

## Phase 3 foundation

The shared configuration-driven shell can accept dedicated Complete navigation later. Provider-neutral models and adapters separate source inventory, canonical metadata and stream resolution. Movies/series surfaces can reuse the repository, local search and progress contracts. Future recommendations can consume canonical identities without implying availability, while a future account service can synchronize progress without transmitting credential-bearing URLs. Complete Mode is intentionally absent from selectable modes.
