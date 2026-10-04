# StadiaTV implementation progress review

Reviewed September 5, 2026, against staged and unstaged changes in `/Users/alexdiab/Downloads/StadiaTV-iOS`. HEAD at review: `4c50510`. This is an in-progress review, not a release approval. No app files were changed by this review.

The metadata plumbing is improving, but event matching is not yet corrected. Several old false positives remain, and the newly introduced guide label can incorrectly imply programme confirmation.

## P1 — An unrelated programme can receive “Guide Match”

At [MatchDetailView.swift:208](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/MatchDetailView.swift:208), `join.titleSimilarity >= 0.25 || join.networkMatches` promotes a candidate to `guideListsMatch`. The same condition exists on tvOS. The [EPG join](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/EPGRepository.swift:754) also admits any programme on a matching network, including unrelated programming and pre/post-show windows with no actual event overlap.

**Reproduced:** using the actual programme-join method and the UI promotion predicate, an ESPN programme titled “SportsCenter” with zero title similarity to Celtics–Nuggets qualified for the guide-match label. This was a controlled fixture, not an observed live guide listing.

**Fix:** use network identity only to nominate candidates. Promotion requires sufficiently specific event/session identity and appropriate temporal/coverage evidence. A 25% title overlap against either individual team name is also too weak to prove both teams or distinguish a replay/highlights show. Read subtitle/description and preserve uncertainty.

## P1 — Original false-positive scoring remains

[SourceMatcher.swift:41](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/SourceMatcher.swift:41) still accepts any significant token as a team hit, adds the both-team bonus for shared city tokens, matches networks by substring and permits NBA inside WNBA. New evidence labels describe those same weak signals rather than validating them.

**Reproduced with current Swift matcher and supplied catalog:**

| Controlled case | Current result |
|---|---|
| NFL / FOX | FOX News 110; FOX Business 110; FOX Sports 1 110 |
| NBA | WNBA TV 99; TNT 75 |
| Lakers–Clippers | ABC Los Angeles 255; actual sample includes CBS News Los Angeles at 185 |
| F1 | Sky Sports F1 117; ESPN F1 117; Apple TV F1 47; TSN1 absent from the controlled results |

**Fix:** independent participant identities, exact/scoped network identity, competition conflicts and evidence-tier sorting. `teamNameMatch` is currently added for a single team hit, although its description says both teams and its badge says “Teams Listed.” Keep these claims appropriately limited.

## P1 — EPG integration decorates old results instead of determining them

[MatchDetailView.swift:205](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/MatchDetailView.swift:205) maps guide metadata only onto sources already returned by `SourceMatcher`, then takes the first 30 without sorting by the new evidence. tvOS does the same with 20.

**Impact:** an exact EPG match cannot introduce a feed that failed the old name threshold, and an EPG-supported source below the cutoff can remain hidden behind weak name matches. The new F1 guide path therefore cannot rescue TSN1 when the ranker omits it.

The [task key](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/MatchDetailView.swift:161) tracks channel count and language only. Programme loading/completion, EPG revision, same-count channel replacement, schedule/status changes and canonical-map completion do not trigger this ranking pass. `programmesNear` reads the current index without requesting missing windows. A cold guide can remain unenriched until the user reopens the screen or another tracked value changes.

**Fix:** generate candidates from programme assignments as well as names, sort by validated evidence before truncation, and rerun on event/catalog/identity/guide revisions. Publish pending enrichment and guard against obsolete task results. Share that service with player and fantasy surfaces, which still call the old matcher directly.

## P1 — Canonical match identity is stored but not used consistently

The new `canonicalID` and `broadcastDetails` fields are populated in `toLegacyMatch`, which is useful. However, [canonicalGameID(for:)](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/SportsData/SportsDataPlatform.swift:1838) still ignores `match.canonicalID` and guesses the provider from the league. The match's new broadcast details are likewise not consumed by ranking.

Additionally, [withLiveContext](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/Models.swift:531) and `withBroadcasts` construct a fresh `Match` without copying the new fields, resetting them to defaults. The enrichment pipeline calls `withLiveContext`, so it loses the newly preserved identity again.

**Fix:** route using the preserved qualified ID and preserve new metadata through every copying/transformation helper. Player canonical fallback is improved, but `PlayerDetailView` still attempts the bare athlete ID against ESPN first and accepts nonempty stats without verifying identity. The stats cache still omits date/season scope.

## P1 — Rights metadata is largely decorative and key packages remain missing

