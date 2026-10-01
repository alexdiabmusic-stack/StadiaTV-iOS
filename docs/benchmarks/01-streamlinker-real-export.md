# StreamLinker vs. a real Xtream export

Measured 2026-09-30 with `swift run -c release linker-cli` (see `MatchLinker/README.md` for the
tool) against a real user's Xtream export (not committed — exports are gitignored). This is the
`StreamLinker` engine itself, run standalone outside the app; it is the same code the app links
against from `MyApp/Matching/StreamLinker.swift`.

## Export shape

| | |
|---|---|
| Channels | 22,300, in 464 categories |
| Guide channels | 9,553 total (2,608 with an empty id); 4,735 used by at least one playlist channel |
| Guide window fed to the linker (now-6h to now+72h) | 55,675 programmes |
| Games in the next ~72h (`events.json`) | 74, across 9 competitions |

## Index build / link time

```
index: 22300 streams, 4735 guide channels, 55675 programmes, 1075710 postings, ~10.1 MB
build:  CPU best 129 ms (median 129) | wall best 131 ms   [1 run]
  first-round slowest (cold caches, CPU): 44.28 ms  Sri Lanka at Seychelles   (national-team table build, once)
  first-round slowest (cold caches, CPU): 0.69 ms   Tahiti at Cook Islands
```

129 ms build is well inside the 1.5 s budget (`StreamLinkerBudgetTests`); the one expensive link
(44 ms) is the national-team country-name table building itself once, exactly as documented in
`MatchLinker/README.md`'s Performance section — every link after that is sub-millisecond.

## Coverage (confidence >= 0.7)

| League | Confident / total |
|---|---|
| football/nfl | 1/1 |
| baseball/mlb | 8/10 |
| hockey/nhl | 11/16 |
| basketball/wnba | 2/5 |
| football/college-football | 1/5 |
| soccer/usa.1 (MLS) | 1/2 |
| soccer/fifa.friendly | 1/15 |
| soccer/uefa.nations | 1/18 |
| soccer/usa.nwsl | 0/2 |
| **Total** | **26/74** |

The low friendly/Nations League numbers track the export's own guide-horizon data (most guide
ids only reach 12-24h ahead; the no-option games above are mostly 24-48h+ out at export time),
not a matching defect — see `MatchesView`'s "Listings appear closer to kickoff" vs. "No listing
in your playlist's guide" distinction (Prompt 7 step 4).

## Known gap

This run exercises `StreamLinker` directly via `linker-cli`, not the full in-app pipeline
(`XtreamProviderAdapter` -> `EPGRepository` -> `MatchLinkService` -> `StreamAvailabilityStore`).
`GuideBenchmark.swift`'s `-guideBenchmark` DEBUG launch mode now accepts this same export format
(Prompt 1), but running it end-to-end in the simulator needs a way to pass that launch argument
through Xcode tooling that wasn't available in the environment this was built in. Until that's
run, app-side parity with the linker-cli numbers above is not independently confirmed — only the
engine itself is.
