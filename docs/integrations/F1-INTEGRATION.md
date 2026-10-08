# Native Formula 1 integration

Status: implemented and exercised with real live-service subscription and archived race data. Final acceptance remains open for live high-frequency telemetry/position UI during an active session, tvOS focus on a simulator/device, and Instruments profiling. The latest whole-app rebuild is currently blocked by concurrent NBA files, not by a reported F1 diagnostic.

## Runtime path

`SportsRepository → F1Provider → Jolpica calendar → canonical session ID → F1RaceCentreView → F1RaceCentreViewModel → SignalR or official archive → topic store → canonical session state → native views`.

Native URLSession only; no ESPN primary path, OpenF1 subscription, backend, account credentials or embedded token. Calendar identities use season/round/session kind; current-session drivers come from DriverList, without a fixed lineup or car count. Existing NHL/MLB paths and intentional provider deletions were preserved.

## Files

Created `MyApp/F1/`:

- `MyApp/F1/API/F1LiveTimingEndpoint.swift`
- `MyApp/F1/API/F1SignalRClient.swift`
- `MyApp/F1/API/F1SignalRProtocol.swift`
- `MyApp/F1/Compression/F1CompressedPayloadDecoder.swift`
- `MyApp/F1/DTO/F1Value.swift`
- `MyApp/F1/Mapping/F1TimingMapper.swift`
- `MyApp/F1/Services/F1ArchiveService.swift`
- `MyApp/F1/Services/F1CalendarService.swift`
- `MyApp/F1/Services/F1HTTPClient.swift`
- `MyApp/F1/Services/F1LiveSessionService.swift`
- `MyApp/F1/Services/F1LiveSnapshotService.swift`
- `MyApp/F1/Services/F1Provider.swift`
- `MyApp/F1/Services/F1ReplayClient.swift`
- `MyApp/F1/Services/F1ResultsService.swift`
- `MyApp/F1/Services/F1SessionCache.swift`
- `MyApp/F1/State/F1DeltaMerger.swift`
- `MyApp/F1/State/F1SessionState.swift`
- `MyApp/F1/State/F1TopicStateStore.swift`
- `MyApp/F1/UI/F1CalendarView.swift`
- `MyApp/F1/UI/F1DriverDetailView.swift`
- `MyApp/F1/UI/F1RaceCentreView.swift`
- `MyApp/F1/UI/F1RaceControlView.swift`
- `MyApp/F1/UI/F1StrategyView.swift`
- `MyApp/F1/UI/F1TimingViews.swift`
- `MyApp/F1/UI/F1TrackMapView.swift`

Created `F1CoreTests/` with a Swift Testing package, direct runner, four test suites and recorded archive fixtures. Modified shared provider registration/identity, provider diagnostics, iOS/tvOS MatchDetailView routing and F1-specific driver/constructor terminology in shared standings, and the existing racing section’s obsolete source comment. Radio reuses PodcastStore’s single player; no second audio player was introduced.

## Protocol and state

- SignalR Core OPTIONS cookie priming (405 tolerated), POST negotiateVersion=1, WebSocket connectionToken, JSON handshake and Subscribe invocation, record-separator framing, completion snapshots, feed invocations, pings and close messages.
- Independent actor topic store; recursive object merge, array-to-indexed-object patches, explicit null/deletion handling, stale timestamp rejection, session identity/generation checks and fresh snapshots after reconnect/session change.
- Base64 → zlib raw DEFLATE (`inflateInit2(-MAX_WBITS)`) → JSON, with a 16 MB expansion limit. A bad compressed update preserves prior valid state.
- Reconnect delays 2/4/8/16/30 seconds; 40-second stale-socket watchdog; Retry-After handling; authentication rejection fails without credentials.
- Shared score discovery uses a coalesced 30-second lightweight SignalR snapshot with an eight-second deadline near session time; live labels come from feed state, not scheduled time.
- Background task cancellation and cached-state retention; foreground reconnect. Future sessions wait efficiently until the connection window. Finalised classifications freeze.
- High-frequency state publishes at most 5 Hz into a separate observable leaf; ordinary timing coalesces to 2 Hz with a trailing update; control/status publishes immediately. Telemetry history and position trails use bounded rings.

Subscribed topics: Heartbeat, DriverList, ExtrapolatedClock, RaceControlMessages, SessionInfo, SessionStatus, SessionData, LapCount, TimingData, TimingStats, TimingAppData, TrackStatus, WeatherData, TeamRadio, TopThree, CarData.z, Position.z, TimingDataF1, PitLaneTimeCollection, PitStopSeries, LapSeries, CurrentTyres, TyreStintSeries, ChampionshipPrediction, DriverRaceInfo and OvertakeSeries. Optional topics are retained without assuming availability; not every optional topic has a dedicated visualization.

