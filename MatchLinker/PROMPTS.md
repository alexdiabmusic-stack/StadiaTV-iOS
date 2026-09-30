# StadiaTV: every fix, in run order

For the coding agent that is already working in the StadiaTV project. This file replaces the earlier chat lists and the separate linker prompts. It holds what was measured, what was decided, and nine prompts. Do the prompts in order. Each one is self-contained and ends with a "Done when" check.

Read "How to work" and "What was measured" once. After that, take one prompt at a time.

## How to work

1. **Branch and commits.** One branch per prompt. One commit per numbered step, with a message that says what changed and what number moved. Never rewrite history, never force-push.
2. **Check before you build.** If a step is already done in the repo, verify it in a few minutes, say so in the commit or PR text, and move on. Some of the earlier plan was implemented already.
3. **Measure with Release.** Debug builds hide the real cost by roughly 10x. Numbers that swing more than 15% between two runs on the same machine are noise, so repeat them. Prompt 1 builds the tool for this.
4. **Never open a live stream in a test.** The sample account allows one connection. Anything that needs the network uses a stubbed `URLProtocol`. Do not add tests, probes or benchmarks that play or fetch a stream.
5. **No secrets in the repo.** Do not commit credentials or exported playlist data. `MatchLinker/Scripts/export_playlist.sh` reads `HOST`, `XT_USER` and `XT_PASS` from environment variables. If you need test data and the user has not provided an export folder, ask for one.
6. **Concurrency.** The app target defaults to MainActor isolation (Swift 5 mode, approachable concurrency). Work that must leave the main thread goes in `nonisolated` types or actors. Do not name a top-level type like a SwiftUI or app type. An internal `Text` enum shadows SwiftUI's `Text` and breaks the build.
7. **Do not spend time on these.** They were measured and are not the problem: date parsing (about 1 microsecond per call), `ChannelNormalizer` (13 to 20 microseconds), channel search (about 5 microseconds), the row-layout cache.
8. **Keep the tests green.** Run the whole test target before every commit that touches shared code.
9. **Line numbers drift.** The file and line references below come from the copy of the project I analysed on 28 September. Search by symbol name if they no longer match.
10. **Report after each prompt.** Say which branch, which commits, which tests you ran, and the new row in `docs/benchmarks/`. If a "Done when" check fails, say which one and why, and do not move on to the next prompt.

Where the linker lives: `MatchLinker/` in the repo root. If it is not there yet, copy it from `/Users/alexdiab/Downloads/StadiaTV-iOS-main-2/MatchLinker`. Its README has the rules and the public API.

## What was measured

All numbers come from one real Xtream playlist, measured 26 to 30 September 2026. Treat them as the shape of the problem. Prompt 1 gives you your own numbers.

### The provider

| Fact | Value |
|---|---|
| Streams | 22,304 (`get_live_streams` is 6.9 MB) |
| One category | `get_live_streams&category_id=N` is about 16 KB and 0.35 s |
| Guide | `xmltv.php` is about 22 MB gzipped, 101 to 127 MB of XML depending on the day |
| Guide contents | 9,557 `<channel>` entries, 2,612 of them with an empty id. 350k to 390k programmes. Offsets like `+0200`. No `<category>` tags. |
| Guide horizon | It varies. For most channels the last programme ends 12 to 36 hours ahead. About 250 channels reach 60 to 84 hours. An earlier fetch had 7 days. Never assume 7 days. |
| Shared guide ids | About 1,800 guide ids are used by several streams (mirrors and regional copies of one channel) |
| Event channels | About 1,600 (ESPN+, DAZN, Flo, pay-per-view, league slots). No guide data. The game is in the channel name: `US ★ MLB 01: TORONTO BLUE JAYS @ BALTIMORE ORIOLES 7:35 PM ET`. Names change during the day. Unassigned slots look like `US ★ MLS 01: `. |
| Title formats | `NHL Hockey : Florida Panthers at Carolina Hurricanes ᴸᶦᵛᵉ` (superscript badges `ᴸᶦᵛᵉ` and `ᴺᵉʷ`), `Spagna - Croazia`, `Carolina Hurricanes v Florida Panthers`. Placeholders: `No Game Today`, `Next Game: A @ B on 2026-09-30 at 10:00PM EDT`. |
| Corrupted names | The panel injects `US ★` inside words: `MUS ★kingum` is `Muskingum` |
| Per-channel guide | `get_simple_data_table` returns a multi-day schedule for one channel in 38 to 74 KB (0.5 to 1 s), base64 titles, read `start_timestamp`. `get_short_epg` returns now and next. |
| Account | `max_connections` is 1. The app never reads it. Server timezone is Europe/Paris. |

