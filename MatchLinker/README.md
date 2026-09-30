# MatchLinker

Start with [PROMPTS.md](PROMPTS.md): nine prompts in run order (the guide, grid and connection-limit fixes as well as the linker), with the measurements and code references an agent needs. Put this whole folder in the repo root first, because the prompts read the code from it.

Links a sports match to every stream in the user's playlist that carries it, using only data the playlist already sends: its own XMLTV guide, its channel names, and (as support) the broadcaster list from the sports-data API. Foundation only. No network, no app types, no global state beyond a lock-guarded Unicode cache.

```
LinkerEvent    (teams, kickoff, API broadcasters) ─┐
LinkerStream[] (name, category, guide id)  ────────┼─▶  StreamLinker.link(event) ─▶ [LinkedFeed]   ranked, mirrors included
LinkerProgramme[] (the playlist's XMLTV)  ─────────┘
```

## What it does on a real playlist

Measured on 29 Sep 2026 against one real Xtream playlist (22,304 channels, 115,388 programmes in a 60-hour guide window) and the real games for the next 48 hours from public sports feeds.

| | |
|---|---|
| Games in the next 48 hours | 53 (11 competitions) |
| With at least one confident stream (confidence 0.7 or higher) | 36 |
| With three or more different broadcasters | 13 |
| With only "likely" options (channel guide ends before kickoff) | 1 |
| With nothing: no programme in the guide names the game, checked by searching the raw guide | 16 |
| In the 12 leagues the app shows today (NHL, MLB, WNBA, MLS in this window) | 19 of 21 confident |
| Previous three days: 208 games | 129 confident |
| Previous three days: games without a confident stream whose guide lists both teams | 0 of 79 |
| Python reference and Swift agree | 261 of 261 games, identical feeds, tiers, confidences, streams and order |
| Index build / link one game | 0.22 s / 0.26 ms median (see Performance) |

## How it decides

Six readers, each with a fixed confidence. A stream keeps the highest confidence it earns.

| Tier | Evidence | Confidence | Real example |
|---|---|---|---|
| T1 | The guide title names both teams around a separator (`vs`, `v`, `at`, `@`, `-`, `x`, `c.`), at kickoff, in any language or script | 0.97 with a Live badge, 0.92 without, 0.8 if the title has several separators, 0.75 for a club-name variant | `NHL Hockey : Florida Panthers at Carolina Hurricanes ᴸᶦᵛᵉ`, `Spagna - Croazia ᴸᶦᵛᵉ`, `Ισπανία - Κροατία` |
| T2 | Generic title, the description names both teams by full name | 0.72 | `Hockey sur glace : NHL` with `Carolina Hurricanes v Florida Panthers …` |
| T3 | A team channel whose guide says `Next Game: A @ B on <date>`, or a channel named after a participant | 0.62 / 0.5 | `US ★ MLB TEAMS : Boston Red Sox HD` |
| T4 | The channel name carries the fixture and a kickoff time that agrees in the zone the name states | 0.85 (0.5 with no time) | `US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET` |
| T5 | The sports API names the network, same country, and the channel's own guide does not show another programme at kickoff | 0.6 | TNT for Kings at Avalanche when TNT's guide ends before kickoff |
| T6 | A studio or in-game show about the game | 0.35 | `Boston Red Sox vs. New York Yankees MLB Baseball Playoffs In-Game Live` |

Treat confidence 0.7 or higher (T1, T2 and T4) as real options and put T3, T5 and T6 under "more options". Confidence is a rule-based score, not a probability.

Rejected outright: placeholders (`No Game Today`, `Next Game` blocks naming another fixture, `TBA`), replays, classics, highlights and recaps, programme blocks longer than 6 hours.

Why it works on real providers:

- **Title first.** Only the title decides a fixture. A description such as "…in a game at Lenovo Center" used to add a second `at` and break a correct match.
- **Team identity comes from the sports data** (`name`, `short`, `nick`, `city`), never from a bare place word. `Louis` and `York` are not aliases.
- **Name variants.** Connector words are optional (`Atlético de San Luis` = `Atlético San Luis`). A fuzzy fallback reads `Celta B - Sabadell` for `RC Celta Fortuna` at `CD Sabadell`.
- **National teams in every language.** Country names come from the OS locale database (41 locales, including Greek, Cyrillic, Arabic and CJK), built on first use.
- **Superscript badges** such as `ᴸᶦᵛᵉ` and `ᴺᵉʷ` are read as text (NFKD), not treated as noise.
- **Names that change during the day.** Event-slot channel names must carry a kickoff time that agrees with the game. A stale name from another game does not match.
- **Schedule horizons.** A channel whose guide ends before kickoff is not treated as contradicting a broadcast-partner hint.
- **Regions.** A rights hint only applies to the same country's network (TNT US, not TNT Spain).

## Public API

