# Netflix-inspired streaming experience — implementation status

Working document for the roadmap in the task brief. The local working tree is authoritative; commit
`8896bf039de1148c76450cd3728938bedfaba402` (pushed to `main`) is the audit reference only.
Update this file at the end of every task. Never mark something done that was not built and run.

Legend: **Done** (built, tested, wired) · **Partial** (what exists is noted) · **Not started** · **Blocked**.

---

## Phase 0 — Architecture and regression baseline

**Status: Done (2026-11-27).**

### 0.0 Regression baseline (before any change)

| Check | Command | Result |
|---|---|---|
| Shared core unit tests | `:bannerCore:macosArm64Test` (mirror at `/Volumes/BannerBuild/src/nuvio-enhanced`, synced from the working tree) | **560 tests, 0 failures, 0 errors, 0 skipped** (52 result files) |
| composeApp tests | `composeApp` `androidHostTest`/`commonTest` have pre-existing compile errors (see `home-discovery` notes); new composeApp-level logic is therefore tested through `bannerCore` | not a baseline — documented limitation |

### 0.1 Playback lifecycle as it exists today

Title selected → `StreamsScreen`/`PlayerStreamsRepository` (source selection) → `PlayerDestination` → `PlayerScreenRuntime`
(`features/player/PlayerScreenRuntime*.kt`) → engine:

* **iOS:** `iosApp/iosApp/Player/PlaybackBackendPolicy.swift` chooses AetherEngine or libmpv (`PlaybackEngineChoice`:
  automatic / aether / mpv; pure, unit-tested; one fallback per attempt) → `HybridPlayerBridge` → `AetherBridgeAdapter` / `MPVPlayerBridge`.
* **Android:** `PlayerEngine.android.kt` (Media3). **Mac (native SwiftUI):** `macApp/.../PlayerScreen.swift` (libmpv).
* The engine publishes a `PlayerPlaybackSnapshot` (position, duration, isPlaying, isEnded, …) polled by the runtime.

Per snapshot the runtime (`PlayerScreenRuntimeEffects.kt`):

* persists progress (`WatchProgressRepository.upsertPlaybackProgress` / `flushPlaybackProgress`, 60 s tick + on pause/end/exit);
* drives external scrobbling through `TrackingScrobbleCoordinator` (start/pause/stop/seek, request generations guard stale starts);
* feeds `LetterboxdRuntime.onPlayerSnapshot` (movies) and `SerializdRuntime.onPlayerSnapshot` (episodes), each with its own coverage tracker;
* decides the Next Episode card (`PlayerNextEpisodeRules.shouldShowNextEpisodeCard`) and autoplay (`PlayerNextEpisodeAutoPlay`);
* decides the movie recommendation stage (`PlayerNextEpisodeRules.movieRecommendationStage`, reading `playerMeta.moreLikeThis`);
* loads skip data: `SkipIntroRepository` (IntroDB, AniSkip, Anime-Skip via ARM/Simkl id mapping) merged with embedded chapters
  (`ChapterSkipIntervals`, `mergeSkipIntervals`).

### 0.2 Ownership map (who owns what today)

| Concern | Owner today | Problem found |
|---|---|---|
| Playback session identity | `PlayerLaunch` + `activePlaybackKey` in the runtime | per-player-instance only; an engine fallback is not tied to a durable session id |
| Current position / duration | `PlayerPlaybackSnapshot` | fine |
| Actual viewing coverage | **only** `WatchedCoverage` inside `LetterboxdPlaybackTracker` (and a Serializd twin) | local Continue Watching and Trakt/Simkl never see coverage; exists only when those integrations are on |
| Narrative completion | nobody | credits start is used for *timing UI*, never for *completion* |
| User-marked completion | `WatchingActions` / `WatchedRepository` | fine, explicit override |
| History / scrobbling | `WatchedRepository`, `TrackingScrobbleCoordinator`, provider adapters | each provider decides independently |
| Continue Watching projection | `WatchProgressRepository` + `WatchProgressRules` + `watching/domain` policies | position-based completion |
| Next episode selection | `PlayerNextEpisodeRules.resolveNextEpisode` + `watching/domain` | sound; reused |
| Recommendation state | `bannerCore` `RecommendationEngine` (Home) | the player does not use it (reads `moreLikeThis`) |

