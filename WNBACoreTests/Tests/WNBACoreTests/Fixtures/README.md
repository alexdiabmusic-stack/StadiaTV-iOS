# WNBA fixture provenance

Every file in this directory is **hand-constructed**, not captured from a live
WNBA response — `cdn.wnba.com` was unreachable from the network this
integration was built on (Akamai bot-detection served the WordPress homepage
instead of JSON; see WNBA-INTEGRATION.md). These fixtures prove the mappers
and reducer obey their own contracts; they do **not** prove the wire format
matches WNBA's actual live responses. Wire-format fidelity is unverified
pending a live check from a network that can reach `cdn.wnba.com`.

Field vocabulary was derived from the WNBA integration brief's own explicit
field list (Step 4/9/12) plus the already-shipped, structurally-identical NBA
mapper/DTO code — not guessed independently. Same disclosure convention as
`NBACoreTests/Tests/NBACoreTests/Fixtures/README.md`.

| File | Covers |
| --- | --- |
| `scoreboard-live-q1.constructed.json` | Live Q1, in-game leaders, broadcasts |
| `scoreboard-scheduled.constructed.json` | Scheduled/pregame, no score yet |
| `scoreboard-halftime.constructed.json` | Halftime status text |
| `scoreboard-live-q4-underminute.constructed.json` | Live Q4, sub-minute clock (`PT00M29.80S`), bonus |
| `scoreboard-playoff.constructed.json` | Playoff series context: `gameLabel`, `seriesGameNumber`, `seriesText` |
| `boxscore-live.constructed.json` | Starters/bench/DNP, on-court lineup, team+player stats |
| `boxscore-final-ot.constructed.json` | Final after exactly one overtime |
| `boxscore-final-2ot.constructed.json` | Final after two overtimes — no hardcoded OT ceiling |
| `playbyplay-live.constructed.json` | Made FG, made 3PT, missed 3PT, free throw, rebound, turnover, steal, block, technical foul, timeout, substitution, jump ball, period start/end, and one deliberately-unrecognized `actionType` ("video_review") to prove `.unknown(_)` never drops an event |
| `schedule-cdn.constructed.json` | Current-season schedule, one final + one scheduled game |

No fixture is loaded by the app itself. Tests require no WNBA server.
