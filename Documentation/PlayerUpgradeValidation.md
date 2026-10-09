# BANNER player upgrade — implementation and validation

This is a substantial integrated upgrade of the existing player, **not a claim that the entire P0–P2 definition of done has been verified**. No successful live-stream/device interaction run was obtained in this environment. The audit in [PlayerUpgradeAudit.md](PlayerUpgradeAudit.md) records the starting implementation and every requested feature.

## 1. Existing features reused

- `MyApp/PlayerView.swift`: existing iPhone portrait/landscape player, UIKit/AppKit AVPlayerLayer surfaces, controls, native iOS PiP, fit/fill/stretch modes, media-track menus, quality caps, recent-channel sheet, game-centre components, multiscreen picker and layouts. The previously disconnected `LiveScoreBug` is now connected to the video presentation.
- `MyApp/Playback/PlaybackController.swift`, `PlaybackItemFactory`, `PlaybackMetrics`: same playback engine, HTTP-header handling, startup watchdog, delayed buffering indicator and bounded reconnect policy. The primary player continues using the environment-owned controller.
- `MyApp/StreamSelection.swift`, `StreamAvailabilityStore.swift`, `StreamLinker`: existing source selection and event evidence; no second stream resolver or sports API client.
- `EPGRepository`, `EPGProgrammeStore`, `TVGuideView` and its view model: same cached programme data, timeline, filters, details and reminders.
- `WatchStore`/`ChannelPreferencesStore`, `PreferencesStore`: same favourites, history and settings persistence. No URL-bearing history or new database.
- Existing sports repositories, league-specific statistics views, notification planner, fantasy tracker, Theme tokens and channel logos.

## 2. Existing features improved

Channel switching now invalidates pending player-item observations, cancels pending seeks, rejects old preflight responses and guards media-track/sports publication after suspension. Selected channel identities include playlist identity where player selection and guide lookup require it. Raw broadcast alternatives are no longer automatically substituted after failure: manual choice is required without a canonical feed identity. Explicit event-broadcast selection now rechecks the event through the existing sports repository and shared linker before committing. Selection validation is cancelled/invalidated by newer requests or channel resets, and retry revalidates the rejected requested feed rather than restarting an unrelated active one. Raw source keys include playlist identity, preventing equal provider IDs from collapsing different feeds.

The channel drawer now supports search, categories, favourites, current-channel indication and cached now/next programme information. Filtering is cached independently of programme progress updates. Full-guide programme-detail selection returns through the existing player's selection callback. Opening the guide no longer deliberately tears down the phone player.

Player matching uses confirmed shared-linker evidence rather than player-only token bonuses, checks live status/time bounds, rejects ambiguous candidate sets and validates supplied event context. Ended events clear sports context. Linker cache signatures now change when channel identities or event-slot names change, even if playlist size stays constant.

The phone/Mac player has one major-panel state, control lock, preferred audio/subtitle languages, configurable auto-hide, capability-gated double-tap seeking and expanded shortcuts. TV channel selection, recent/previous channel, guide and sports actions switch in place. Its options sheet reuses the existing track, aspect, quality, buffer, spoiler and diagnostics controls; the focus-driven action bar scrolls horizontally and panel closure restores a control focus target. Existing TV fantasy watch actions now select their requested channel.

Multiview tiles now use isolated instances of the existing recovery controller. Layout changes preserve those controllers, and audio routing mutes all sessions before enabling the selected one. Entering multiview stops the hidden primary decoder and exiting resumes single playback.

## 3. New features implemented

### P0

- Explicit preparing, connecting, recovering and ended states alongside existing playback states.
- Request/item generation guards, asynchronous broadcast-validation ordering, playlist-scoped raw source IDs and conservative automatic failover rules.
- Searchable/filterable channel drawer with now/next guide rows and favourite toggling.
- Previous-channel action, TV in-player switching and overlay-aware remote navigation.
- In-memory control lock and source-supported, clamped double-tap seeking.
- Redacted actionable network/timeout/access/format error descriptions.

### P1

- Mac compact floating mode using the existing window and player; restores prior geometry, aspect constraint and window level.
- Mac hover controls/full-screen double-click and expanded playback shortcuts, including Cmd+1–4 saved multiview slots.
- Shared game-centre presentation and confirmed-broadcast selector connected to TV.
- Persistent audio/subtitle language choice, actual resolution/frame-rate display and an advanced diagnostics entry.
- Playlist-aware EPG lookup that rejects ambiguous channel associations.

### P2