[activeBroadcasters](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/BroadcastRightsPolicy.swift:76) never evaluates `countries` and returns only flattened strings, discarding their scope. [SourceMatcher](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/SourceMatcher.swift:256) does not pass the event date, so validity is evaluated against today. Unknown racing sessions accept all session-restricted entries. Live versus highlights is not represented.

The registry still omits explicit rules for 14 of the 43 configured leagues: WNBA, NWSL, CFL, UFL, G League, NBL, college football, men's and women's college basketball, college baseball, WBC, men's and women's college hockey, and NHRA. Saudi is now correctly keyed.

The NBA entry retains TNT and lacks NBC/Peacock/Prime, despite the current national package. [NBA source](https://pr.nba.com/nba-walt-disney-company-nbcuniversal-amazon-prime-video-media-agreements/). F1 still uses ESPN session assumptions and lacks Apple TV's current US package. [Apple source](https://www.apple.com/newsroom/2026/03/formula-1-begins-this-weekend-exclusively-on-apple-tv-in-the-us/).

**Fix:** preserve structured records through scoring and compare rights territory with the candidate feed's territory, while continuing to consider all markets for all users. Use event/edition validity, explicit unknown states, live/highlight scope and source verification. Expanding the registry to additional leagues does not replace completing the app's existing supported league policies.

## P2 — Stream availability counts never clear

[StreamAvailabilityStore.swift:34](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/StreamAvailabilityStore.swift:34) saves only positive results and merges them into old counts. An empty catalog returns before clearing anything.

**Reproduced with the actual store:** one FOX candidate gives count 1; replacing it with a nonmatching Cooking Channel still gives 1; removing all channels still gives 1.

**Fix:** write explicit zero results for evaluated events, clear invalid catalog entries and version results by event/catalog/preferences. Use generation checks so an older concurrent scan cannot restore stale counts. Count-based task keys in the root views also miss same-size event/catalog replacements. The displayed count currently counts all heuristic candidates, not confirmed event streams; name it accordingly or count validated results.

## P2 — Canonical market validation compares cities with country codes

At [CanonicalChannelMatcher.swift:254](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/CanonicalChannelMatcher.swift:254), the last part of a `network|market` key is treated as a country. The actual curated data contains values such as `CBC|Toronto`, with a separate country `CA`. Comparing `TORONTO` to `CA` rejects a correct-country candidate whenever matching reaches this fallback.

Collision handling also returns a sole candidate before checking country conflicts; if no country candidates agree, it retains the original set and chooses by priority. Fuzzy index construction keeps `keys.first`, and fuzzy results bypass conflict resolution. Ambiguous results continue into canonical feed grouping.

**Fix:** compare against the curated `country` property, resolve city/affiliate market separately, validate single-candidate paths too, and keep unresolved identity separate from confirmed canonical grouping. Retain all candidate keys during fuzzy matching.

## P2 — Removing the NBA date cap creates an unbounded request sequence

The actual helper now returns 365 days for a 365-day range, fixing truncation. But [schedule(for:range:)](/Users/alexdiab/Downloads/StadiaTV-iOS/MyApp/SportsData/NBAProvider.swift:37) still awaits one scoreboard request for each date. A full-year search can now issue 365 sequential requests before returning; a later error discards the accumulated result and invokes fallback.

**Fix:** use a season/range schedule endpoint when available, or bounded chunking, cancellation, caching, request budgets and explicit partial coverage. Verify that consumers do not request a year of daily stats calls on a routine navigation path.

## Positive progress and validation limits

- Reproduced NBA scheduled status now returns `scheduled`, and date expansion returns the requested 365 days.
- Provider EPG IDs reach the guide builder through `Channel.tvgId` and `LiveChannel.asChannel`.
- Slot/date/language metadata is extracted before normalization, and unmatched visible streams are retained.
- Canonical aliases now store candidate sets, and tvOS ranking moved out of the computed view property.
- New canonical and broadcast fields are a useful start, though their consumers/copying paths need completion.

I compiled and ran the current SourceMatcher and BroadcastRightsPolicy with minimal model stubs against all 23,693 sample rows for 43 league cases and six focused scenarios. I also ran extracted production NBA and EPG logic plus the actual shared availability store with controlled fixtures. These isolate the demonstrated behaviours; they are not full app, UI, network or playback tests. Core reviewed file hashes were unchanged at the recheck. No full Xcode build was performed, and the current diff adds no regression tests for these matching changes.

Recommended next step: fix false guide confirmation, participant/network identity and EPG-driven candidate/ranking behavior before extending availability badges to more screens. Add the reproduced cases as automated regressions, then finish ID propagation, cache invalidation and scoped rights policies.
