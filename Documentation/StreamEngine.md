# Banner Stream Engine

The stream engine sits between IPTV providers and AVPlayer. It holds the provider connection itself, keeps a reserve of programme ahead of what is on screen, and when a connection breaks it reconnects in the background and splices the new connection onto the old one, so the viewer keeps watching the reserve instead of a spinner. It follows the Neverlag design: a resilient pre-decoder engine with a single recovery referee, and the platform decoder (AVPlayer) behind a thin local adapter.

**What has and hasn't been verified.** The engine and its tests were built and run with the Swift 6.2 toolchain on Linux: 84 unit and end-to-end tests, chaos runs against a fake provider that cuts, stalls, throttles and refuses, and runs against a real Xtream Codes panel, with the engine fetching live channels and a virtual player reading its local playlist (see [Live provider runs](#live-provider-runs)). The app's own target was type-checked with the real `PlaybackController` against stubbed AVFoundation/Combine. No Xcode build, simulator or device run was possible in this environment, so nothing here proves how AVPlayer itself behaves with the local stream (see [Not verified](#not-verified-and-limitations)).

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
2. **Keep a reserve.** Everything received is cut into keyframe-aligned HLS segments of about 2 s (1 s for the first two, so the first picture appears quickly). A source with a keyframe every 4 s, common on IPTV encoders, is still cut at every keyframe; a longer GOP is cut at 4.3 s. Only a short lead (5–6 s) is published to AVPlayer; the rest stays in the engine, so a stalled provider doesn't stall the decoder. The first playlist goes out once 5 s is ready, or 3 s after the first segment: AVPlayer reloads a live playlist only a target duration (4 s) after loading it, so a first playlist holding one short segment would freeze the picture before the next reload.
3. **Detect at the network boundary.** Delivery is measured in programme seconds per wall-clock second, long before AVPlayer would notice anything, over windows at least two delivery rhythms long. The engine learns that rhythm: panels that restream HLS sources as MPEG-TS deliver in bursts about 4–5 s apart, and a pause that long is normal there, not a stall. A silent connection is replaced after 6–12 s, depending on how much reserve is left, and never sooner than 1.5 × the learned rhythm + 1 s.
4. **Reconnect in the background.** The viewer keeps watching the reserve while the referee reconnects: immediately the first time, then with a short backoff.
5. **Splice.** The new connection is joined onto the old one at a picture the decoder can start from:
   - after a drop on a raw MPEG-TS connection, the GOP the drop cut short is held back while at least 5.5 s of other programme is ahead of the picture. Providers re-send their last seconds on connect, so the reconnect usually re-sends that GOP's keyframe: the engine takes over from it and the splice skips nothing and repeats nothing. If the keyframe doesn't come within 6 s, or the reserve runs low first, the held GOP is released and the splice carries on as below;
   - re-sent programme (the provider's burst) is recognised by keyframe fingerprint and skipped, so no picture plays twice; re-sent audio that straddles the join is cut at an AAC frame, so the sound carries on without a hole (a PES often holds a fifth of a second or more);
   - HLS ingest resumes after the last segment it delivered, so a reconnect within the provider's playlist window loses nothing;
   - a restarted encoder's new clock, a forward gap after an outage, or a clock jump within a connection is re-timed so the output timeline stays continuous (PTS, DTS and PCR move together, so audio stays in sync);
   - PIDs are remapped onto the output program and continuity counters stay continuous;
   - only a codec change or a join at an open-GOP picture is announced to AVPlayer as a discontinuity;
   - a PES packet still open when a connection ends is kept when it's known to be whole (its header announces a length that has all arrived, or an HLS segment ended there); a picture torn by a dying socket is dropped, never glued to the next connection.
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
| The same route keeps failing | The backup route is tried after three failures on a route that has played (two on one that hasn't): a reconnect to the playing route brings the provider's burst, while the backup (often HLS) can run behind it. |
| No programme for a minute | Probes step out to 15, 30, then 60 s; the viewer sees "Provider not responding · retrying in N s". |
| Connected but silent | Replaced after `reserve − 6 s`, clamped to 6–12 s, and never sooner than the connection's normal silence: 1.5 × the learned delivery rhythm + 1 s on MPEG-TS, 2 × target duration + 2 s on HLS. |
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

The tests build MPEG-TS deterministically (H.264 or HEVC, open or closed GOPs, AAC audio in PES packets that announce their length, radio), with every picture carrying its frame number, so they can prove exactly which pictures reached the output:

- **Transport stream parsing**: 33-bit timestamp arithmetic, packet resync after garbage, torn packets and lost sync, PAT/PMT round trip and CRC rejection, multi-packet sections, PES timestamps rewritten across packet boundaries, keyframe classification for H.264/HEVC/MPEG-2, ADTS durations, fingerprints.
- **Splicing**: first connection, a reconnect that re-sends the last keyframe taken over from it (also after skipping a longer re-sent burst, and with open GOPs), re-sent burst without a held GOP (no picture twice), restarted encoder behind / ahead / reset to zero, outage gap closed, reconnect starting just after the tables, continuity counters across every kind of splice, PID change, codec change, open-GOP join, clock jump in one connection, 33-bit wrap, radio, torn picture, whole audio kept at a drop, re-sent audio straddling a splice cut at an AAC frame, HLS segments joined seamlessly across a reconnect, the picture before an HLS discontinuity kept.
- **Segments, reserve and playlists**: PAT/PMT and keyframe at every segment start, startup and long-GOP cutting, a 4 s GOP cut at every keyframe, reserve publishing/eviction/byte ceiling, discontinuity sequence, playlist and programme-date output, provider playlist parsing and the formats handed to AVPlayer.
- **Referee, pace and health**: every rule in the table above, including the 15-a-minute ceiling with two and with twenty failing routes and the extra patience for a route that has played, plus the learned delivery rhythm, the delivery ratio of a bursty line, pace targets, slew limits and slow-line hysteresis.
- **End to end**: a real engine session, loopback server and URLSession against fake providers, with a virtual player that reloads the local playlist as RFC 8216 tells AVPlayer to. A raw TS channel whose connection is cut mid-packet plays with no freeze, no repeated picture, no missing picture and decode times exactly one frame apart (the reconnect's burst re-sends the GOP the cut interrupted); an Xtream channel without `.ts` output falls back to HLS and rides out a 5 s HLS outage the same way, losing nothing.

Deliberately breaking the engine in 16 places (no re-sent detection, deduplication by clock alone, no audio guard, no continuity re-anchoring, no open-GOP discontinuity, no PAT/PMT in segments, no forced long-GOP cut, route switches ignoring the one-minute rule, rationing off, dead routes retried, stall timeout ignoring the reserve, no starvation verdict, no slew limit, reconnects not announced to the splicer, reserve never handed over, a 0.5 s lead) makes the relevant tests fail in 15 of them; rationing was only caught after a test was added for it. The survivor is the 0.5 s lead: the virtual player's polling happened to keep up, so that tuning is left to device testing. What was added after the live runs was checked the same way: without the keyframe resume the end-to-end cut test misses pictures, and ignoring announced PES lengths, treating the end of an HLS segment or a discontinuity as a torn packet, the session not passing the segment boundary on, or dropping straddling audio whole (or cutting it a frame short) each fail the tests written for them.

### Chaos runs

The engine was also driven by a scratch harness (not committed): an ffmpeg-encoded fixture (H.264 480×270 at 25 fps with a 2 s GOP, AAC 48 kHz) served live by a fake provider with scheduled faults, played by a virtual player that freezes when its buffer runs out. These measure the engine and the local playlist, not AVPlayer's decoder. Balanced profile unless noted. All of them were re-run after the fixes from the live runs (the two that splice by skipping re-sent programme again after the last fix, which cuts re-sent audio at a frame); where a result differed from what this page said before, the engine as first committed was run alongside it in the same conditions:

| Fault | Result |
| --- | --- |
| None (45 s) | 0 freezes, 1 connection |
| Provider closes the stream at 20, 38 and 55 s | 0 freezes; 3 background reconnects. The last one rejoined at the interrupted GOP's keyframe with nothing missed. The first two came with less than 5.5 s ahead of the picture, so the re-sent programme was skipped instead and 0.1 s of programme went missing each time; the audio carried on with at most one AAC frame (21 ms) between packets, where it had left a 0.32 s hole before re-sent audio was cut at frames |
| Connection open but silent for 8 s | 0 freezes; replaced, 0.1 s missed, audio continuous as above |
| Encoder restarts with a new clock and content | 0 freezes; timeline repaired (one 0.67 s audio gap at the join) |
| `.ts` route missing (404) | 0 freezes; HLS route |
| `.ts` route missing and HLS down for 8 s, 12 s provider window | one freeze, 1.6 s (Maximum: 1.1 s). The window holds less programme than the outage and the reconnect take; the first commit gave 1.4 s (Maximum 0.8 s) in the same conditions, not the 0.4 s (Maximum: none) this page used to show |
| Provider unreachable for 20 s with about 11 s of reserve | one ~10 s freeze, then playback resumes by itself; no error |
| Line delivers 90 % of real time for 3 minutes | Balanced (floor 0.93x): 5 freezes, 3.1 s in total; Maximum (0.90x): 1 freeze, 0.4 s. The first commit gave 5 freezes and 3.4 s beside it; the 2 freezes this page used to show didn't reproduce. Why a slow line freezes this early is under [limitations](#not-verified-and-limitations) |
| `.ts` route sends headers and then nothing | HLS route after 6.3 s, then 0 freezes |
| Provider unreachable for the first 4 s | starts at 6.8 s, once it answers and the backoff comes round (the first commit: 6.9 s); no error |
| 403 after playing (account taken elsewhere) | yields after two refusals with the account-in-use message |

Validating the runs found and fixed these engine issues: two routes that both served unplayable content retried forever instead of going to AVPlayer; route switches ignored the one-minute rule and kept retrying every 5 s; a channel whose `.ts` output the panel doesn't offer could, during an HLS outage, be switched back to the dead route and given up as "no longer available" or "in use elsewhere"; a 404 after playing ended the stream immediately even with reserve left (it now waits for a frozen picture, then reports it); four refused connections at tune-in gave up within 1.5 s; HLS ingest skipped segments while the provider was unreachable, losing 2 s per outage; and a reconnect landing just after the tables waited out a whole GOP.

## Live provider runs

A sample Xtream Codes account (four connections, about 22,000 live channels) was played through the real engine for 3 minutes per channel, Balanced profile, with the scratch harness's virtual player reading the local playlist. Everything the player received was then checked with ffprobe and ffmpeg. The sandbox reached the panel through a small relay, which could also cut connections and refuse requests on cue. How the panel serves its channels:

- a `.ts` request is redirected to a streaming server with a per-request token, and the stream is then one long response;
- every connection starts with a burst of the last 5–23 s of programme;
- channels the panel restreams from HLS sources arrive in bursts about 4.7 s apart, silent in between;
- keyframes came anywhere from every 0.2 s to every 5.2 s, and audio PES carried 0.17–0.24 s of AAC each;
- the tested channels were H.264 at 720p or 1080p and 25, 29.97 or 50 fps, each with one AAC track; a 4K channel was HEVC Main 10 with AC-3 (see [limitations](#not-verified-and-limitations)).

Results with the engine as committed (the last change, cutting re-sent audio at an AAC frame, was in place for the cut US sports A and the HLS runs; it only acts at splices that skip re-sent programme, which the other runs didn't have):

| Channel | Faults in the 3 minutes | Result |
| --- | --- | --- |
| US sports A, 720p 29.97 fps, delivered in bursts about 4.7 s apart | none | 0 freezes, one connection throughout |
| US sports A | relay cut the connection 40 s in, three times | 0 freezes. The first two cuts came with only 6–7 s buffered (this channel's burst on connect was 5 s), so the re-sent programme was skipped: 0.6 s and 0 s of programme missing, the audio continuous. The third rejoined at the last keyframe, nothing missed |
| US sports B, 720p 29.97 fps | none | 0 freezes |
| German sports, 720p 50 fps | the provider went silent for over 6.6 s twice and closed the stream once | 0 freezes; all three reconnects rejoined at the last keyframe, nothing missed |
| UK sports, 1080p 25 fps | none | 0 freezes |
| UK sports over HLS only (the relay refused `.ts`) | the playlist was refused (403) three times in a row, twice | 0 freezes; each retry resumed after the last segment delivered, seamlessly |
| Arabic sports, 720p 50 fps | relay cut 40 s in, three times | 0 freezes; each reconnect rejoined at the last keyframe, nothing missed |
| Spanish sports A, 720p 25 fps | relay cut 45 s in, three times | 0 freezes; each rejoined, nothing missed |
| Spanish sports B, 720p 25 fps | relay cut 50 s in, twice | 0 freezes; each rejoined, nothing missed |

Every output was one continuous timeline, with no timestamp running backwards, and decoded without errors. The one exception is Spanish sports B, whose encoder puts the buffering-period SEI ahead of the SPS in every keyframe: ffmpeg reports that once wherever decoding starts. The engine passes access units through untouched.

Runs before the fixes below froze the bursty US channel 6 times in 3 minutes (7.8 s in all) and the Arabic one once (2.0 s), and a provider drop on the UK channel skipped 1.2 s of programme. With the first fixes in, US sports B still froze 3 times (5.4 s) and the German channel twice (1.9 s). What the runs exposed, and what changed:

- Bursty restreams pause about 4.7 s between deliveries. Against a 4 s minimum stall timeout every pause looked like a dead connection, and replacing it threw away the burst that was on its way. The engine now learns each line's delivery rhythm, never calls a pause a stall before 1.5 × that rhythm + 1 s, and waits at least 6 s.
- One-second delivery-ratio windows read a bursty line as slow and slowed playback for nothing; the windows now span at least two delivery rhythms.
- The first playlist could carry a single 2 s segment while AVPlayer reloads only a target duration (4 s) later, freezing the picture right after tune-in. The first playlist now waits for 5 s, or 3 s after the first segment.
- Encoders with a keyframe every 4 s were force-cut at 3.5 s, so most segments didn't start with a keyframe; the forced cut moved to 4.3 s.
- After two transient stalls the referee switched to the HLS route, which runs behind the `.ts` route. A route that has played now gets three failures.
- A reconnect skipped the rest of the GOP the drop interrupted. The engine now holds that GOP and rejoins at its keyframe when the burst re-sends it.
- An HLS reconnect dropped the last picture of the last segment, and audio re-sent across a splice was dropped a whole PES at a time. Whole PES packets are now kept when a connection ends, and straddling audio is cut at an AAC frame.

On Linux the harness's CPU time went almost entirely to FoundationNetworking's libcurl-based URLSession and to libdispatch. The engine's own work (packet alignment, splicing, segmenting) took 0.19 s of CPU for 3 minutes of a 3.7 Mbps channel, 441 MB/s on one core. Apple platforms use their own URLSession instead.

## Not verified and limitations

- **AVPlayer on device.** Not run on iOS, tvOS or macOS. Unverified: how AVPlayer honours `EXT-X-START` when an item is rebuilt, rate changes below 1.0x with time-domain pitch on live HLS, behaviour at `EXT-X-DISCONTINUITY` after a codec change, and whether any provider stream triggers decoder errors (such as -12888) that the synthetic and ffmpeg fixtures don't. Watch the diagnostics journal for "Player item rebuilt" on real channels.
- **Programme lost at a splice.** After a drop on a raw TS connection nothing is lost when the reconnect re-sends the last keyframe within 6 s and at least 5.5 s was ahead of the picture. In the live runs that covered every drop once the reserve had built up. Otherwise (a thin reserve soon after tune-in, or a provider that doesn't re-send), the reconnect must still join at a keyframe, so up to one GOP after the last delivered picture can be skipped (0–0.6 s in the runs above). The timeline is closed up, so this is a small jump in the programme, not a freeze. HLS ingest loses nothing while the next segment is still in the provider's window.
- **Thin reserve, coarse playlist.** The local playlist's target duration is 4 s, so that 4 s GOPs can be cut at keyframes, and AVPlayer reloads a live playlist only that often. With the reserve empty (a line slower than real time, or straight after a long outage), the segment still being cut and the time to the next reload leave the player a few seconds short of what the engine holds. A slow line therefore freezes briefly every 20 s or so (the 90 % line above) instead of playing to the end of the buffer. A target duration chosen from the source's GOP (2 s for 2 s GOPs) would roughly halve that gap; it needs testing with AVPlayer first.
- **HEVC in MPEG-TS.** Apple's HLS authoring guidance asks for HEVC in fragmented MP4, so HEVC channels (such as 4K feeds) carried in the engine's MPEG-TS playlist will probably not play; unverified on device. Supporting them means packaging HEVC as fMP4.
- **Reserve depth comes from the provider.** The engine can't download the future: the reserve is what the provider bursts or keeps in its HLS window, plus about 0.5 s a minute while trickling at 0.992x. An outage longer than the reserve freezes once (holding until a few seconds are rebuilt), then resumes.
- **One connection at a time.** No make-before-break: many IPTV accounts allow a single stream, and a second connection would get the first one dropped.
- **Single rendition.** No automatic quality step-down; real bitrate ladders, encrypted, fMP4 and byte-range HLS go to AVPlayer directly.
- **AirPlay video** plays the provider URL directly, without the engine.