- Three-stream layout, tile replacement/removal/maximization, return to grid, and four saved multiview slots resolved against current channel IDs, with Cmd+1–4 restoration.
- Conservative simultaneous-session budget based on memory, thermal state and low-power mode. This is a resource budget, not proof of hardware decoder capacity.
- Confirmed, favourite-team-prioritized live multiview suggestions.
- Shared bounded spoiler snapshot buffer; real-time, 15/30/60/120-second delayed score display, and hide scores. Delay is measured from receipt, not asserted video synchronization. Other audited score-bearing panels hide while delay is active to avoid leaking newer scores.
- Opt-in Commercial Break Mode preference with explicit **automatic detection unavailable** messaging. No fabricated detector, ad bypass or automatic muting.
- In-player fantasy alerts respect existing notification and spoiler preferences. Score-bearing Live Activities end immediately when spoiler protection becomes active.

## 4. Architecture changes

No replacement player, playback manager, EPG client, sports API or dependency was introduced. `PlayerView.swift` remains the existing presentation owner. Phone/Mac and TV boolean panel bindings now each adapt one platform panel enum. `PlaybackController.mediaSelections` and `selectMedia` share track discovery, identity checks and preference application across presentations; `PlayerMoreSheet` is reused on TV. `MultiScreenPlayerView` owns per-tile instances of the existing `PlaybackController`; a tile's failure remains local.

`Preferences.swift` extends the existing backward-compatible Codable schema and contains a small bounded in-memory `PlayerSpoilerBuffer`. `StreamAvailabilityStore.swift` remains the shared matching entry point, including fresh event/broadcast confirmation; `StreamSelectionState` owns the cancellable pending-selection generation. `EPGRepository.swift` extends its existing channel lookup with an optional playlist identity, retaining existing consumers' API compatibility.

Build/test configuration repairs: the app module name matches the existing tests' `BannerTV` import, the test host points to `StadiaTV.app/StadiaTV`, unit-test deployment matches the app's iOS minimum, and `BannerPlayerValidation.xcscheme` provides an explicit unit-test action. The obsolete Yahoo-provider assertion now checks the active BBC provider. The UI scrolling metric uses the SDK's supported signpost metric.

Narrow availability guards were added around ActivityKit, visionOS external playback and a visionOS-unavailable keyboard-dismiss modifier. Existing `Localizable.xcstrings` edits were preserved; Xcode also extracted new interface strings.

## 5. Platform coverage

“Implemented but not device-verified” describes source integration and compilation, not proof of playback/UI behavior. No row is marked “Implemented and verified” because physical/simulator interaction validation did not succeed. TV source integration was compiled successfully before the final broadcast-validation changes, but final TV build completion is blocked by disk exhaustion as detailed below.

| Feature group | iPhone/iPad | macOS | tvOS | visionOS |
|---|---|---|---|---|
| Shared controller, switching and recovery | Implemented but not device-verified | Implemented but not device-verified | Implemented but not device-verified | Partially implemented; visionOS build blocked |
| Drawer, favourites, now/next and full-guide routing | Implemented but not device-verified | Implemented but not device-verified | Implemented but not device-verified | Partially implemented; visionOS build blocked |
| Portrait/landscape, native PiP | Implemented but not device-verified | Unsupported by platform for the iPhone presentation | Unsupported by platform for the iPhone presentation | Partially implemented; visionOS build blocked |
| Desktop compact window/shortcuts | Unsupported by platform | Implemented but not device-verified | Unsupported by platform | Unsupported by platform |
| Remote focus/navigation | Unsupported by platform for TV remote mapping | Unsupported by platform for TV remote mapping | Partially implemented; focus restoration and all remote interactions unverified | Unsupported by platform for TV remote mapping |
| Advanced tracks/quality/aspect controls | Implemented but not device-verified | Implemented but not device-verified | Implemented but not device-verified | Partially implemented; visionOS build blocked |
| Confirmed sports context/score panel | Implemented but not device-verified | Implemented but not device-verified | Implemented but not device-verified | Partially implemented; visionOS build blocked |
| Multiview 2/3/4, tile actions, four saved slots | Implemented but not device-verified; resource budget applies | Implemented but not device-verified; resource budget applies | Implemented but not device-verified; resource budget applies | Partially implemented; visionOS build blocked |
| Spoiler protection | Partially implemented; audited player/guide/fantasy paths covered | Partially implemented | Partially implemented | Partially implemented; visionOS build blocked |
| Commercial mode settings | Implemented but not device-verified | Implemented but not device-verified | Implemented but not device-verified | Partially implemented; visionOS build blocked |
| Automatic commercial detection | Blocked by missing dependency or data | Blocked by missing dependency or data | Blocked by missing dependency or data | Blocked by missing dependency or data |

