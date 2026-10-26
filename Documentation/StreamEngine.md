# Banner Stream Engine

The stream engine sits between IPTV providers and AVPlayer. It holds the provider connection itself, keeps a reserve of programme ahead of what is on screen, and when a connection breaks it reconnects in the background and splices the new connection onto the old one, so the viewer keeps watching the reserve instead of a spinner. It follows the Neverlag design: a resilient pre-decoder engine with a single recovery referee, and the platform decoder (AVPlayer) behind a thin local adapter.

**What has and hasn't been verified.** The engine and its tests were built and run with the Swift 6.2 toolchain on Linux: 128 unit and end-to-end tests, chaos runs against a fake provider that cuts, stalls, throttles and refuses, and runs against a real Xtream Codes panel, HD and 4K, with the engine fetching live channels, a virtual player reading its local playlist and, for 4K, ffmpeg playing it as a second HLS client (see [Live provider runs](#live-provider-runs)). The fragmented MP4 it publishes for 4K was checked with ffmpeg, ffprobe and MP4Box. The app's own target was type-checked with the real `PlaybackController` against stubbed AVFoundation/Combine. No Xcode build, simulator or device run was possible in this environment, so nothing here proves how AVPlayer itself behaves with the local stream (see [Not verified](#not-verified-and-limitations)).

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
2. **Keep a reserve.** Everything received is cut into keyframe-aligned HLS segments of about 2 s (1 s for the first two, so the first picture appears quickly). A source with a keyframe every 4 s, common on IPTV encoders, is still cut at every keyframe; a longer GOP is cut at 4.3 s. Only a short lead (5–6 s) is published to AVPlayer; the rest stays in the engine, so a stalled provider doesn't stall the decoder. The first playlist goes out once 5 s is ready, or 3 s after the first segment: AVPlayer reloads a live playlist only a target duration (4 s) after loading it, so a first playlist holding one short segment would freeze the picture before the next reload. Until AVPlayer has actually started playing, the playlist keeps growing in real time whatever position it reports: a player that is still starting reports where it will start from, and publishing no further than that would leave the playlist unchanged, which AVPlayer treats as an error after 1.5 target durations (-12888).
3. **Detect at the network boundary.** Delivery is measured in programme seconds per wall-clock second, long before AVPlayer would notice anything, over windows at least two delivery rhythms long. The engine learns that rhythm: panels that restream HLS sources as MPEG-TS deliver in bursts about 4–5 s apart, and a pause that long is normal there, not a stall. A silent connection is replaced after 6–12 s, depending on how much reserve is left, and never sooner than 1.5 × the learned rhythm + 1 s.
4. **Reconnect in the background.** The viewer keeps watching the reserve while the referee reconnects: immediately the first time, then with a short backoff.
5. **Splice.** The new connection is joined onto the old one at a picture the decoder can start from:
   - after a drop on a raw MPEG-TS connection, the GOP the drop cut short is held back while at least 5.5 s of other programme is ahead of the picture. Providers re-send their last seconds on connect, so the reconnect usually re-sends that GOP's keyframe: the engine takes over from it and the splice skips nothing and repeats nothing. If the keyframe doesn't come within 6 s, or the reserve runs low first, the held GOP is released and the splice carries on as below;
   - re-sent programme (the provider's burst) is recognised by keyframe fingerprint and skipped, so no picture plays twice; re-sent audio that straddles the join is cut at an AAC frame, so the sound carries on without a hole (a PES often holds a fifth of a second or more);
   - HLS ingest resumes after the last segment it delivered, so a reconnect within the provider's playlist window loses nothing;
   - a restarted encoder's new clock, a forward gap after an outage, or a clock jump within a connection is re-timed so the output timeline stays continuous (PTS, DTS and PCR move together, so audio stays in sync);
   - programme the provider drops in the middle of a connection (0.25–2 s missing, as panels' MPEG-TS output does with 4K streams it can't keep up with) is closed up at once, without waiting for a keyframe: the next picture follows straight on, the audio after the gap moves with it, and audio stamped before the gap that arrives late still plays before it. Holding the last picture for the gap's length would show as a freeze. Only a gap after at least eight ordinary picture steps counts, so a stream that lowers its picture rate is closed up once, not squeezed;
   - a PES packet that lost transport packets part-way (a gap in the continuity counter) is dropped rather than decoded with a hole in it, unless it announces a length that all arrived; duplicate packets are ignored. Continuity counters that restart at an HLS segment boundary don't count as loss;
   - PIDs are remapped onto the output program and continuity counters stay continuous;
   - only a codec change or a join at an open-GOP picture is announced to AVPlayer as a discontinuity;
   - a PES packet still open when a connection ends is kept when it's known to be whole (its header announces a length that has all arrived, or an HLS segment ended there); a picture torn by a dying socket is dropped, never glued to the next connection.
6. **One referee.** `RecoveryReferee` is the only code that decides what happens next, and only one remedy is in flight at a time. Every decision is written to the diagnostics journal.
7. **Adapt on a slow line.** A line that can't deliver real time is played slightly slower (pitch-corrected, down to the profile's floor) instead of freezing; a healthy line plays a hair below 1.0x until the reserve reaches its target and a hair above when it has grown well past it.

AVPlayer only ever sees a well-formed local live playlist (`http://127.0.0.1:<port>/<token>/<session>/live.m3u8`) whose segments each start with PAT/PMT and a keyframe; HEVC channels get fragmented MP4 renditions under a multivariant playlist at the same address instead (see [4K and HEVC channels](#4k-and-hevc-channels)). The path carries an unguessable token; no provider URL, credential or header is exposed through it.

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
| An Xtream channel turns out to be HEVC (4K) | Before anything plays, the panel's HLS output is used instead of its MPEG-TS output. |
| Programme arrives with holes (the provider drops chunks of it) | Each gap is closed up as it comes. Two gaps (closed up, or long enough to need a timeline jump), or 1.5 s of programme, missing within 30 s on one route: the other route is used at once (the panel's HLS output carries 4K channels whole where its MPEG-TS output drops them), and a route found dropping programme isn't switched to for that reason again. HLS ingest then joins at its newest segment (4 s back) and never further back than the programme already delivered; the new route is taken to be on the same clock, so what it re-sends is skipped even from before anything the old route delivered. |
| No programme at start-up | An on-demand source nobody else is watching (most event channels) takes the panel up to 8 s to start: it answers once the source is up, or refuses that output (502) a little later, when the other output usually works. So the backup route is tried when the first hasn't answered in 8 s; a route that has answered gets 12 s to bring a picture, as does every later attempt. When every route has had its 12 s (or two tries *and* 12 s, for connections that failed outright) without the provider ever answering, AVPlayer tries the URL directly. |
| The provider answers with nothing to play before anything has played | A route is off the air after a server error or empty response twice, at least a second apart; after one that the panel took 5 s or more to give (it tries to start the source for about 10 s before answering 502); or after answering and then sending no media for the whole 12 s. Once every route is off the air: "This channel isn't broadcasting right now", with no retry through AVPlayer, which would get the same answers. Panels answer an event channel with nothing on 502 or 503, then 888 to repeated requests. |
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

### 4K and HEVC channels

IPTV panels send 4K channels as HEVC in MPEG-TS, but AVPlayer plays HLS HEVC only from fragmented MP4 (Apple's HLS authoring specification). So when a channel's program carries HEVC, the session publishes fMP4 instead (`FragmentedPackager`, `FragmentedMP4`, `CodecConfiguration`). Splicing, the reserve, recovery and pacing are unchanged: only the publication differs.

- **Route.** On the live panel the MPEG-TS output dropped 1–19 % of the programme of every 4K channel (13–19 Mbit/s), while its HLS output carried the same channels whole (see [Live provider runs](#4k-channels)). So when an Xtream channel's first program table shows HEVC, before anything has been published, the engine leaves the MPEG-TS route for the panel's HLS output, whose window then fills the reserve at once. If that route is refused or missing, the MPEG-TS route is used as before, with dropped programme closed up and the route left again if a better one appears.
- **Playlists.** `live.m3u8` becomes a multivariant playlist with one video variant (`video.m3u8`) and each audio track as its own rendition (`audio0.m3u8`, …): Apple requires multichannel audio as a separate rendition, and no segment may carry two audio streams. The variant states `CODECS` (RFC 6381, read from the parameter sets and audio headers, e.g. `hvc1.2.4.L153.B0,ec-3`), `RESOLUTION`, `FRAME-RATE`, `VIDEO-RANGE` (PQ, HLG or SDR) and `BANDWIDTH`/`AVERAGE-BANDWIDTH` measured from the reserve, so AVPlayer can tell it can play the variant and set up HDR before the first picture. Each rendition has `LANGUAGE` (RFC 5646, from the PMT's ISO 639 descriptor), a unique `NAME` and `CHANNELS`; the first is `DEFAULT`. Every media playlist repeats `EXT-X-MAP` after each discontinuity, starts every rendition at the same moment (`EXT-X-START`), and claims `EXT-X-INDEPENDENT-SEGMENTS` only while every segment it lists starts with a keyframe.
- **Initialization sections.** The VPS, SPS and PPS go into an `hvc1` sample entry as complete arrays; copies identical to them are dropped from the samples, as are access unit delimiters, and SEI stays in the samples. The entry carries the colour description (`colr` nclx) and puts the HDR10 mastering-display and content-light-level SEI in the `hvcC` record's declarative array. HLG sent backward-compatibly (BT.2020 SDR in the VUI, HLG in an alternative-transfer SEI) is signalled as HLG. Audio: AAC with its AudioSpecificConfig (HE-AAC with SBR signalled explicitly, object type 5, as Apple requires), AC-3 (`dac3`) and E-AC-3 (`dec3`, with frames of fewer than six blocks and dependent substreams grouped into 1536-sample access units).
- **Fragments.** Each segment becomes one video fragment and one fragment per audio rendition. Sample flags come from the slice types (RASL and RADL leading pictures are marked), with composition offsets for reordered pictures. Decode times run on unbroken from fragment to fragment, as the authoring rules require: where a splice resumed a few frames late, the first picture's decode slot is stretched instead of leaving a gap, and a hole at the start of a segment's audio is taken into its first frame. A change of picture format (codec, size, profile, level or colour) or of an audio format starts a new initialization section behind a discontinuity.
- **H.264 channels stay on MPEG-TS** as before. A channel that switches from H.264 to HEVC mid-session is published as fMP4 from its first HEVC segment, and the player is moved there (`endpointChanged`, which rebuilds the player item); the MPEG-TS programme it hadn't played yet is skipped. A switch the other way carries on in the fMP4 publication behind a discontinuity, with an `avc1` initialization section; the multivariant playlist keeps the CODECS it was first written with.

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

The tests build MPEG-TS deterministically (H.264 or HEVC, open or closed GOPs, AAC audio in PES packets that announce their length, E-AC-3 tracks with language descriptors, radio, and real x265/x264 parameter sets where a test needs a stream that can be packaged), with every picture carrying its frame number, so they can prove exactly which pictures reached the output:

- **Transport stream parsing**: 33-bit timestamp arithmetic, packet resync after garbage, torn packets and lost sync, PAT/PMT round trip and CRC rejection, multi-packet sections, PES timestamps rewritten across packet boundaries, keyframe classification for H.264/HEVC/MPEG-2, ADTS durations, fingerprints.
- **Splicing**: first connection, a reconnect that re-sends the last keyframe taken over from it (also after skipping a longer re-sent burst, and with open GOPs), re-sent burst without a held GOP (no picture twice), restarted encoder behind / ahead / reset to zero, outage gap closed, reconnect starting just after the tables, continuity counters across every kind of splice, PID change, codec change, open-GOP join, clock jump in one connection, 33-bit wrap, radio, torn picture, whole audio kept at a drop, re-sent audio straddling a splice cut at an AAC frame, HLS segments joined seamlessly across a reconnect, the picture before an HLS discontinuity kept; programme dropped mid-connection closed up mid-GOP with every later picture kept and the audio in step, audio sent late still played before the gap it belongs before, a hiccup of a few frames left alone, a lowered picture rate closed up once; a picture that lost packets dropped and a duplicate packet ignored, counters restarting at an HLS segment boundary not taken for loss, and another route's programme from before anything delivered skipped, not replayed.
- **Segments, reserve and playlists**: PAT/PMT and keyframe at every segment start, startup and long-GOP cutting, a 4 s GOP cut at every keyframe, reserve publishing/eviction/byte ceiling, discontinuity sequence, playlist and programme-date output, provider playlist parsing and the formats handed to AVPlayer.
- **Referee, pace and health**: every rule in the table above, including the 15-a-minute ceiling with two and with twenty failing routes, the extra patience for a route that has played, a route that drops programme giving way to the other and not being switched back to, a preferred route taken only before anything plays, start-up patience on every route, channels off the air (502/503 on every route, within 5 s and not retried through AVPlayer; one refusal the panel took 10 s to give; answered and then silent; bytes that never make a picture still going to AVPlayer; a single quick refusal not condemning a route), plus the learned delivery rhythm, the delivery ratio of a bursty line, pace targets, slew limits and slow-line hysteresis.
- **Codec configuration**: x265 parameter sets (4K PQ Main 10, 720p HLG, 1080p SDR Main) and x264 ones (High, and Constrained Baseline coded at 1088 lines and cropped) give the size, profile, level, colour and the codec string MP4Box reads from the same streams; `hvcC` and `avcC` records byte for byte; HDR10 SEI gathered into the record, other SEI left out; HLG read from an alternative-transfer SEI; AudioSpecificConfig for AAC-LC and HE-AAC, `dac3` and `dec3` matching what real channels carry; frame splitting with resync.
- **Fragmented MP4**: the initialization sections' box trees (`hvc1` with `hvcC`, `colr` and `pasp`; `mp4a` with its `esds`, `ec-3` with `dec3`; track languages), fragment layout (data offset, signed composition offsets, empty fragments), fMP4 media playlists (`EXT-X-MAP` after every discontinuity, independent segments only when true) and the multivariant playlist.
- **fMP4 packaging**: a 4K HEVC stream cut by the segmenter becomes one initialization section and fragments holding every picture once and in order, keyframes as sync samples starting each fragment, no parameter sets or delimiters in the samples, decode times unbroken in video and audio, and audio starting with the pictures; a new picture format starts a new initialization section behind a discontinuity; a splice resumed two frames late keeps decode times unbroken and the picture on time, while a discontinuity keeps its jump; backward-compatible HLG is published as HLG; a hole at the start of a segment's audio is taken into its first frame, except behind a discontinuity, and audio the next segment repeats is dropped; AAC and E-AC-3 tracks become two renditions with their languages; E-AC-3 frames of one or three blocks and dependent substreams make 1536-sample access units; H.264 packages as `avc1`.
- **End to end**: a real engine session, loopback server and URLSession against fake providers, with a virtual player that reloads the local playlist as RFC 8216 tells AVPlayer to. A raw TS channel whose connection is cut mid-packet plays with no freeze, no repeated picture, no missing picture and decode times exactly one frame apart (the reconnect's burst re-sends the GOP the cut interrupted); an Xtream channel without `.ts` output falls back to HLS and rides out a 5 s HLS outage the same way, losing nothing. A 4K HEVC channel with English AAC and French E-AC-3, cut the same way, is published as a multivariant playlist with the right `CODECS`, `RESOLUTION`, `FRAME-RATE`, `VIDEO-RANGE` and renditions, and plays as fMP4 with no freeze, nothing missed and decode times unbroken; a channel that switches from H.264 to HEVC moves the player to the fMP4 renditions once and plays on. A channel whose MPEG-TS output drops every eighth 0.4 s chunk, or 2.4 s of every 8, moves to the panel's HLS output once, with no freeze: the gaps before it are closed up (decode times one frame apart throughout), nothing plays twice, and after the move the programme is whole, also when the HLS window starts at a keyframe the MPEG-TS output had dropped. A 4K HEVC Xtream channel moves to the panel's HLS output before its first picture and plays from that window with nothing missing. An Xtream channel that answers 502 on both outputs is reported off the air in under 6 s; one that answers and then sends nothing on both is reported after one wait per output; one the panel takes 7 s to start plays from its MPEG-TS output with no route switch and no freeze; one whose MPEG-TS output the panel refuses after trying for 9 s plays from HLS within 10 s, without waiting for the refusal; and a player that reports its starting position without playing sees the playlist keep changing.

Deliberately breaking the engine in 16 places (no re-sent detection, deduplication by clock alone, no audio guard, no continuity re-anchoring, no open-GOP discontinuity, no PAT/PMT in segments, no forced long-GOP cut, route switches ignoring the one-minute rule, rationing off, dead routes retried, stall timeout ignoring the reserve, no starvation verdict, no slew limit, reconnects not announced to the splicer, reserve never handed over, a 0.5 s lead) makes the relevant tests fail in 15 of them; rationing was only caught after a test was added for it. The survivor is the 0.5 s lead: the virtual player's polling happened to keep up, so that tuning is left to device testing. What was added after the live runs was checked the same way: without the keyframe resume the end-to-end cut test misses pictures, and ignoring announced PES lengths, treating the end of an HLS segment or a discontinuity as a torn packet, the session not passing the segment boundary on, or dropping straddling audio whole (or cutting it a frame short) each fail the tests written for them. The 4K work was checked the same way, 37 changes in all: dropping or mis-flagging anything in the packager (decode-time repair at splices, parameter-set and delimiter stripping, E-AC-3 access units, HLG from SEI, HDR10 SEI in `hvcC`, sync flags, format changes and their discontinuity, repeated or missing audio at a fragment's start), the multivariant playlist's attributes, independent-segment and `EXT-X-MAP` rules, the switch to fMP4, closing provider gaps (at all, early, guarded against a lowered picture rate, audio before the gap kept in place), torn and duplicate packets, segment-boundary counters, moving off a lossy route (the switch, jumps counted, a lossy route not switched back to, the join depth capped, the same-clock assumption and its survival through a reconnect), and moving an HEVC channel to the HLS output (at all, after playing, to a dead route, and only once what was delivered is committed). All but two fail a test. One survivor joins the HLS route 20 s back instead of 4 on a move: early in a session the delivered programme already caps the depth, so the fake panel can't tell them apart. The other moves to the HLS output straight from the program table instead of after the commit: nothing from the connection is in flight that early, so the two come to the same thing, and waiting is only a guard against reordering. The start-up rules were checked the same way, twelve changes, each failing a test: the provider's answer never passed to the referee, or only noticed with the first bytes; an unanswered first route dropped after 6 s as before, or waited out for the whole timeout; an answered one cut at 8 s too; a slow refusal treated like a quick one; two quick refusals condemning a route; server errors never meaning off the air; off the air handed to AVPlayer anyway; bytes without a picture called off the air; routes that timed out retried regardless; and publishing tied to the position of a player that hasn't started.

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

The 4K path was driven the same way with x265 fixtures, encoded at 640×360 so the sandbox's CPU could keep up (packaging doesn't depend on picture size): HEVC Main 10 PQ at 50 fps with 1 s GOPs and E-AC-3 5.1; Main 10 HLG at 59.94 fps with 2 s open GOPs and AAC; Main SDR at 25 fps with AAC stereo and AC-3 5.1. Besides the virtual player, ffmpeg played the engine's multivariant playlist as a second HLS client. In every run the fMP4 the player received decoded without errors, its decode times ran on unbroken from fragment to fragment, and hashing each decoded picture against the fixture's showed exactly which pictures arrived:

| Channel and fault | Result |
| --- | --- |
| PQ on a panel without HLS output (one MPEG-TS route); the provider closes the stream at 20, 38 and 55 s | 0 freezes; every reconnect rejoined at the last keyframe: all 3,900 pictures arrived once and in order |
| HLG with open GOPs, the same cuts | 0 freezes; two reconnects rejoined at the last keyframe. The other came with less than 5.5 s published ahead of the picture, so it joined at the next keyframe, behind a discontinuity: 6 pictures (0.1 s) missing, every other picture once and in order |
| HLG, connection open but silent for 8 s | 0 freezes; replaced after 6.1 s of silence, but the provider stayed silent 2 s longer, so the held GOP was released as the reserve ran low and the reconnect joined at the next keyframe: 2.0 s of programme skipped, closed up |
| H.264 channel whose encoder restarts as HEVC PQ 25 s in | 0 freezes; the player moved to the fMP4 renditions once; every HEVC picture from the restart on, once and in order |
| The PQ channel, and the SDR one with two audio tracks, as Xtream links | moved to the HLS output 0.4 s in, before the first picture; 0 freezes; every picture once and in order; the SDR channel's AAC and AC-3 tracks became two renditions, both of which ffmpeg played |

## Live provider runs

A sample Xtream Codes account (four connections, about 22,000 live channels) was played through the real engine for 3 minutes per channel, Balanced profile, with the scratch harness's virtual player reading the local playlist. Everything the player received was then checked with ffprobe and ffmpeg. The sandbox reached the panel through a small relay, which could also cut connections and refuse requests on cue. How the panel serves its channels:

- a `.ts` request is redirected to a streaming server with a per-request token, and the stream is then one long response;
- every connection starts with a burst of the last 5–23 s of programme;
- channels the panel restreams from HLS sources arrive in bursts about 4.7 s apart, silent in between;
- keyframes came anywhere from every 0.2 s to every 5.2 s, and audio PES carried 0.17–0.24 s of AAC each;
- the tested channels were H.264 at 720p or 1080p and 25, 29.97 or 50 fps, each with one AAC track; the 4K channels have [their own section](#4k-channels).

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

### 4K channels

Seven of the account's 4K channels were probed (one didn't answer) and six were played through the engine as committed, one at a time, Balanced profile, for 2–2.5 minutes each. Besides the virtual player, ffmpeg played the engine's local multivariant playlist as a second HLS client, and everything both received was decoded. How these channels come:

- HEVC 3840×2160 at 50 fps (one at 25), Main and Main 10, in PQ, HLG (one sent as BT.2020 SDR with an alternative-transfer SEI), BT.709 and BT.2020 SDR; keyframes every 0.08–2 s, open GOPs with RASL pictures on two, four slices per picture on one;
- E-AC-3 5.1 with Atmos at 640 kb/s, E-AC-3 5.1 at 384 kb/s and stereo at 192 kb/s, AAC-LC, HE-AAC, and two AAC tracks on one channel; most with a language descriptor;
- the panel's MPEG-TS output dropped part of every one of them, in chunks of 0.3–4 s, often splitting a picture: 1.3 % of the programme of a 13 Mbit/s channel, 15–19 % of two at 17–19 Mbit/s, with the panel delivering a steady 15.5 Mbit/s. Its HLS output carried the same channels whole (checked with captures straight from the panel, not through the engine), and the H.264 channels at 2.5–5 Mbit/s lost nothing on either.

| Channel | Format | Faults | Result |
| --- | --- | --- | --- |
| UK sports | HEVC Main 10 HLG, AAC stereo (English) | none | moved to the HLS output 1.0 s in, first picture at 4.3 s; 0 freezes in 150 s |
| European sports | HEVC Main SDR, HE-AAC | none | moved at 0.6 s, first picture at 3.9 s; 0 freezes in 150 s |
| Sports (PQ, Atmos) | HEVC Main 10 PQ, E-AC-3 5.1 Atmos | the playlist was refused (403) twice at 44 s and twice at 91 s | moved at 0.7 s, first picture at 3.4 s; 0 freezes in 150 s, the refusals retried within the connection, 19–21 s buffered throughout |
| Italian | HEVC Main 10, HLG by SEI, four slices per picture, open GOP; E-AC-3 5.1 (Italian) | none | moved at 0.6 s, first picture at 4.9 s; 0 freezes in 120 s; published as HLG |
| French | HEVC Main 10 PQ, E-AC-3 stereo (French) | none | moved at 0.7 s, first picture at 3.4 s; 0 freezes in 120 s |
| Travel | HEVC Main BT.2020 SDR at 25 fps, two AAC tracks (Russian, English) | its HLS output dropped 0.28 s and 1.09 s, 30–37 s in | moved at 0.6 s; back to MPEG-TS at 37 s after the second gap, 0 freezes; both gaps closed up, and MPEG-TS carried the rest whole |

In every run the video and audio decode times ran on unbroken from fragment to fragment, the playlists carried the right `CODECS`, `VIDEO-RANGE`, `FRAME-RATE`, languages and channel counts, and the renditions decoded without errors, but for one missing-reference error on the travel channel where its HLS output had dropped programme. ffmpeg's own recording of the Italian channel started at an open-GOP keyframe and skipped its leading pictures, as a decoder must, logging "first slice in a frame missing" for the other three slices of each; the engine marks those pictures as leading in the fMP4, and its output for that channel decodes cleanly.

Before the last changes the same channels went quite differently. With fMP4 publishing alone, on the MPEG-TS route, the two lossy channels held a frozen picture for 18–20 s of every 2 minutes (a gap every 5–10 s), their audio decode times broke at gaps, and ffmpeg found corrupt slices where the panel had split a picture. Closing gaps and leaving a lossy route mid-stream helped, but each move froze the picture for 3–12 s: HLS ingest joined at least three segments back, 10–16 s with these 4–5 s segments, all of it already played, while the drops had thinned the reserve. Moving before the first picture, joining at the newest segment on a later move, and treating the other route as the same clock fixed that. Playing three 4K channels at once also exceeded the account's four connections (its HLS sessions and recently closed MPEG-TS ones count too), and the panel refused the third with "account in use"; a viewer watches one channel, but that's why these runs went one at a time.

### Event channels

Matched sources for a game usually point at per-event channels (the account has them for NBA, NFL, NHL and MLB games, ESPN+, FloSports, DAZN and pay-per-view, named after the event and its start time). These were probed and played the same way, while US games were on:

- live event channels with viewers answered in under a second and started through the engine in 2–4 s, H.264 1080p or 720p with AAC, 0 freezes;
- of 28 random sports and event channels, 21 were H.264, 1 HEVC, 5 answered 502 or 503 (off the air), and 1 sent nothing for 6 s;
- event channels nobody else is watching are started by the panel on demand, and most random ones were cold. Their MPEG-TS output either answered with its first bytes after 7.1–7.9 s, or was refused with 502 after 8.4–8.8 s, after which the HLS output answered 1–8 s later with a window of one 4 s segment;
- a channel that can't be started is refused with 502 after the panel tries for about 10 s, then with 503 and 888 to repeated requests.

So event channels start slowly whatever plays them, and the engine made it worse in two ways. It dropped the first route after 6 s of silence, before a cold source came up on it, which left every cold channel on the one-segment HLS window. It also retried 502s and silence like network blips (two tries per route and at least 10 s), then handed the URL to AVPlayer for another try, so a channel off the air spun for 13–45 s before the viewer saw a generic error. The first route now gets 8 s to answer and 12 s once it has, and a channel off the air is reported as such, without AVPlayer. The old engine (as on `main` before this change) and the new one were run alternately on fresh channels, each cold channel played once:

| Channel | Old engine | New engine |
| --- | --- | --- |
| Fake panel: 502 on both outputs | gave up at 11 s, then AVPlayer tried | "isn't broadcasting right now" at 3.5 s |
| Fake panel: 503, single route | 11.8 s, then AVPlayer | 2.0 s |
| Fake panel: answers, then nothing on both outputs | 38.5 s in the engine; the app's 30 s watchdog handed it to AVPlayer first | 24 s, off the air |
| Fake panel: source needs 7.3 s to start | MPEG-TS dropped at 6 s, played from HLS at 7.4 s | 8.9 s from MPEG-TS |
| Live: cold channels | MPEG-TS dropped at 6 s every time; first picture from HLS at 11.3, 12.3, 12.3 and 16.3 s, then a 1.5–2 s freeze | MPEG-TS answering within 8 s: 9.8 and 11.0 s from MPEG-TS; unanswered at 8 s: 16.8 s from HLS, then a 2 s freeze |
| Live: a channel off the air | gave up at 10.7 s ("didn't start"), then AVPlayer tried | "isn't broadcasting right now" at 10.9–19.6 s, as fast as the panel refuses |
| Live: event channels with viewers | 2–4 s | 2.0–4.3 s |

## Not verified and limitations

- **AVPlayer on device.** Not run on iOS, tvOS or macOS. Unverified: how AVPlayer honours `EXT-X-START` when an item is rebuilt, rate changes below 1.0x with time-domain pitch on live HLS, behaviour at `EXT-X-DISCONTINUITY` after a codec change, and whether any provider stream triggers decoder errors that the synthetic and ffmpeg fixtures don't. Reports from projects serving live HLS to AVPlayer on devices say it fails a live playlist that stays unchanged for 1.5 target durations (-12888) and expects about three target durations between its position and the live end; the engine keeps its playlist changing, including before AVPlayer starts, but its lead (6 s, 1.5 target durations) is shorter than that. Watch the diagnostics journal for "Player item rebuilt" on real channels.
- **Programme lost at a splice.** After a drop on a raw TS connection nothing is lost when the reconnect re-sends the last keyframe within 6 s and at least 5.5 s was ahead of the picture. In the live runs that covered every drop once the reserve had built up. Otherwise (a thin reserve soon after tune-in, or a provider that doesn't re-send), the reconnect must still join at a keyframe, so up to one GOP after the last delivered picture can be skipped (0–0.6 s in the runs above). The timeline is closed up, so this is a small jump in the programme, not a freeze. HLS ingest loses nothing while the next segment is still in the provider's window.
- **Thin reserve, coarse playlist.** The local playlist's target duration is 4 s, so that 4 s GOPs can be cut at keyframes, and AVPlayer reloads a live playlist only that often. With the reserve empty (a line slower than real time, or straight after a long outage), the segment still being cut and the time to the next reload leave the player a few seconds short of what the engine holds. A slow line therefore freezes briefly every 20 s or so (the 90 % line above) instead of playing to the end of the buffer. A target duration chosen from the source's GOP (2 s for 2 s GOPs) would roughly halve that gap; it needs testing with AVPlayer first.
- **4K on device.** The fMP4 renditions were checked with ffmpeg (as an HLS client and as a decoder) and MP4Box, not with AVPlayer. Unverified: that AVPlayer accepts them as written (HDR10 and HLG signalling, `hvc1` with SEI left in the samples, E-AC-3), and that a given device decodes 4K HEVC at 50 fps smoothly (Apple TV 4K and recent iPhones and iPads should; older devices can't).
- **Dolby Atmos.** E-AC-3 carrying Atmos (JOC) is published as plain `ec-3` 5.1, so decoders play the 5.1 bed; the Atmos objects would need the JOC extension in `dec3` and `CHANNELS="16/JOC"` on the rendition, which aren't written.
- **Codec changes mid-stream.** H.264 → HEVC rebuilds the player item on the fMP4 renditions and skips the MPEG-TS programme it hadn't played; HEVC → H.264 carries on behind a discontinuity with the multivariant playlist's `CODECS` unchanged. A picture format change between keyframes inside one segment reaches the decoder as in-band parameter sets until the next segment.
- **Cold event channels** take the panel 8–17 s to start, and most then froze once for 1.5–2 s shortly after their first picture: the panel's first HLS window holds a single 4 s segment, and a source that has just started delivers unevenly (one froze for 7.6 s while the panel restarted its connection). Waiting for a second segment would avoid the freeze at the cost of another 4 s before the picture. Off-air verdicts take as long as the panel takes to refuse, about 10 s per output on the live panel.
- **Dropped programme.** Closing a gap keeps the picture moving, but the programme in it is gone, and it comes out of the reserve: the timeline runs that much short of real time, which the pace controller makes up by playing slightly slow. On streams with reordered (B) pictures a gap closes up to the last picture already shown, so up to about 0.2 s of it can still hold; with packets missing after it, the picture just before a gap is dropped too. A route that keeps dropping programme is left for one that doesn't, when there is one; with a single route, a source that drops 15 % of its programme is watchable but visibly jumpy.
- **Moving to another route** costs the reserve whatever the new route takes to bring programme the old one hadn't: its first answer, then its segments. On the live panel the HLS output ran ahead of the MPEG-TS output that was dropping programme, so the move was quick; when the new route's live end isn't ahead and the reserve is already thin, the picture can freeze briefly at the move.
- **Corrupt pictures from the provider** are passed through untouched, as in MPEG-TS (see the 4K runs above).
- **Reserve depth comes from the provider.** The engine can't download the future: the reserve is what the provider bursts or keeps in its HLS window, plus about 0.5 s a minute while trickling at 0.992x. An outage longer than the reserve freezes once (holding until a few seconds are rebuilt), then resumes.
- **One connection at a time.** No make-before-break: many IPTV accounts allow a single stream, and a second connection would get the first one dropped.
- **Single rendition.** No automatic quality step-down; real bitrate ladders, encrypted, fMP4 and byte-range HLS go to AVPlayer directly.
- **AirPlay video** plays the provider URL directly, without the engine.