### The app before these fixes

| Measurement | Value |
|---|---|
| Streams matching the 581-channel curated list | 390 of 22,304. So 20,886 are "unresolved". |
| After the first guide import | 237 of 9,557 guide channels mapped. 12,952 of 151,671 programmes kept. 214 of the 4,302 streams that should have guide data (5%) had it. After a second refresh: 2,874 (67%). |
| Retention | Programmes are kept for about 36 hours ahead. 20 of 31 test games start later than that, and 8 of them had listings the app discarded. |
| Match check | `SourceMatcher.confirms` joins title and description and demands exactly two fixture segments. Of 37 real listings naming both teams it rejected 12. A title-first check went from 25 to 36 confirmations with none lost. |
| Games with a confirmed stream (31 real games) | 3 after the first import, 7 after the second |
| Junk candidates | 16 of 77 "possible" candidates were wrong: `CAR` matched "CAR CHASE", `VAN` matched "The Dick Van Dyke Show", "Queens Park Rangers" for the NY Rangers |
| Scan cost | 17 to 24 ms per match on the main thread (about 0.6 s for 31 games) once the guide is loaded correctly. `teamNameBackups` about 0.3 s and `rank()` 0.8 to 2.1 s per match over 22k channels. |
| Persistence | Every EPG.pw batch re-sorts the whole index and re-saves 73 MB of JSON. Encode 0.85 to 1.35 s, decode 0.76 to 1.1 s at launch. Each batch bumps `lastUpdated`, which re-triggers the scans. |
| Startup | `EPGRepository.init` costs 139 to 444 ms on the main thread |
| Grid | About 22 cells per row are built for a whole day, roughly 700 views for the rows rendered, against about 30 visible |
| Guide import stages (Release, clean run) | prefilter 0.65 to 1.0 s, canonical match 3.4 to 6.6 s, parse 2.9 to 4.9 s |

### The linker (Prompt 2)

Run on the same provider, with real games:

| Set | Result |
|---|---|
| Next 48 hours, 53 games | 36 with a confident stream, 13 with three or more broadcasters. The 16 with nothing have no listing in the provider's guide. |
| Same window, the 21 games in leagues the app shows | 19 confident |
| Previous three days, 208 games | 129 confident. Of the 79 without one, none has a guide listing that names both teams. |
| Speed (Release, Mac) | index build about 0.22 s for 22k channels and 115k programmes, about 0.26 ms per game |

## Run order

| # | Prompt | What it fixes |
|---|---|---|
| 1 | Benchmark first | Reproducible numbers for everything below |
| 2 | Link matches to streams with StreamLinker | Matches not found, junk candidates, main-thread scans, event-channel names |
| 3 | One guide from the playlist, stored properly | 95% of the guide thrown away, third-party downloads, 73 MB JSON, main-thread import |
| 4 | The TV guide grid | Lag in the Live tab |
| 5 | Keep event channels current | Stale channel names |
| 6 | Respect the connection limit | Probes that kick the viewer or mark healthy mirrors dead |
| 7 | League list and per-playlist visibility | A dead league, leagues the playlist does not carry |
| 8 | Tests, budgets and signposts | Regressions |
| 9 | Leftovers from the first plan | Radii, weights, images, stray files |

## Prompt 1: Benchmark first

Goal: one command that prints the same numbers every time for import, guide coverage, matching and main-thread stalls, so every later prompt can show what it changed.

Why: my timings swung about 10x when the Mac was short of memory. Only counts and clean Release runs can be trusted.