```swift
let linker = StreamLinker(streams: streams, programmes: programmes)   // build once per playlist or guide refresh, off the main thread
let feeds  = linker.link(event)                                       // ranked [LinkedFeed], best first; thread-safe
let rows   = feeds.groupedByFamily()                                  // collapse look-alike feeds (a dozen local affiliates) for the UI
print(linker.stats)                                                   // sizes, for logs and budgets
```

`LinkedFeed`: `key`, `tier`, `confidence`, `label`, `region`, `language`, `displayName`, `family`, `streamIDs` (mirrors, best quality first), `evidence` (the guide line or channel name that earned it), `programmeTitle`.

`LinkerEvent`: `id`, `league`, `kickoff`, `home`, `away` (`LinkerTeam`: `name`, `short`, `nick`, `city`, `abbr`), `broadcasts` (network names from the sports API), `isNational` (true for national-team competitions).

`LinkerStream`: `id`, `name`, `category`, `guideID` (the Xtream `epg_channel_id` or M3U `tvg-id`).
`LinkerProgramme`: `guideID` (the raw XMLTV `channel` attribute), `start`, `end`, `title`, `desc`.

The guide id on a stream and on its programmes must be the raw id from the playlist and the XMLTV file. Comparison is case-insensitive.

## Integration checklist

1. **Isolation.** The app target defaults to MainActor isolation. Every declaration in `StreamLinker.swift` is marked `nonisolated`. Keep it that way. The tests run under the same settings (Swift 5 mode, default MainActor isolation), and the file also type-checks in Swift 6 mode.
2. **Naming.** Internal helpers carry a `Linker` prefix so nothing in the file shadows SwiftUI's `Text` or any app type.
3. **Threading.** `StreamLinker` is immutable after `init` and `Sendable`. Build it on a background task, hold it in an actor, and rebuild when the playlist or the guide changes.
4. **Input.** Give it the raw XMLTV programmes for roughly now-6h to now+54h. The linker keeps your `[LinkerProgramme]` array (no copy) and indexes it. Programmes whose guide id no playlist channel uses are skipped.
5. **Adapters** (write these in the app target):

| From | To | Notes |
|---|---|---|
| `Match` | `LinkerEvent` | `league = match.league.path`, `kickoff = match.date`, `broadcasts = match.broadcasts`, `isNational` for national-team competitions |
| `TeamSide` | `LinkerTeam` | `name = displayName`, `short = shortName`, `nick = shortName`, `abbr = abbreviation`; add `city` when the provider has it |
| `Channel` | `LinkerStream` | `category = group title`, `guideID = epg_channel_id / tvg-id` |
| programme | `LinkerProgramme` | `guideID = raw XMLTV channel attribute` |

## Performance

Apple-silicon Mac, Release build, single thread, on the real playlist.

| Measure | Result |
|---|---|
| Index build: 22,304 channels, 115,388 programmes (60-hour window) | 0.22 s, best of 8 runs |
| Index build: 22,304 channels, 255,784 programmes (3 days) | about 0.5 s |
| Index memory | about 16 MB for 60 hours (30 MB for 3 days). Programme text stays in your array. |
| Link one game | median 0.26 ms, 95th percentile 0.73 ms, slowest 1.1 ms |
| First national-team game | plus about 45 ms, once (builds the country-name table) |

The runs were taken while other processes were also busy on the Mac, so a quiet machine is faster.

A phone is slower. The build runs once per guide refresh, so run it at `.utility` priority off the main thread. The first national-team game also builds the country-name table (about 50 ms, once).

## Run it

```bash
swift test                                                   # 12 golden tests from real titles
swift run -c release linker-cli DIR guide.json events.json out.json
```

`DIR` holds `streams.json` and `cats.json` (Xtream `get_live_streams` and `get_live_categories`). `guide.json` is a window of programmes as `[guideID, startUnix, endUnix, title, desc]` rows. `Scripts/` has the exporters. They read the host, user and password from environment variables. Never commit exported playlist data or credentials.

`Reference/` is the same rules in Python. `run_reference.py` and `compare_results.py` check the Swift against it.

## Extending

- **Networks.** `StreamLinker.networks` maps the sports API's broadcaster names to playlist network keys, and `networkRegion` gates them by country. It covers ESPN, TNT, truTV, Sportsnet, TVA Sports, TSN, CNBC, USA, FS1/FS2, MSG and a few more. Add your other regions there.
- **Aliases.** `LinkerAliases.of` builds a team's names from `name`, `short`, `nick` and `city + nick`. Generic words (`fc`, `united`, `city`, `real`…) never stand alone.
- **Connector words.** `LinkerText.connectors`.

## Limits

- Checked against one provider. Title formats differ between providers.
- A confident option means the guide says the game is on that channel. It does not mean the stream is up.
- The linker cannot find a game the guide does not mention. Pay-per-view and event slots that a provider assigns late are found when their name changes (see the event-channel refresh prompt).