### 0.2 Completion thresholds that exist today (all independent)

| Where | Rule | Source |
|---|---|---|
| Local Continue Watching / `isProgressComplete` | `isEnded` **or** position ≥ **90%** (position-based: dragging to 90% completes); streams < 121 s are treated as placeholders | `watching/domain/WatchingPolicies.kt:9,24` |
| Trakt progress projection | progress ≥ **90%** | `trakt/TraktProgressRepository.kt:48` |
| Simkl projection / scrobble stop | ≥ **80%** → scrobble, else pause | `simkl/SimklProjections.kt:781`, `SimklScrobbleResult.kt:132` |
| Letterboxd | unique **coverage** ≥ **95%**, or player end with coverage ≥ **60%**; seeks are not watching | `bannerCore/.../LetterboxdPlaybackTracker.kt` |
| Serializd | per-profile `completionThreshold` default **0.90**, coverage-based | `bannerCore/.../SerializdModels.kt:209`, `SerializdManager.kt:459` |
| Next Episode card | credits/outro start, else user threshold (97–100% or 0–3.5 min before end); heuristic post-credits scene | `PlayerNextEpisodeRules.kt` |
| Movie recommendation card | credits start + 4 s, else last 4 min, last 30 s, ended | `PlayerNextEpisodeRules.movieRecommendationStage` |

Platform-independent decisions: all of the above (they are pure functions of position, duration, segments, coverage).
Engine-dependent: only the snapshot source and seeking.

### 0.3 Defects confirmed against the current tree

1. **Movie credits ignored (confirmed).** `SkipModels.kt:53` emits type `movie-credits`; `PlayerNextEpisodeRules.OUTRO_SEGMENT_TYPES`
   is `{outro, ed, mixed-ed}`; `creditsStartMs()` filters by it, so a movie with valid IntroDB credits falls back to the "last 4 minutes" guess.
2. **No typed segment model (confirmed).** Segment categories are decided from raw strings in ≥ 8 places with disagreeing alias sets
   (`segmentCategory` knows `credits`/`ending` but not `movie-credits`; `OUTRO_SEGMENT_TYPES` knows none of them; `AutoSkipSegmentType` knows all;
   `SkipIntroButton`, `InternalSkipAction`, `PlayerScreenRuntimeEffects:1181`, `ChapterSkipIntervals` each carry their own).
3. **Early return on IntroDB opening (confirmed).** `SkipIntroRepository.getSkipIntervals` returns as soon as IntroDB has an opening
   (`:81-89`), so recap/credits from other providers are never resolved and the unfinished result is cached.
4. **Cache is IMDb-keyed, unbounded, in-memory (confirmed).** `HashMap` keyed `imdb:season:episode`; no edition, duration, expiry or negative cache.
5. **Sentinel end time.** Anime-Skip's open-ended ending uses `Double.MAX_VALUE`.
6. **Watch Credits reset (confirmed).** `PlayerScreenRuntimeEffects.kt:886-891` sets `nextEpisodeCardDismissed = false` when playback ends
   (and autoplay is on), undoing an explicit "Watch Credits". `movieRecommendationDismissedStage` is also reset when the stage returns to 0.
7. **`isProgressComplete` is position-only** — seeking to 90% completes a title.

### 0.4 Decisions

* New pure shared policy code lives in `bannerCore` (`com.nuvio.app.features.playback`), tested in `bannerCore/commonTest`
  (`:bannerCore:macosArm64Test`). `composeApp` adapts to it; no module migration beyond moving the dependency-free `SkipModels.kt`
  into `bannerCore` under the same package (source compatible).
* Existing behaviour is kept until the replacement is wired and verified.

---

## Status at a glance (Phases 0–5; Phase 6 and 7 were not started, by instruction)

"Wired" means the user can reach it in the app. "Core only" means the decision logic exists in `bannerCore` with tests but nothing in
the app calls it yet. Nothing below has been run on a device or in a full Xcode/Mac build.

