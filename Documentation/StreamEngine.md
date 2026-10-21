# Banner Stream Engine

The stream engine sits between IPTV providers and AVPlayer. It holds the provider connection itself, keeps a reserve of programme ahead of what is on screen, and when a connection breaks it reconnects in the background and splices the new connection onto the old one, so the viewer keeps watching the reserve instead of a spinner. It follows the Neverlag design: a resilient pre-decoder engine with a single recovery referee, and the platform decoder (AVPlayer) behind a thin local adapter.

**What has and hasn't been verified.** The engine and its tests were built and run with the Swift 6.2 toolchain on Linux: 73 unit and end-to-end tests, plus chaos runs against a fake provider that cuts, stalls, throttles and refuses. The app's own target was type-checked with the real `PlaybackController` against stubbed AVFoundation/Combine. No Xcode build, simulator or device run was possible in this environment, so nothing here proves how AVPlayer itself behaves with the local stream (see [Not verified](#not-verified-and-limitations)).

## Why playback used to break

`PlaybackController` handed provider URLs straight to AVPlayer (rewriting Xtream `.ts` URLs to `.m3u8`, because AVPlayer can't play raw MPEG-TS). Every provider hiccup therefore reached the decoder directly:

- AVPlayer's own buffer is small and only fills at the provider's pace, so ordinary 3–10 s server pauses drained it and froze the picture.
- A stall longer than 6 s rebuilt the player item: the buffer was thrown away and the stream restarted from scratch, with startup latency, a black frame and often a jump in programme. Four rebuilds and the channel failed.
- Several mechanisms (AVPlayer's waiting logic, the stall timer, the start-up watchdog, failover) reacted to the same hiccup independently.

## How the engine works

```
provider ──► acquisition ──► packet aligner ──► splicer ──► segmenter ──► reserve ──► loopback HTTP ──► AVPlayer
            (TS or HLS)     (188-byte sync)   (one timeline)  (2 s HLS)   (held/published)  (127.0.0.1)
                 ▲                                                            │
                 │         health monitor ──► recovery referee ◄── playback position, starvation
                 └──────────── connect / switch route / wait / give up        │
                                           pace controller ──► playback rate (pitch-corrected)
```

1. **Hold the connection.** A raw MPEG-TS route is one long HTTP response kept open for as long as the provider sends it; IPTV panels burst several seconds of buffered programme on connect, which becomes instant reserve. HLS routes are followed playlist by playlist, joining deep in the window for the same reason.
2. **Keep a reserve.** Everything received is cut into 2 s keyframe-aligned HLS segments (1 s for the first two, so the first picture appears quickly). Only a short lead (5–6 s) is published to AVPlayer; the rest stays in the engine, so a stalled provider doesn't stall the decoder.
3. **Detect at the network boundary.** Delivery is measured in programme seconds per wall-clock second, long before AVPlayer would notice anything. A silent connection is replaced after 4–12 s, depending on how much reserve is left.
4. **Reconnect in the background.** The viewer keeps watching the reserve while the referee reconnects: immediately the first time, then with a short backoff.
5. **Splice.** The new connection is joined onto the old one at a picture the decoder can start from:
   - re-sent programme (the provider's burst) is recognised by keyframe fingerprint and skipped, so no picture plays twice;
   - a restarted encoder's new clock, a forward gap after an outage, or a clock jump within a connection is re-timed so the output timeline stays continuous (PTS, DTS and PCR move together, so audio stays in sync);
   - PIDs are remapped onto the output program and continuity counters stay continuous;
   - only a codec change or a join at an open-GOP picture is announced to AVPlayer as a discontinuity;
   - a picture torn by a dying socket is dropped, never glued to the next connection.
6. **One referee.** `RecoveryReferee` is the only code that decides what happens next, and only one remedy is in flight at a time. Every decision is written to the diagnostics journal.
7. **Adapt on a slow line.** A line that can't deliver real time is played slightly slower (pitch-corrected, down to the profile's floor) instead of freezing; a healthy line plays a hair below 1.0x until the reserve reaches its target and a hair above when it has grown well past it.

AVPlayer only ever sees a well-formed local live playlist (`http://127.0.0.1:<port>/<token>/<session>/live.m3u8`) whose segments each start with PAT/PMT and a keyframe. The path carries an unguessable token; no provider URL, credential or header is exposed through it.

### Routes

`StreamEnginePlanner` decides what the engine carries:

| Stream URL | Routes |
| --- | --- |
| Xtream live: `/{user}/{pass}/{id}`, `/live/{user}/{pass}/{id}.ts` or `.m3u8` | raw MPEG-TS first, the panel's HLS output as backup |
| other live `.m3u8` | HLS |
| other live HTTP(S) | MPEG-TS (a playlist served there is detected and followed as HLS) |
| movies, series, catch-up/timeshift/archive, DASH, finite files, non-HTTP | not carried: AVPlayer plays the URL directly |

The engine also hands a stream to AVPlayer when it can't ingest it: encrypted, fMP4/CMAF, byte-range or audio-only renditions and real bitrate ladders.

### Recovery rules

| Situation | What the referee does |
| --- | --- |
| Connection closed or failed | Reconnect at once, then 0.5, 1, 2, 3, 4, 5 s; 10 s of steady delivery forgives earlier failures. |
| No programme for a minute | Probes step out to 15, 30, then 60 s; the viewer sees "Provider not responding · retrying in N s". |
| Connected but silent | Replaced after `reserve − 6 s`, clamped to 4–12 s (HLS: never sooner than 2 × target duration + 2 s). |
| No programme at start-up | Next route after 6 s when a backup route exists, else 10 s; gives up after two tries per route *and* 10 s, then AVPlayer tries the URL directly. |
| Route answers 404/403 or unplayable content before ever playing | That route is dead for this session; the other route is used and never switched back to while it works. |
| 404 on every route before playing | "This channel is no longer available from your provider." |
| 403 after playing | One-stream accounts yield after two refusals, others after three ("account is being used on another device"). |
| Three connections cut 2–12 s in, with no 30 s of steady play between, on a one-stream account | Another device holds the line: stop competing for it. |
| Picture frozen with the provider silent | Shown "Waiting for the provider…"; after the profile's grace period (15/25/40 s) the source is reported lost. |
| AVPlayer waiting for 8 s while ≥ 3 s is published | Decoder problem, not network: the player item alone is rebuilt (at most every 30 s, three times in two minutes); the connection, reserve and timeline carry on. |

Never more than 15 connection attempts in any minute, on any number of routes.

### Profiles

The Buffer setting (Settings → Streams) picks the engine profile:

| | Fast | Balanced (default) | Stable → Maximum |
| --- | --- | --- | --- |
| Target reserve | 8 s | 20 s | 45 s |
| Low / high mark | 4 / 16 s | 8 / 40 s | 15 / 75 s |
| Published to AVPlayer ahead of the picture | 5 s | 6 s | 6 s |
| Rebuilt before resuming after running dry | 1.5 s | 3 s | 6 s |
| Rate while building / trickling | 0.99 / 0.995 | 0.98 / 0.992 | 0.97 / 0.985 |
| Slowest rate on a weak line | 0.97 | 0.93 | 0.90 |
| Rate when far ahead | 1.01 | 1.01 | 1.01 |
| Frozen this long before reporting the source lost | 15 s | 25 s | 40 s |
| Memory ceiling | 32 MB | 72 MB | 128 MB |

Multiview tiles use Fast with a 20 MB ceiling and a 10 s rewind window. Deeper profiles survive longer outages and weaker lines and sit further behind live.

## Integration

- `MyApp/Playback/StreamEngine/` holds the engine; every type is `nonisolated` and confined to its session's serial queue, so it compiles both under the app's main-actor default isolation and under Swift 6 strict concurrency.
- `PlaybackController` starts an engine session for each live channel and plays the local playlist on an item with no forward buffer of its own and time-domain pitch correction (`PlaybackItemFactory.makeEngineItem`). Its old stall timer and reconnect loop now only run for direct playback. It falls back to direct playback when the engine can't carry the stream before the first frame, when it hasn't produced a playlist after 30 s, and when AirPlay video starts (the receiver can't reach this device's loopback server).
- Settings → Streams has a **Stream Engine** switch (on by default, `UserPreferences.playerStreamEngineEnabled`) for troubleshooting a provider; changes apply from the next channel.
- The player's status pill shows the engine's notice when there is one, and the diagnostics panel shows the engine's phase, route, codecs, reserve, rate and reason, delivery ratio, connections, reconnects, splices, removed overlaps, timeline repairs and decoder resets, plus the recent decisions journal.
- The app target enables `ENABLE_INCOMING_NETWORK_CONNECTIONS` so the macOS sandbox allows the loopback listener.

## Tests

`StreamEngineCoreTests` is a Swift package whose sources are symlinks to `MyApp/Playback/StreamEngine`, like the other `*CoreTests` packages:

```sh
bash StreamEngineCoreTests/run-tests.sh            # macOS, Xcode toolchain (also run by scripts/test-all.sh packages)
swift test --package-path StreamEngineCoreTests     # macOS or Linux with a Swift 6 toolchain
```

The tests build MPEG-TS deterministically (H.264 or HEVC, open or closed GOPs, AAC audio, radio), with every picture carrying its frame number, so they can prove exactly which pictures reached the output:

- **Transport stream parsing**: 33-bit timestamp arithmetic, packet resync after garbage, torn packets and lost sync, PAT/PMT round trip and CRC rejection, multi-packet sections, PES timestamps rewritten across packet boundaries, keyframe classification for H.264/HEVC/MPEG-2, ADTS durations, fingerprints.
- **Splicing**: first connection, re-sent burst (no picture twice), restarted encoder behind / ahead / reset to zero, outage gap closed, reconnect starting just after the tables, continuity counters across every kind of splice, PID change, codec change, open-GOP join, clock jump in one connection, 33-bit wrap, radio, torn picture.
- **Segments, reserve and playlists**: PAT/PMT and keyframe at every segment start, startup and long-GOP cutting, reserve publishing/eviction/byte ceiling, discontinuity sequence, playlist and programme-date output, provider playlist parsing and the formats handed to AVPlayer.
- **Referee, pace and health**: every rule in the table above, including the 15-a-minute ceiling with two and with twenty failing routes, plus pace targets, slew limits and slow-line hysteresis.
- **End to end**: a real engine session, loopback server and URLSession against fake providers, with a virtual player reading the local playlist. A raw TS channel whose connection is cut mid-packet plays with no freeze, no repeated picture and decode times exactly one frame apart; an Xtream channel without `.ts` output falls back to HLS and rides out a 5 s HLS outage the same way.

Deliberately breaking the engine in 16 places (no re-sent detection, deduplication by clock alone, no audio guard, no continuity re-anchoring, no open-GOP discontinuity, no PAT/PMT in segments, no forced long-GOP cut, route switches ignoring the one-minute rule, rationing off, dead routes retried, stall timeout ignoring the reserve, no starvation verdict, no slew limit, reconnects not announced to the splicer, reserve never handed over, a 0.5 s lead) makes the relevant tests fail in 15 of them; rationing was only caught after a test was added for it. The survivor is the 0.5 s lead: the virtual player's polling happened to keep up, so that tuning is left to device testing.

### Chaos runs

The engine was also driven by a scratch harness (not committed): an ffmpeg-encoded fixture (H.264 480×270 at 25 fps with a 2 s GOP, AAC 48 kHz) served live by a fake provider with scheduled faults, played by a virtual player that freezes when its buffer runs out. These measure the engine and the local playlist, not AVPlayer's decoder. Balanced profile unless noted; latest runs:

| Fault | Result |
| --- | --- |
| None (45 s) | 0 freezes, 1 connection |
| Provider closes the stream at 20, 38 and 55 s | 0 freezes; 3 background reconnects, re-sent programme removed each time |
| Connection open but silent for 8 s | 0 freezes; connection replaced, overlap removed |
| Encoder restarts with a new clock and content | 0 freezes; timeline repaired (one 0.67 s audio gap at the join) |
| `.ts` route missing (404) | 0 freezes; HLS route |
| `.ts` route missing and HLS down for 8 s, 12 s provider window | Balanced: one 0.4 s freeze; Maximum: 0 freezes |
| Provider unreachable for 20 s with about 11 s of reserve | one ~10 s freeze, then playback resumes by itself; no error |
| Line delivers 90 % of real time for 3 minutes | Balanced (floor 0.93x): 2 freezes, 1.9 s in total (4 / 2.5 s in a run sharing the CPU); Maximum: 0 freezes at 0.90x |
| `.ts` route sends headers and then nothing | HLS route after 6.3 s, then 0 freezes |
| Provider unreachable for the first 4 s | starts at 5.1 s, once it answers; no error |
| 403 after playing (account taken elsewhere) | yields after two refusals with the account-in-use message |

Validating the runs found and fixed these engine issues: two routes that both served unplayable content retried forever instead of going to AVPlayer; route switches ignored the one-minute rule and kept retrying every 5 s; a channel whose `.ts` output the panel doesn't offer could, during an HLS outage, be switched back to the dead route and given up as "no longer available" or "in use elsewhere"; a 404 after playing ended the stream immediately even with reserve left (it now waits for a frozen picture, then reports it); four refused connections at tune-in gave up within 1.5 s; HLS ingest skipped segments while the provider was unreachable, losing 2 s per outage; and a reconnect landing just after the tables waited out a whole GOP.

## Not verified and limitations

- **AVPlayer on device.** Not run on iOS, tvOS or macOS. Unverified: how AVPlayer honours `EXT-X-START` when an item is rebuilt, rate changes below 1.0x with time-domain pitch on live HLS, behaviour at `EXT-X-DISCONTINUITY` after a codec change, and whether any provider stream triggers decoder errors (such as -12888) that the synthetic and ffmpeg fixtures don't. Watch the diagnostics journal for "Player item rebuilt" on real channels.
- **Programme lost at a splice.** A reconnect must start at a keyframe, so up to one GOP after the last delivered picture can be skipped (usually under 2 s). The timeline is closed up, so this is a small jump in the programme, not a freeze.
- **Reserve depth comes from the provider.** The engine can't download the future: the reserve is what the provider bursts or keeps in its HLS window, plus about 0.5 s a minute while trickling at 0.992x. An outage longer than the reserve freezes once (holding until a few seconds are rebuilt), then resumes.
- **One connection at a time.** No make-before-break: many IPTV accounts allow a single stream, and a second connection would get the first one dropped.
- **Single rendition.** No automatic quality step-down; real bitrate ladders, encrypted, fMP4 and byte-range HLS go to AVPlayer directly.
- **AirPlay video** plays the provider URL directly, without the engine.