## 6. Performance and reliability

Player-item callbacks check generation and current-item identity after actor hops. Recovery ignores abandoned time-control changes during reconnect backoff, preserving bounded retry accounting. Stream-selection preflight responses check cancellation/generation. Supplemental sports and track tasks cannot publish after cancellation; scores clear on channel/event changes.

Drawers use lazy lists, cached filtering and repository lookups; no second EPG parser or network poller was added. Multiview uses at most the computed session budget and one audible tile. Saved layouts persist channel identifiers rather than private stream URLs. Diagnostics omit provider URLs/headers and redact credential-bearing engine error text.

These changes are supported by code inspection/builds, not measured startup/scrolling/long-duration playback benchmarks. Network behavior and decoder capacity still need representative authorized streams.

## 7. Testing results

Validation results are recorded below; build success and test execution are separate. The original `MyApp` scheme and `Alex’s iPhone` destination were restored. `git diff --check` passed. Failed generated build products were removed to release disk space, while logs and test-result bundles were retained.

- Final iPhone simulator **build-for-testing passed**, including app, unit-test and UI-test compilation: 13.824 seconds, `BuildProject-Log-20261008-192927.txt`. Earlier clean build-for-testing also passed (68.831 seconds).
- Final macOS build passed after the broadcast-validation changes: 48.947 seconds, `BuildProject-Log-20261008-193039.txt`. An earlier signing failure cleared after removing this project’s generated index cache.
- tvOS simulator builds passed for both simulator architectures before the last broadcast-validation changes: clean build 116.827 seconds, `BuildProject-Log-20261008-191834.txt`; incremental build 21.956 seconds, `BuildProject-Log-20261008-191914.txt`. **The final revision’s tvOS rebuild did not complete**: linking failed with errno 28 / No space left on device (`BuildProject-Log-20261008-193240.txt`), and a cache-cleanup retry failed writing x86_64 object files for the same reason (`BuildProject-Log-20261008-193412.txt`). This is an environment failure, not a passing build.
- visionOS build progressed through availability repairs but remains blocked at `MyApp/EntitlementStore.swift:87`: `purchase(options:)` unavailable in visionOS. This existing purchase presentation requires platform-specific StoreKit handling; the player upgrade does not disable purchases to force a successful build.
- Physical tvOS build was blocked by a missing provisioning profile.
- Initial `RunAllTests` returned 155 tests not run. CLI unit-test compilation succeeded after configuration repairs, but simulator launch failed with “Pseudo Terminal Setup Error”, error 7 / errno 1 / operation not permitted. No assertions passed in that attempt. Result: `/tmp/BannerPlayerValidation-verified.xcresult`.
- A debugger-free unit-test retry also compiled but failed before test execution with the same pseudo-terminal launch permission error: `/tmp/BannerPlayerValidation-no-debugger.xcresult`. No runtime unit-test passes are claimed.
- The device-interaction session could not initialize/install/launch successfully. No screenshots, rotation, PiP, remote navigation or live-stream interactions are claimed verified.
- Disk exhaustion interrupted builds and signing. Only this project's generated Products/Intermediates and symbol-index caches were cleared. Source files, test results, playlists and user settings were not deleted. Platforms were subsequently built sequentially to limit disk use.

`MyAppUnitTests/PlayerUpgradeTests.swift` adds eleven Swift Testing tests for latest selection token/identity, conservative broadcast failover, retry identity, credential-safe errors, old preferences, preference round-trip, delayed snapshot boundaries/event clearing, invalid preference clamping, duplicate provider IDs across playlists, out-of-order asynchronous broadcast validation and revalidation on retry. These are focused logic tests, not substitutes for live AVPlayer race/network tests.

## 8. Remaining limitations and acceptance work