## Sources, caching and UI

- Jolpica: season calendars, constructors/drivers, championship standings and official race classifications. Official classifications enrich archived timing and provide a fallback if an archive is unavailable. Six-hour calendar cache and 30-minute standings cache.
- Official F1 static archive: yearly index resolves past session paths by session type/start time; session index discovers available snapshots. It is never the future calendar source.
- Normalized snapshots persist as atomic JSON in the existing cache-directory style. No high-frequency sample stream is persisted. Cached data is labeled and never creates a healthy LIVE indicator.
- Overview, Timing, Track, Strategy, Race Control and Radio tabs; season calendar/results navigation; driver detail with sectors/mini-sectors, traps and telemetry; Practice, Qualifying Q1/Q2/Q3, Sprint Qualifying, Sprint and Race labels/semantics.
- Responsive timing/detail layout, focusable controls, Dynamic Type text styles and accessibility labels. Existing premium/spoiler preferences remain in force.
- Track view uses actual coordinates and bounded observed trails, aspect-preserving transforms and selectable markers. No fabricated circuit shape or coordinates. Missing positions/telemetry have explicit unavailable states.
- Tyre age and stint distance are separate; ambiguous restart/formation-lap boundaries are omitted. Pit durations appear only when supplied.
- Radio uses supplied F1-hosted recordings and existing system audio controls; never autoplay or fabricated transcripts.
- Active Aero channel 45 and unknown channels remain raw. No guessed Straight/Corner/Boost/Overtake or legacy DRS telemetry indicator.

## Verification

- 25 offline Swift Testing tests passed (including parameterized cases), latest run 3.172 seconds: real stationary/moving raw-DEFLATE samples, official Jolpica classifications, archived normalization, partial/nested/indexed merges, unknown values, 22 entries, Q1/Q2/Q3 isolation, tyre reuse, weather units, UTC fields, HTTP 404/429/503, clock validation, stale responses, switching/background/foreground, cache, replay and final classification.
- Native live smoke: negotiation, WebSocket, handshake and subscription succeeded anonymously; 20 snapshot topics returned. An intentional socket interruption recovered through reconnect and a fresh snapshot. The lightweight discovery subscription also returned all seven requested topics. No active CarData/Position stream was available during that check.
- Native archive smoke: Australian GP 2025, 20 drivers, 113 control messages, 20 radio items and 34 supplied pit-stop records.
- iPhone/iPad simulator: real constructor/calendar discovery, future sessions and navigation verified. iPhone archived Race Centre timing, strategy, control messages, driver detail and shared radio Play/Pause dispatch verified. Audible output cannot be verified by screenshot tools.
- iOS and tvOS builds passed during implementation. Later whole-app builds encounter unfinished NBA mapping types from concurrent work. Latest F1 source diagnostics are clean; latest visual fixes still need reinstall verification after the app builds again.
- Instruments was attempted twice, including an escalated attempt, but macOS denied creation of its InstrumentsCLI cache directory. No CPU/battery or SwiftUI profiler claim is made.

Run offline tests:

```sh
bash F1CoreTests/run-tests.sh
```

Optional real-network diagnostics (not unit tests):

```sh
bash F1CoreTests/run-tests.sh --live-smoke
bash F1CoreTests/run-tests.sh --archive-smoke
bash F1CoreTests/run-tests.sh --snapshot-smoke
```

Debug builds expose Record timing / Stop recording in Race Centre. JSONL recordings are bounded at 64 MB in Documents and include initial snapshots. Launch with `F1_REPLAY_FILE` set to a recording’s local path to explicitly replay it through the normal state pipeline. Production never automatically selects fixtures.

## Remaining verification / undocumented data

Active Aero numeric semantics remain intentionally unmapped. Optional position, telemetry, radio and pit-duration availability depends on the session/feed. Observed trails are not a guaranteed complete circuit outline. Full active-session telemetry/position behavior, tvOS focus, final UI-fix retest and Instruments performance acceptance remain outstanding. Anonymous access worked during verification but can change upstream.

Protocol/schema references reviewed: [FastF1 client](https://github.com/theOehrly/Fast-F1/blob/master/fastf1/livetiming/client.py), [julesr0y reference](https://github.com/julesr0y/f1-livetiming-api), [harsh779 client](https://github.com/harsh779/f1-live-api), [topic schema reference](https://github.com/matteocelani/f1-telemetry/blob/main/docs/live-timing-types.md).