| Phase | Status | Wired into the app | Core only (tested, not yet called by the UI) |
|---|---|---|---|
| 0 Baseline | Done | — | — |
| 1 Segments + completion | **Mostly done** | 1.1, 1.3 (SkipDB), 1.4, 1.5, 1.7 (shadow mode), 1.8 (local ledger) | 1.8 provider adapters; 1.6 Skip-button targets |
| 2 Post-Play | **Partly done** | 2.2, 2.3, 2.4, 2.10, protected-scene holdback | 2.1 state machine runtime; **not started:** 2.5–2.9 |
| 3 Personalization | **Core only** | nothing | 3.1–3.9 |
| 4 Discovery | **Core only** | nothing | 4.1–4.5 |
| 5 Smart Downloads | **Partly done** | 5.1 Download Next Episode, 5.3 (most of the simple settings), pin + origin labels | 5.2 Downloads for You, 5.4 reconciler |

Tests: `:bannerCore:macosArm64Test` went from 560 (baseline) to **773 tests, 0 failures, 0 errors, 0 skipped**. `:composeApp:compileAndroidMain`
and `:composeApp:compileKotlinIosSimulatorArm64` both build. Nothing is committed or pushed.

---

## Phase 1 — Playback segments and unified completion

| Task | Status | Wired into the app? |
|---|---|---|
| 1.1 Movie credits recognition / typed categories | **Done** | Yes (every raw-string site uses the normalizer) |
| 1.2 Shared segment contract + validation | **Done** | Yes: arbitration, validation and `creditsStartMs` use it. `PlaybackSegment` is the contract; `SkipInterval` stays the player's carrier |
| 1.3 SkipDB provider | **Done** | Yes (queried with the playing video's duration; 404 = no data, 429/5xx = retryable error) |
| 1.3 TheIntroDB provider | **Blocked** | No: its raw HTTP contract is not stated in its public docs, so nothing was guessed |
| 1.4 Segment-level arbitration, no early return | **Done** | Yes (`SkipIntroRepository` no longer returns at the first IntroDB opening; results are published incrementally) |
| 1.5 Edition-aware, bounded cache | **Done** | Yes (`SegmentCache`; negative caching for SkipDB only, see limits) |
| 1.6 Protected scenes | **Partial** | The takeover holdback is wired; the Skip button does not use `creditsSkipTarget` and has no "Skip to bonus scene" string |
| 1.7 Unified completion policy | **Shadow mode** | `PlaybackCompletionRuntime` runs it for every session and logs disagreements with the old 90% rule; `PlaybackFeatureFlags.unifiedCompletion` is **false**, so the old rule still decides and there is no UI switch for the flag |
| 1.8 Completion events | **Partial** | Idempotent local `CompletionLedger` with per-provider pending queues is recorded in shadow mode; **no adapters** yet for Trakt/Simkl/Letterboxd/Serializd/local progress |
| 1.9 Continue Watching behaviour | Not verified | Existing behaviour untouched |

### What was discovered, decided and built

* **Existing implementation** (Phase 0 §0.3): the movie-credits defect was real — IntroDB's `movie-credits` was in no outro set, so movie credits never
  triggered the recommendation. Five independent completion thresholds existed (local 90%, Trakt 90%, Simkl 80%, Letterboxd 95% coverage / 60% ended,
  Serializd 0.90).
* **Decisions:** one typed category normalized in one place (matching is on the whole label: `Opening Credits` → intro, `credits roll` → unknown);
  provenance kept (`SegmentSource`, `SegmentMediaContext`); a segment must pass validation (placeholder < 121 s, plausible location, 2% duration
  tolerance, edition match) before any automatic action; low-confidence and approximate matches are manual-skip only; completion is coverage-based
  (a seek adds nothing) and runs beside, not instead of, the old rule until it is judged on real playback.
* **bannerCore, `features/playback/`:** `PlaybackSegment`, `SegmentValidation`, `ProtectedScenes`, `PlaybackCompletion`, `MovieEndingStage`,
  `SegmentArbiter` (rank: user correction → chapters → matched provider → consensus → loose → low-confidence; clusters by stretch; credits cut around
  scenes), `SegmentCache` (bounded, TTL, negative TTL, stale grace, injected clock), `CompletionEvents` (ledger, coverage store, session tracker,
  feature flag), `PostPlay` (see Phase 2). **`features/player/skip/`:** `SkipModels.kt` (moved from composeApp, same package), `SkipIntervalSegments.kt`,
  `SkipDbProvider.kt`.
* **composeApp:** `SkipIntroRepository` (rewritten: arbitration, duration refinement, cache), `PlayerNextEpisodeRules`, `InternalSkipAction`,
  `AutoSkipSegmentType` (auto-skip also requires a trusted segment), `SkipIntroButton`, `PlayerScreenRuntimeEffects/Ui/SourceActions/PlaybackActions`,
  `PlayerPlaybackOverlays`, new `watchprogress/PlaybackCompletionRuntime.kt`, `WatchProgressRepository.upsert` (consults the policy only when the flag is on).
* **Behaviour changes to be aware of (intended):** (1) movies with IntroDB credits show the end-of-movie recommendation 4 s after the credits start instead
  of in the last 4 minutes, which is why the protected-scene holdback is wired with it; (2) `segmentCategory("movie-credits")` is now `"ending"`.
* **Tests:** `PlaybackSegmentTypeTest` 9, `IntroDbMovieCreditsRegressionTest` 7 (real IntroDB movie response), `SegmentValidationTest` 14,
  `ProtectedScenePolicyTest` 9, `PlaybackCompletionPolicyTest` 16, `PlaybackCoverageAccumulatorTest` 6, `MovieEndingStageTest` 6, `SegmentArbiterTest` 10 +
  limit 1, `SegmentCacheTest` 7, `SkipDbProviderTest` 10, `SkipFlowSemanticsTest` 3, `CompletionEventsTest` 11, `SkippedOpeningCreditTest` 5.
* **Mutation checks:** removing the `movie-credits` alias fails exactly the 5 targeted tests (restored).

### Phase 1 acceptance cases

| Case | Covered by |
|---|---|
| IntroDB movie-credits normalization | `IntroDbMovieCreditsRegressionTest` |
| Opening credits vs end credits | `PlaybackSegmentTypeTest`, `ProtectedScenePolicyTest`, `SegmentValidationTest` |
| Movie with several protected bonus scenes | `ProtectedScenePolicyTest` (130-min scenario), `PlaybackCompletionPolicyTest` |
| No timestamp data / unknown credits | `PlaybackCompletionPolicyTest`, `IntroDbMovieCreditsRegressionTest` |
| Different theatrical / extended editions | `SegmentValidationTest`, `SegmentArbiterTest`, `SegmentCacheTest` |
| Invalid or overlapping timestamps | `SegmentValidationTest`, `SkipDbProviderTest` |
| Provider disagreement, several same-type segments | `SegmentArbiterTest` |
| Stream switching during a segment | `PlaybackCoverageAccumulatorTest` (accumulator only) |
| Seeking directly to 99%, two sessions, skipped intro, credits, protected scene exit, rewatch, error clips | `PlaybackCompletionPolicyTest`, `SkippedOpeningCreditTest` |
| Confirmed absent vs no data vs provider error | `SkipDbProviderTest`, `SegmentCacheTest` (negative caching) |
| Duplicate / offline completion events | `CompletionEventsTest` (ledger only; no provider adapters yet) |
| Profile switch during playback, stale async responses | partly (cache keys; session-scoped results) — **no app-level test** |

---

## Phase 2 — Post-Play

| Task | Status |
|---|---|
| 2.1 Shared state machine | **Core done** (`PostPlayStateMachine`, 13 states, 19 tests). The runtime uses its eligibility and takeover rules, not the full machine |
| 2.2 TV episode ending experience | **Done, wired** — `PostPlayEpisodeActions` (identifier text, *Watch Credits* secondary, *Next Episode* primary with a countdown fill, accessibility descriptions) replaces the old `NextEpisodeCard` (left in the tree, now unused) |
| 2.3 Autoplay countdown | **Done, wired** — 5 s (was 3 s), cancels on interaction |
| 2.4 Watch Credits | **Done, wired** — sticky (`watchCreditsChosen`) so the end-of-file reset no longer re-arms autoplay |
| 2.5 Next-episode preparation (semantic track matching, expiry fallback) | Not done |
| 2.6 Cinematic movie Post-Play | Not done |
| 2.7 Movie recommendation ranking | Not done |
| 2.8 Trailers during Post-Play | Not done |
| 2.9 Final-episode recommendations | Not done |
| 2.10 Are You Still Watching? | **Done, wired** — `UnattendedViewingTracker` (3 automatic episodes, or 90 minutes on TV; a 6 h gap resets it); a manual seek, skip or visible controls count as interaction. Interaction detection is heuristic |

Tests: `PostPlayStateMachineTest` 19, `UnattendedViewingTrackerTest` 5. A real defect was found by the state-machine tests (automatic takeover stayed allowed
in not-yet-eligible branches while a protected scene was ahead) and fixed once in `decide`. **No visual or device verification of the new post-play UI.**

---

## Phase 3 — Advanced personalization (core only)

`bannerCore/.../features/personalization/Personalization.kt`, 20 tests (`PersonalizationTest`). **Nothing is connected to Home, details, menus or the
recommendation engine's inputs yet.**

| Task | Built (core) |
|---|---|
| 3.1 Signals | `RatingConsolidator` — newest rating wins, ties go to source priority, the original value is kept |
| 3.2 Feedback | `PreferenceFeedbackStore` — per profile; Not Interested is separate from taste; reset supported |
| 3.3 Refresh | `RecommendationRefreshPolicy` — order-independent fingerprint, 60 s debounce, 6 h expiry |
| 3.4 Endless rows | `EndlessRowPolicy.nextPage` |
| 3.5 Hero | `HeroSelector` — genre cap 2, franchise cap 1, stable per day and profile, artwork required |
| 3.6 Match | `MatchPresentation` — percentile labels; a percentage only with ≥ 30 evidence items, ≥ 20 in the distribution and spread ≥ 0.05 |
| 3.7 Explanations | `RecommendationExplainer` |
| 3.8 Adaptive order | `AdaptiveHomeOrder` — anchors fixed, manual order wins, no reordering while the viewer scrolls |
| 3.9 Artwork | `ArtworkSelector` — shape, language, resolution, votes, seeded tie-break, user override |

---

## Phase 4 — Intelligent discovery (core only)

`bannerCore/.../features/discovery/` (`SearchQuery.kt`, `Discovery.kt`), 16 tests (`SearchQueryParserTest` 10, `DiscoveryLogicTest` 6). **Not connected to the
Search screen, Home, notifications or Library.**

| Task | Built (core) |
|---|---|
| 4.1 Natural-language search | `SearchQueryParser` — deterministic, no network or AI service; produces removable chips; an ordinary title or a quoted query is left exactly as typed; `toDiscover` maps to TMDB Discover parameters and returns names that still need an id lookup and filters that must be answered locally (watched, saved, availability) |
| 4.2 Microgenres | `MicrogenreCatalog` (10 definitions); a category with too few real results is hidden, never padded; taste leads, season gives a lift |
| 4.3 Coming Soon / New & Hot | `ReleaseLabeler` — a theatrical date never makes a title playable; only a confirmed listing does |
| 4.4 Reminders | `ReminderEngine` + `ReminderStore` — per profile, each stage sent at most once, "now available" never from a date alone, a moved date re-arms the date stages, cancel supported |
| 4.5 My BannerTV | `MyBannerTv.sections` — composition of existing Library content; empty sections omitted |

---

## Phase 5 — Smart Downloads

| Task | Status |
|---|---|
| 5.1 Download Next Episode | **Done, wired** (not yet exercised against real addon streams) |
| 5.2 Downloads for You | **Core only** — `ForYouPlanner` and the history store are tested; **there is no switch and no coordinator**, so nothing runs |
| 5.3 Settings | **Mostly** — switch, storage limit, quality, episodes to keep ready (1–3) and delete-finished policy are on the Downloads settings page. "Wi-Fi only" is the existing *Allow mobile data* setting (inverted), not a second switch |
| 5.4 Native execution | Existing background mechanisms untouched; `DownloadReconciler` is **core only** (not called by the native layers); failures are classified and an expired link is re-resolved at once |

### How 5.1 works

* **Core (`bannerCore/.../features/smartdownloads/`):** `NextEpisodePlanner` reads settings, device conditions, the series' episode list, the finished episodes
  (from the shared completion events) and what is on the device, and returns *cancel, remove, enqueue* plus a reason for everything it did not do.
  * Only a series the viewer has downloaded something of is managed, and only once they have finished an episode.
  * It keeps the next 1–3 aired, unwatched episodes after the last finished one. A finished episode is deleted **only after the replacements are on the
    device**; it is given up first only when the replacement cannot fit otherwise, and never when it still would not fit.
  * Never deleted: pinned, retained, playing, an unfinished transfer, the series' last aired episode (unless the viewer chooses), and — by default —
    anything the viewer downloaded themselves (the delete policy is *Never / Automatic ones / All finished*; "All finished" is the viewer's explicit choice).
  * Gates: offline, cellular when Wi-Fi only, charging, free space above a 1 GB reserve, device-wide automatic limit, per-profile budget (manual downloads
    never count against either), retry back-off (15 min, 2 h, 12 h), 3 attempts, and a removal by the viewer is final.
  * Turning the feature off cancels unfinished automatic transfers and keeps everything finished.
  * `DownloadRecovery`, `DownloadFailures` (HTTP status or message → expired / gone / network / storage / file), `DownloadSourceSelector` (direct HTTP files only,
    quality cap, the viewer's provider breaks ties), `DownloadReconciler`, `SmartDownloadHistoryStore`, `ReleaseDates`, `EstimatedDownloadSize`.
* **App wiring (composeApp, `features/downloads/`):** `SmartDownloadsCoordinator` runs on: an episode finished (`PlaybackCompletionRuntime`), a download completed or
  failed, the player closing, a setting change, and app start. It builds the planner's inputs, then carries the plan out through the existing
  `DownloadsRepository` (on the main dispatcher). `PlayerStreamsRepository.fetchOnce` finds a source without touching the player's panels (it does not wake
  paused local plugin search). A direct file link wins; otherwise up to three debrid-resolvable streams are tried. `DownloadItem` gained `origin` and `pinned`
  (defaulted, so saved downloads load unchanged); an automatic request never replaces anything but a failed automatic attempt; `cancelDownload(byUser = false)`
  keeps the coordinator's own removals from being read as the viewer saying no. The Downloads screen labels automatic downloads and has a *Keep* button.
  `DeviceStorage` (Android `StatFs`, iOS file-system attributes) supplies free space. New strings are in the default `strings.xml` only.

### Phase 5 acceptance cases

| Case | Covered by |
|---|---|
| Completion queues next download | `NextEpisodePlannerTest.finishingEpisodeOne…` |
| Already downloaded next episode | `…anAlreadyDownloadedNextEpisode…` |
| Insufficient storage | `…insufficientStorage…`, `…aFinishedAutomaticEpisodeIsGivenUpFirst…`, `…freeingEverythingDeletable…` |
| Offline device / cellular restrictions | `…anOfflineDevice…`, `…cellularRestrictions…` |
| Source unavailable | `…anUnavailableSource…`, `DownloadRecoveryTest.sourcesThatCannotBeSaved…` |
| Expired stream URL | `DownloadRecoveryTest.anExpiredStreamUrl…`, `DownloadReconcilerTest.aSourceThatExpired…`, `SmartDownloadHelpersTest` |
| Interrupted download / app terminated by the OS | `DownloadReconcilerTest` (core only — see 5.4) |
| Manual download remains protected / last episode | `NextEpisodePlannerTest.manualDownloadsRemainProtected…`, `…theLastEpisode…`, `ForYouPlannerTest.manualDownloadsAreNeverCleared…` |
| Profile-specific storage budgets | `…storageBudgetsArePerProfile…`, `ForYouPlannerTest.theBudgetAndStorage…` |
| Smart Downloads disabled during transfer | `…disablingSmartDownloadsMidTransfer…`, `ForYouPlannerTest.disablingStops…` |
| Restricted title cannot be automatically downloaded | planner: `…aRestrictedTitle…`, `ForYouPlannerTest.excludes…`. **The app always passes `restricted = false`** — there is no maturity model until Phase 6 |

Mutation check: letting automatic-delete touch manual downloads and ignoring `pinned` fails exactly the 2 targeted tests (restored).

---

## Validation (this work)

| Step | Result |
|---|---|
| `:bannerCore:macosArm64Test` before | 560 tests, 0 failed |
| `:bannerCore:macosArm64Test` after | **773 tests, 0 failed, 0 errors, 0 skipped** (+138 playback and segments, +20 personalization, +16 discovery, +39 smart downloads over the 560 baseline) |
| `:composeApp:compileAndroidMain` | BUILD SUCCESSFUL (after Phase 5 wiring) |
| `:composeApp:compileKotlinIosSimulatorArm64` | BUILD SUCCESSFUL (after Phase 5 wiring) |
| composeApp unit tests | **not run** — that source set has pre-existing compile errors |
| Full Xcode app build, Mac app build, device or simulator run, TestFlight | **not run** |
| Real addon streams / real downloads through Smart Downloads | **not run** |

## Known limitations

* TheIntroDB is not integrated (no documented wire contract). IntroDB and the anime clients swallow errors, so they cannot yet report "provider error" apart
  from "no data"; only SkipDB feeds negative caching.
* Duration refinement of segments can lose to a late initial lookup that overwrites it.
* The completion policy only observes (flag off). Provider adapters for the ledger do not exist.
* The Skip button ignores `creditsSkipTarget`; chapters classify mid-credits as post-credits.
* The unattended-viewing interaction signal is a heuristic (controls shown, manual seek or skip).
* Smart Downloads: retries are evaluated when the app next runs a pass (launch, completion, settings change), **not on a timer** — nothing is scheduled for
  when the app is closed, and iOS may not run code in the background; the operating system keeps transfers already started. Charging-only exists in the planner
  but has no UI and no platform signal. Audio/subtitle/source preferences and the per-profile budget have no UI. Sources behind a debrid resolve are tried at most
  three per episode. Free-space on iOS is the home volume, not a custom download location.
* Phase 3 and 4 logic is not connected to any screen.

## Manual validation still required

* Movie with IntroDB credits: recommendation ~4 s after credits begin; with a post-credits scene it must wait for the scene.
* Episode end: the two actions, countdown (5 s), *Watch Credits* stays on the credits, *Still watching?* after 3 automatic episodes.
* Download a show manually, finish episode 1, confirm: episode 2 stays, the next episode appears as *Added automatically*, episode 1 is removed only after
  that one finishes (with *All finished*) and is kept by default; *Keep* protects an episode; deleting an automatic download by hand does not bring it back;
  switching the feature off mid-transfer stops unfinished automatic downloads.
* Smart Downloads with real addon streams, a debrid-only setup, an expiring link, low storage, mobile data, and an app relaunch mid-transfer.
* Existing Downloads screen and manual download flow unchanged (replace, pause, resume, delete).

## Remaining work (next, in order)

1. Phase 5: Downloads for You coordinator + switch (recommendation candidates, source check, history), native reconcile wiring, charging signal.
2. Phase 3/4: connect the core logic to Home, details, search, notifications and Library; run the Phase 3/4 acceptance cases at app level.
3. Phase 2: 2.5–2.9; wire the remaining state-machine rules.
4. Phase 1: provider adapters for the ledger, Skip-button targets and "Skip to bonus scene", TheIntroDB (needs its contract), error-vs-no-data for IntroDB.
5. Turn the unified completion flag on after the shadow log has been reviewed on real playback.
6. Phases 6 and 7.