- The complete P0–P2 definition of done is **not met**. Final tvOS rebuilding requires more free disk space; runtime tests require a functioning simulator test-runner launch environment. Live startup, rapid switching during buffering/recovery, network interruption, prolonged playback, background/foreground, orientation, PiP and memory-pressure scenarios remain unexercised.
- Three/four simultaneous decoders have not been exercised on any device. Memory/thermal budgeting cannot establish codec-specific hardware limits or provider concurrent-stream restrictions. Hidden tiles in a smaller layout may retain their allocated controller until removed/exit, within the overall budget.
- TV now shares advanced settings and has coordinated panels/focus-restoration targets. Actual remote focus scrolling, focus retention during asynchronous updates, VoiceOver and all requested mappings still require device verification.
- Full-guide embedded video preview and catch-up navigation do not yet have complete single-surface/session validation. Guide scroll-position restoration is inherited and not device-verified.
- Broadcast selection is conservative but language/region/quality labels depend on existing metadata and are not complete across every presentation. No unverified feeds are promoted as automatic replacements by the new raw-failover path.
- Statistics use existing providers only. Unknown fields remain unavailable. API errors do not intentionally stop video; stale-event expiry beyond the updated polling paths still needs end-to-end validation.
- Spoiler controls cover the audited player, guide and fantasy paths. Live Activity score leakage is suppressed, but full app-wide notification/widget auditing and exact video/stat synchronization are not complete. Delayed mode hides panels that lack delayed snapshots.
- Existing recommendations and notification services were reused; all requested new alert types (including alternative-broadcast availability) and all recommendation surfaces are not implemented.
- No reliable commercial signal exists in the current integration. Automatic detection remains explicitly unavailable.
- Audio/subtitle delay correction and some codec/buffer diagnostics are unavailable. Quality controls now enumerate advertised representation heights and apply AVPlayer resolution caps; a cap is not a guarantee of a fixed rendition. A separate native-pixel “Original” aspect option is not implemented; Fit preserves the source aspect ratio.
- Accessibility labels, reduced-motion behavior and VoiceOver-aware phone auto-hide were retained/improved, but a complete contrast/Dynamic Type/VoiceOver/device audit is outstanding.

## Final requirement audit

This matrix identifies integration versus remaining acceptance work; it does not promote a compiled UI to a device-tested feature.

| Requirement | Implementation result | Remaining work or limitation |
|---|---|---|
| P0.1 Cinematic player | Existing branding/surfaces preserved; timed controls, real metadata, accessibility guards | Pointer/keyboard focus retention and every size need interaction checks |
| P0.2 Switching | Shared player, selection/item guards, conservative failover | Real rapid-switch/network race tests blocked |
| P0.3 Drawer | Search, category, favourites, current programme/current channel | Large-playlist scrolling and preserved position need profiling |
| P0.4 Compact guide | Now/next cached guide rows in in-player drawer | No separate compact timeline presentation |
| P0.5 Controls | Existing engine actions plus TV shared settings/Go Live | Source-specific capabilities require actual streams |
| P0.6 Recovery | Existing bounded retry extended with states and stale-callback guards | Disconnection/decoder-error/long-running tests blocked |
| P0.7 iPhone layout/gestures | Existing orientation/layout preserved; seek-aware double tap and lock | Portrait/landscape/PiP regression checks blocked |
| P0.8 TV navigation | Remote mappings, coordinated panels, scrollable action bar, focus restoration target | Physical remote behavior unverified |
| P0.9 Exit | Guide selection routed to existing player; overlay-first TV Back | Guide stack/scroll restoration not exercised |
| P0.10 State | Existing stores; language, aspect and four multiview slots | Not every transient guide/focus/audio-tile choice is persisted |
| P1.1 Full guide | Existing virtualized guide and details reused; live selection repaired | Embedded preview/catch-up lifecycle not fully validated |
| P1.2 History | Existing recents connected on phone/Mac/TV; previous channel | Device interaction unverified |
| P1.3 Favourites | Existing shared store in settings/drawer/guide | Cross-device account synchronization not tested |
| P1.4 Settings | Actual variants as caps, actual tracks, fit/fill/stretch, source seek ranges | Native-pixel Original mode, track timing correction and richer diagnostics incomplete |
| P1.5 PiP/mini player | Existing iOS PiP; Mac same-window compact mode | Lifecycle/device verification blocked; no fabricated TV PiP |
| P1.6 Sports panel | Existing sport-specific UI reused, including TV | Provider-specific stats coverage unchanged; delay hides unbuffered detail panels |
| P1.7 Matching | Confirmed evidence, live/time checks, ambiguity rejection, context validation | End-to-end event/replay fixtures and runtime tests outstanding |
| P1.8 Broadcasts | Confirmed alternatives revalidated on selection, raw automatic substitution disabled | Fresh selection checks are implemented; complete language/region presentation remains dependent on provider metadata |
| P1.9 Mac | Existing desktop surface, floating compact mode, hover/fullscreen/keyboard/slots | Small-window/mouse/keyboard interaction checks blocked |
| P1.10 Adaptive UI | Existing device layouts plus TV scrolling controls | Full size/accessibility screenshot audit outstanding |
| P2.1 Multiview | Existing grid extended with 3-up, tile controls, isolated recovery, four saved slots | No simultaneous-decoder configuration device-verified |
| P2.2 Multiview suggestions | Confirmed live sources, favourite-team priority | Recommendation quality unverified on real account data |
| P2.3 Spoilers | Buffered player score snapshots; protected guide/fantasy paths; Live Activities suppressed | Full application/widget audit and delayed rich statistics incomplete |
| P2.4 Sports context | Verified context available on request; cleared on event/channel changes | Runtime freshness checks still require verification |
| P2.5 Recommendations | Existing related channels and live-event suggestions reused | Complete after-game/upcoming/unavailable recommendation expansion not implemented |
| P2.6 Alerts | Existing notification service reused; player settings/spoilers respected | New alternative-broadcast and all configurable moment alert types not implemented |
| P2.7 Commercial mode | Opt-in setting and honest unavailable state | No reliable detector/data; no automatic audio changes |
| P2.8 Customization | Existing settings plus timeout, gestures, languages, spoilers, lock and slots | Invalid mappings avoided; not every proposed customization exposed |
| P2.9 Diagnostics | Channel/session state, codec/resolution/FPS/bitrate, retries and sanitized startup summary | Audio codec, continuous buffer metrics, match confidence and EPG age not fully exposed |