1. Add a DEBUG-only launch argument `-guideBenchmark <dir>`. Handle it at the very start of the `@main` app (`ContentView.swift`), before any UI exists. Run `GuideBenchmark.run(dir:)`, print the report, call `exit(0)`. Keep all of it inside `#if DEBUG`.
2. `<dir>` holds `streams.json` (`get_live_streams`), `cats.json` (`get_live_categories`), `xmltv.xml` (the provider's guide) and `events.json` (games, same shape as `MatchLinker/Fixtures/events_next48h.json`). Ask the user to produce them with `MatchLinker/Scripts/export_playlist.sh` and `MatchLinker/Scripts/export_events.py` if they do not exist.
3. Drive the app's real code, headless:
   - Build channels through `XtreamProviderAdapter`, using a `URLSession` whose configuration installs a stub `URLProtocol` that answers the two Xtream calls from the JSON files. Use stub credentials so the Keychain is never touched.
   - Convert with `LiveChannel.make(from:providerID:kind:)` and `asChannel(playlistName:)`, exactly as the app does.
   - Call `EPGRepository.setupWithChannels(channels, customEPGURLs: [<dir>/xmltv.xml])`. Wait for the import to finish. Add an explicit completion signal for this if you need one: `importProgress.state` did not reliably return to `.ready` in my harness. Prompt 3 makes every import path end in `.ready`.
   - Decode `events.json` into `Match` values and run the real `StreamAvailabilityStore.scan(matches:channels:epgRepository:)`.
4. Print one metric per line, in a fixed order:
   - time for: adapter load, channel build, canonical lineup, guide parse, mapping, save, scan
   - memory (`task_vm_info.phys_footprint`) after each stage, and the peak
   - main-thread stalls of 100 ms or more: run a background thread that posts to the main queue every 20 ms and logs the delay together with the current stage name
   - coverage: streams with a guide id, streams that received programmes, guide channels mapped out of total, programmes kept out of parsed
   - games: how many have at least one guide-confirmed stream, and how many have any candidate
5. Also write the same numbers to `<dir>/benchmark.json`.
6. Add `scripts/benchmark.sh <dir>`. It builds Release for the simulator (or macOS if the project has such a target) and launches the app with `-guideBenchmark <dir>`. Refuse to run Debug.
7. Run it now, before any other change, and commit the numbers (never the data) as `docs/benchmarks/00-baseline.md`.

Done when: the script works from a clean checkout, two runs agree within 15% on times and exactly on counts, and the baseline is committed. From now on every prompt adds a row to `docs/benchmarks/`.

## Prompt 2: Link matches to streams with StreamLinker

Goal: every match shows all the streams in the user's playlist that carry it, ranked, with mirrors as alternates. This replaces the old matcher. It covers the earlier items "rewrite `confirms`", "match-linking engine" and "parse event-channel names".

Why:

- `SourceMatcher.confirms` rejects real listings (see the table above), the fallback candidates are junk, and the matching work is triggered from six places, with the first phase on the main thread.
- The five causes of missed games in the shipped code: the channel-to-guide map is built before `unresolvedStreams` is assigned (`EPGRepository.swift` around lines 225 and 226), `matchCustomEPGChannels` keeps only the last stream per guide id, `confirms` joins title and description, 36-hour retention, and event channels that carry the game only in their name.
- `MatchLinker/Sources/BannerTV/StreamLinker.swift` reads the provider's own guide and channel names. It is Foundation only, every declaration is `nonisolated`, it has 12 golden tests, and a Python reference gives identical results on 261 games. Its tiers: T1 the guide title names both teams (0.97 with a Live badge, 0.92 without), T2 the description names both (0.72), T3 team channel (0.62 or 0.5), T4 event channel whose name carries the fixture and a kickoff time that agrees (0.85), T5 likely, the sports API names the network (0.6), T6 coverage show (0.35). Confidence 0.7 or higher is a real option.

Steps:

1. Make sure `MatchLinker/` is in the repo root. Add `Sources/BannerTV/StreamLinker.swift` to the app target unchanged, under `MyApp/Matching/`. Do not remove the `nonisolated` keywords. Do not add `@MainActor`. Do not rename the `Linker*` helper types: the prefix keeps them from shadowing SwiftUI.
2. Add `MyApp/Matching/StreamLinkerAdapters.swift` with `nonisolated` conversions:
   - `Match` to `LinkerEvent`: `id = match.id`, `league = match.league.path`, `kickoff = match.date`, `broadcasts = match.broadcasts`, `isNational = false` for the current leagues (true for national-team competitions when they are added).
   - `TeamSide` to `LinkerTeam`: `name = displayName`, `abbr = abbreviation`. Pass `short` and `nick` only when they are real nicknames ("Panthers", "Red Sox"), never abbreviations. If a provider exposes a nickname or city (NHL `commonName` and `placeName`, MLB `teamName` and `locationName`), carry them through. The linker never matches on abbreviations or bare place words. That is deliberate: it is what removes the junk candidates.
   - `Channel` to `LinkerStream`: `id`, `name`, `category` = the group or category title, `guideID` = the Xtream `epg_channel_id` or the M3U `tvg-id`. It must be the raw id that appears in the XMLTV file, not a canonical id.
   - programme to `LinkerProgramme`: `guideID` = the raw XMLTV `channel` attribute, `start`, `end`, `title`, and `desc` cut to its first 300 characters.
3. Capture the linker's guide input in the import, before programmes are re-keyed to canonical ids or dropped for having no canonical channel. Hand the raw parsed programmes for now minus 6 hours to now plus 72 hours to the service in step 4. The parser's own retention window (`programmeWindow`, about now minus 14 hours to now plus 36 hours) is what discarded listings for later games. Widen it for this feed only. Do not use `programmeIndex` or `programmesNear` for this.
4. Add `actor MatchLinkService` in `MyApp/Matching/MatchLinkService.swift`:
   - `rebuild(channels:programmes:)` builds a `StreamLinker` off the main actor and bumps a revision. Coalesce repeated calls. The build takes about a third of a second.
   - `options(for match:) -> [LinkedFamily]` calls `link`, then `groupedByFamily()`. Cache by match id and revision.
   - `prewarm(matches:)` links every match in the next 48 hours in one background task after each rebuild.
   - An `@Observable` read model on the main actor exposes only what the views draw: per match id, the number of confident families and the ordered options, plus the revision.
5. Replace every trigger of the old matching. `StreamAvailabilityStore.scanDebounced` is called from `HomeView.swift` (around line 107), `MatchesView.swift` (69), `ContentView.swift` (163) and `TV/TVRootView.swift` (54). The two detail screens call `rankSources()`, which runs `SourceMatcher.rank`, from `.task(id:)` keys that include `lastUpdated` (`MatchDetailView.swift` around line 213, `TV/TVMatchDetailView.swift` around line 89) and listen to `streamStore.sourcesByMatchId` with `.onChange`. Delete every `.task(id:)` key that includes `epgRepository.lastUpdated`. Views observe `MatchLinkService.revision` and read `options(for:)` instead. No guide data may be read on the main actor.
6. UI:
   - Match row: "N streams" from confident families only. A muted "Likely" label when only T3 or T5 options exist. Nothing when there are none. If the match starts after every sports channel's guide ends, say "Listings appear closer to kickoff" instead of "no streams".
   - Match detail: a "Where to watch" list, one row per `LinkedFamily`: display name, region and language chip, quality of the best mirror, and a tier label (T1 "Guide lists this game", T2 "Guide description names this game", T3 "Team channel", T4 "Event channel", T5 "Likely, broadcast partner", T6 "Coverage show"). Confident rows first, then a collapsed "More options". Tapping a row plays `streamIDs[0]` and passes the rest as alternates, best quality first.
7. Repair the provider's in-word corruption in the channel adapter, before names reach the linker: `(?<=\p{L})(US|CA|UK) ★(?=\p{L})` becomes the lower-case two letters, so `MUS ★kingum` becomes `Muskingum`. Add a test for it.
8. Delete the old matcher: `SourceMatcher.confirms`, `rank`, `teamNameBackups`, the "possible candidates" fallback and the old event-name parsing. Port any case in `PrecisionStreamMatcherTests` that still makes sense into adapter-level tests. Remove the rest with the code, in the commit that removes the last caller.
9. Tests: add `StreamLinkerTests.swift` (uses `@testable import BannerTV`, like the existing tests) and make all 12 pass. Add adapter tests, including nickname handling and the corruption repair.

Done when:

- All tests pass, including the 12 golden tests.
- Time Profiler shows no guide scan on the main thread while the Matches tab opens.
- On the same export, the number of games with a confident option in the app's benchmark (Prompt 1) is within 2 of what `swift run -c release linker-cli` reports from `MatchLinker`. A bigger gap means an adapter is losing data.
- `link` takes under 5 ms per match and the index build under 1.5 s in a Release run.
- No abbreviation-only or nickname-only candidates remain (check `CAR`, `VAN` and the NY Rangers cases).

## Prompt 3: One guide from the playlist, stored properly

Goal: the playlist's own guide is the only default source, loaded once, stored in SQLite, imported off the main thread. This covers the earlier items "index the guide by guide id", "store the guide in SQLite" and "move the import off the main thread".

Why: the numbers in "The app before these fixes". In short, about 95% of the provider's guide is thrown away, three third-party sources add up to about 69 MB more per refresh (epgshare01 `US_LOCALS1` 56.1 MB, `US2` 6.5 MB, `CA2` 6.4 MB, `US_SPORTS1` 0.2 MB, plus EPG.pw per-channel data), and the provider's own guide already covers 236 of the 266 curated channels. The 30 it lacks are not sports channels. Stored as one 73 MB JSON file, it costs seconds at launch and after every batch.

Steps:

1. **Source.** Make the playlist's guide the only default: Xtream `xmltv.php`, or the M3U `url-tvg` and `x-tvg-url`. `EPGPWSourcePolicy` (`EPGPWProvider.swift`) is currently all `true`. Put EPG.pw and epgshare01 behind a debug-only setting that defaults to off, and keep the code compiling. Keep support for a user-supplied XMLTV URL (`customEPGURLs`): it goes through the same ingest. For a channel row with no programmes, request `get_short_epg` for that one channel on demand (Prompt 4), never in bulk.
2. **Download and parse.** Stream the file to disk with a URLSession download task (gzip), using ETag or If-Modified-Since so an unchanged guide costs nothing. Parse as a stream on a background task, in constant memory. Parse offsets like `+0200` properly and store UTC epoch seconds. Keep programmes that end after now minus 6 hours and start before now plus 72 hours, and only for guide ids (lower-cased) that at least one playlist channel uses. Skip empty ids. Never build the full 7-day array. Parse the timestamps arithmetically instead of building `DateComponents` with a `Calendar` for every programme (`EPGXMLParser.parseDate`, around line 205): turn year, month and day into days since 1970 with the civil-from-days algorithm, add the time of day, subtract the offset. In my measurement this took about 30% off the parse stage. It is a small win, not the main cost.
3. **Map by guide id.** A programme belongs to a channel through its own guide id (`epg_channel_id` or `tvg-id`, lower-cased), not through a canonical-name join. Map every stream that shares a guide id, unresolved streams included. Remove the `matchCustomEPGChannels` last-one-wins map (`EPGRepository.swift` around line 679) and the `scopedProviderChannelId` workaround (`EPGModels.swift` line 162, used in `EPGRepository.swift` around line 511 and `StreamAvailabilityStore.swift` around line 147). Fix the ordering bug: `rebuildChannelToCanonicalMap()` runs at line 225 before `unresolvedStreams` is assigned at line 226. Keep `ChannelNormalizer` and the curated 581-channel list for display names and lineup only. A canonical channel with several provider streams reads programmes from the first stream whose guide id has rows.
4. **Store.** Replace `programmeIndex`, `saveProgrammeIndex`, `loadProgrammeIndex`, `finalizeProgrammeIndex` and every `programmesNear` full scan with one `GuideStore`: an SQLite file with a channel table and a programme table indexed by (channel, start). API: `programmes(channel:from:to:)`, `nowAndNext(channel:)`, and a `Sendable` snapshot of raw programmes for `MatchLinkService`. Reads are per channel and per time window. Run it in an actor or behind a serial queue. Never read it on the main actor.
5. **Import off the main thread.** Run the whole import in an importer actor. Publish one revision at the end and remove the storm of `objectWillChange.send()` calls (`EPGRepository.swift` around lines 430, 523, 600 and 1027). Make `EPGRepository.init` trivial: it costs 139 to 444 ms on the main thread now. `importProgress.state` must reach `.ready` on every path, including the custom-guide-URL path.
6. **Refresh.** At launch if the stored guide is older than 6 hours, and every 6 hours while the app is active. Never block the UI.
7. **Delete** EPG.pw batching, the JSON persistence, every cache file the new store replaces (also remove the old files from disk on the first launch of the new version), and the third-party download code paths that are now off by default.
8. Add a row to `docs/benchmarks/` with the new numbers.

Tests: a fixture XMLTV with a `+0200` offset, an empty channel id, two streams sharing one guide id, HTML entities in a title, and programmes outside the window; a `GuideStore` round trip; the ordering bug (a stream that is only "unresolved" still gets programmes); an unchanged guide (ETag hit) does no work.

Done when:

- At least 98% of streams that have guide data receive programmes (baseline 5% after the first import, 67% after the second).
- The first launch downloads one guide file of about 22 MB and nothing else for guide data.
- Peak memory in the benchmark is below the old 366 MB, with no main-thread stall of 100 ms or more during import.
- No 73 MB JSON is written. The benchmark's parse stage is no slower than the old 2.9 to 4.9 s.
- `MatchLinkService` receives its programmes from `GuideStore`.

## Prompt 4: The TV guide grid

Goal: the Live tab guide scrolls without hitches. This covers the earlier items "measure the guide first, then rebuild the grid" and "fill guide rows lazily".

Why: `ProgrammeGridView` (`TVGuideView.swift` around line 448) builds a whole day of cells for every row, about 22 cells per row and roughly 700 views for the rows rendered, against about 30 visible. Each cell is a `Button`. The grid observes the whole repository and the fantasy stores, so unrelated changes redraw it.

Steps:

1. Measure first. Add an `XCTHitchMetric` scroll test for the guide (scroll the channel list and the time axis on a fixed fixture) and commit its baseline.
2. Render only the cells inside the visible time range for the visible rows. Use one hit-test or gesture layer instead of a `Button` per cell.
3. Precompute time strings and cell layouts outside `body`. Update only the "now" line once a minute, not the grid.
4. Stop the grid observing the whole repository and the fantasy stores. Give it a narrow view model that publishes only what it draws (rows in view, their programmes, the current time).
5. Fill rows lazily from the provider. For a visible row with no programmes in `GuideStore`, call `get_simple_data_table` (a full multi-day schedule for one channel, 38 to 74 KB, 0.5 to 1 s; titles are base64; read `start_timestamp`, not the `start` string). Use `get_short_epg` for now and next. Store results in `GuideStore` with a 6-hour lifetime. At most two requests at a time. These are API calls, not stream connections.
6. The 30 curated channels the playlist guide lacks are not sports channels. They fill in through step 5.

Done when: the hitch metric improves by at least half against its baseline, with a hitch time ratio under 5 ms per second on the simulator scroll test; the number of views built for the guide is within about 2x of what is visible; changing an unrelated store does not redraw the guide.

## Prompt 5: Keep event channels current

Goal: channels named after the game (`US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET`) change name during the day. A list downloaded at launch goes stale and matches lose their stream. Keep those channels fresh without re-downloading the whole list.

1. Once per playlist, find the event categories: names containing MLB, NHL, NBA, NFL, MLS, UFC, PPV, DAZN, ESPN+, EVENT or LIVE EVENT (case-insensitive), and categories where at least 30% of the channel names contain " vs ", " @ " or a clock time such as "2:00 PM ET".
2. Poll only those categories with `get_live_streams&category_id=<id>` (about 16 KB and 0.35 s each). Every 10 minutes while the Matches or Home tab is visible, and every 60 seconds from 30 minutes before to 30 minutes after a kickoff that has no confident option yet. Diff by `stream_id`.
3. When a name changes, update the channel in place, rebuild the `MatchLinkService` input, and re-link only matches within 12 hours of now.
4. Keep a `firstSeen` date per (`stream_id`, name). A channel that just changed name shows a "New" tag for an hour. Never link a stale name from another day: the linker checks the kickoff time stated in the name, so keep passing current names and do not cache old ones.
5. Do the full `get_live_streams` refresh at most once per launch. It is 6.9 MB.

Done when: renaming an event channel on the provider changes the matching result within 10 minutes without a full refresh, verified with a stubbed `URLProtocol` test.

## Prompt 6: Respect the connection limit

Goal: the account's connection limit is respected. The sample account allows 1 (`player_api.php`, `user_info.max_connections`). A second connection kicks the stream the user is watching.

Why: `preflightAlternates()` (`StreamSelection.swift` around line 403, called from `PlayerView.swift` around line 882) probes two alternate streams while the main one starts. The app never reads the limit, and a rejected probe (HTTP 400 or higher) marks healthy mirrors dead for 90 seconds. This came from the first plan; it needs this fix.

1. After login and on every refresh, read `user_info` (`max_connections`, `active_cons`, `status`, `exp_date`) and `server_info`. Store them on the provider model and refresh them when the app becomes active.
2. Skip probes when `max_connections` is 1 or unknown, or when `active_cons` has reached the limit. Then rely on the player's own failover. Never probe while something is playing.
3. Treat 401, 403, 429 and every 5xx as inconclusive: they must never mark a mirror dead.
4. Multiscreen and recording need `max_connections` at least equal to the number of simultaneous streams. Otherwise show a clear message and do not start the second stream.
5. Settings, Account shows connections in use and allowed, status and expiry. The player shows a short banner if the server reports that the maximum is reached.

Done when: with `max_connections` set to 1, a stubbed `URLProtocol` that counts requests to the stream host sees exactly one connection during a normal start, a failover and a channel change.

## Prompt 7: League list and per-playlist visibility

Goal: no dead leagues, and no league that the user's playlist does not carry cluttering the app.

Why:

- `League.all` (`Models.swift` line 81) has 12 leagues, and `SportsRepository` has 11 providers (NHL, MLB, F1, NFL, CFL, NBA, WNBA, EPL, MLS, LaLiga, PGA). **Liga MX (`soccer/mex.1`) has no provider**, so `legacyScoreboard(for:)` throws `noProviderAvailable` and its games can never load. It is still referenced in `PlayerView.swift` (around lines 1210 and 3695), `TV/TVPlayerView.swift` (335), `BroadcastRightsPolicy.swift` (349), `SportsCatalogRepository.swift` (170) and `LeagueLogoRepository.swift` (125).
- CFL has its own official-API client and this playlist lists CFL games live on TSN 1 to 5. Keep it. The app's featured-events code weights Canadian relevance, which fits.
- Evidence on this playlist (Sep 26 to 29 backtest, games with a confident stream): MLB 27 of 28, NFL 15 of 15, NHL 8 of 14 (preseason, the rest on local channels), WNBA 3 of 4, Liga MX 7 of 7, MLS 0 of 14. MLS has only one club channel with guide data, and 34 event channels (`US ★ MLS 01:` and so on) that are blank between match days, so MLS is unproven, not absent. NBA (preseason starts Oct 3), EPL and La Liga (international break) could not be tested. F1 and PGA are not two-team fixtures, so the linker does not judge them.
- Competitions the playlist covers poorly, so do not add them: small-nation friendlies (6 of 17), Copa del Rey early rounds (0 of 10), Uruguay (0 of 8), Brazil Série B (0 of 7), Colombia (1 of 6). Well covered and worth adding if wanted: UEFA Nations League (25 of 26, needs `isNational = true`), NWSL (5 of 5).

Steps:

1. Remove Liga MX from `League.all` and clean its references, unless you add a `LigaMXProvider` in the same change. Add a unit test that every `League.all` entry has a provider in `SportsRepository`, so this cannot regress.
2. Fix the stale comment in `HomeView.swift` (around line 1985) that names CFL as a league with no provider.
3. Add per-playlist visibility from linker results. After each rebuild, `MatchLinkService` keeps, per league, the matches of the last 14 days and how many had a confident option. If a league has 10 or more matches and none with a confident option, show its matches under a collapsed "Not on your playlist" section instead of the main lists. Never hide a league the user follows. A league with fewer than 10 matches stays visible.
4. Show the empty state clearly: a match with no options says why ("No listing in your playlist's guide", or "Listings appear closer to kickoff").

Done when: the provider test passes, Liga MX is gone from every list, and a playlist export without MLS listings collapses MLS while one with them does not.

## Prompt 8: Tests, budgets and signposts

Goal: the match rate and the speed do not regress.

1. **Budgets.** A Release-only test builds `StreamLinker` over a synthetic playlist of 22,000 channels and 115,000 programmes and asserts a build under 1.5 s and a median link under 5 ms. Measured on a Mac: about 0.25 s and 0.3 ms.
2. **Integration test.** When the environment variable `LINKER_FIXTURE_DIR` is set, load `streams.json`, `cats.json` and `guide_window.json` from that folder, link the events in `MatchLinker/Fixtures/events_next48h.json`, and assert that nothing throws, every option has at least one stream id, and the median link time is under 5 ms. Skip the test when the variable is not set.
3. **Signposts.** Add `os_signpost` intervals around guide download, parse, store write, linker build, link, and the time from opening the Matches tab to the first drawn option. One subsystem, so Instruments shows them together.
4. **Fixture refresh.** `MatchLinker/Scripts/` has the exporters. Add their output folder to `.gitignore`. Never commit credentials or exported playlist data.
5. Add the benchmark rows to `docs/benchmarks/` after each prompt if you have not already.

Done when: the budgets pass in CI or locally in Release, and the signposts show up in Instruments.

## Prompt 9: Leftovers from the first plan

Goal: finish what the first plan started. The audit found the false-failure bug fixed, `PlaybackController` in, and no unique build warnings. What is left:

1. **Hard-coded corner radii.** 572 `cornerRadius` literals. Replace them with `Theme.Radius` (`Theme.swift` line 43: sm 8, md 12, lg 16, xl 24), mapping each to the nearest token. Leave capsules, circles and one-off shapes alone.
2. **Heavy and black weights.** About 200 uses of `.heavy` and `.black` (207 in my audit; grep for both). `Theme.Typography` says weights are semibold or bold only. Use the `Theme.Typography` styles or semibold and bold.
3. **`AsyncImage`.** 11 uses. Replace them with the cached, downsampled image view from the first plan.
4. **Stray files.** `Untitled Project.xcodeproj` and `scripts/legacy-patches` (six one-off patch scripts). Search the repo for references, then delete them in a commit of their own.

Done when: `git grep` finds no `AsyncImage`, no `.heavy` or `.black` weights and no hard-coded corner radius outside `Theme`, and the two stray items are gone.

## Where the earlier lists went

| Earlier item | Now |
|---|---|
| Round 2: 1 benchmark | Prompt 1 |
| 2 index the guide by guide id | Prompt 3 |
| 3 rewrite `confirms` | Prompt 2 |
| 4 SQLite store | Prompt 3 |
| 5 import off the main thread | Prompt 3 |
| 6 match-linking engine | Prompt 2 |
| 7 event-channel names | Prompt 2 (T4, corruption repair), Prompt 5 (freshness) |
| 8 grid | Prompt 4 |
| 9 lazy rows | Prompt 4 |
| 10 connection limit | Prompt 6 |
| 11 first-plan leftovers | Prompt 9 |
| Linker prompts A to E | A: Prompt 2, B: Prompt 3, C: Prompt 5, D: Prompt 6, E: Prompt 8 |

## The MatchLinker folder

| Path | What it is |
|---|---|
| `README.md` | Rules, tiers, public API, how to run |
| `Sources/BannerTV/StreamLinker.swift` | The linker (Foundation only, every type `nonisolated`) |
| `Tests/BannerTVTests/StreamLinkerTests.swift` | 12 golden tests from real titles |
| `Sources/linker-cli/main.swift` | Runs the linker on an exported playlist and guide |
| `Reference/` | The same rules in Python, and a strict comparer |
| `Scripts/` | `export_playlist.sh`, `export_guide_window.py`, `export_events.py` |
| `Fixtures/` | The 53 games and what the linker returned for each |