Build logs are in `/var/folders/1y/sv89fsys2gj80vtgv6lwswww0000gn/T/ActionArtifacts/064C292F-60D3-48E2-BFAB-C3F434DBE71F/BuildProject/`. Test result bundles listed above were retained even when generated platform build caches were cleared. No screenshots or successful simulator-launch artifacts exist for this validation.

## Continuation — playback and integration repairs

The historical matrix above describes the earlier checkpoint. The working tree already contained further recommendation, alert, customization, native-pixel aspect, and visible-tile session work when this continuation began. This pass preserves those changes and adds:

- P0/P1: live-edge seeking now requires an indefinite-duration item, so resuming paused catch-up/on-demand content does not jump to its end. Live offsets are clamped to the advertised seek window, and nonfinite seek inputs are rejected.
- P2 multiview/customization: reopening a saved slot from the player carries its saved audio channel into the new session. Removing a tile reconciles the newly visible sessions; replacing the audible tile transfers audio selection and records the replacement in watch history.
- P2 recommendations: event and channel both identify broadcast-validation tasks, preventing a new event on the same channel from retaining an old validation request. Refresh is available, followed-league changes restart loading, duplicate events are removed, and schedule errors are distinguished from an empty schedule.
- P2 alerts: current preferences are checked before scheduling and foreground display, including already queued alerts. Explicit reminders remain available independently of automatic favourite notifications, while score-bearing reminders still honor spoiler protection. Failed submissions release their deduplication reservation; reminder scheduling reports delivery failure.
- Added three Swift Testing regressions covering live seek boundaries, updated alert preferences, and explicit-reminder spoiler protection. Added the missing CoreGraphics import needed by the existing native-pixel aspect test.

Validation for this pass:

- iPhone 17 Pro simulator build-for-testing passed (50.428 seconds; `BuildProject-Log-20261008-213712.txt`).
- The simulator executed all 29 selected player/notification tests: 28 passed, including all three new regressions. The existing native-pixel sizing test failed only because exact equality compared `1000.0000000000001` with `1000`. Its assertion now uses a tolerance of `0.000001` points. The corrected test compiled successfully, but its focused runtime rerun did not return after several minutes; Xcode reported no running app when asked to stop, and the waiting tool call was terminated. No runtime pass is claimed for that corrected assertion.
- The completed test result is `RunSomeTests/Test-BannerPlayerValidation-2026.10.08_21-37-23--0400.xcresult` under `/var/folders/1y/sv89fsys2gj80vtgv6lwswww0000gn/T/ActionArtifacts/94A54B8F-68FF-4D94-9F7C-987A475E8D9B/`.
- No new live-stream or UI interaction verification is claimed. The earlier blanket statement that runtime tests could not launch no longer applies to the completed 29-test run.
- Final tvOS simulator build passed for the generic arm64/x86_64 destination (313.38 seconds; `BuildProject-Log-20261008-215339.txt` in this pass's artifact directory). Restored the original `BannerPlayerValidation` scheme's `iPhone 17 Pro` destination. `git diff --check` passed. macOS and visionOS were not rebuilt during this continuation.
