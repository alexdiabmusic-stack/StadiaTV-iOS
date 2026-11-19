package com.nuvio.app.features.recommendations

import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.watchedItemKeys
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The spec's ten scenarios, run through the real builder against a small fake catalogue (no network).
 */
class RecommendationScenarioTest {
    private val today = "2026-11-19"
    private val now = 20_776L * DAY_MS // 2026-11-19

    // ------------------------------------------------------------------------------------------------ Fake world

    private class World {
        val titles = LinkedHashMap<String, TitleDetails>()
        val unavailable = HashSet<String>()
        var failures = 0

        fun add(
            id: Int, tv: Boolean, name: String, genres: List<Int>, release: String,
            votes: Int = 2000, average: Double = 7.6, popularity: Double = 30.0,
            cast: List<Person> = emptyList(), collection: Int? = null,
        ): TitleMeta {
            val m = TitleMeta(
                id, tv, name, genres, keywords = genres.map { it + 100_000 }, cast = cast, collectionId = collection,
                releaseDate = release, voteAverage = average, voteCount = votes, popularity = popularity,
                preview = MetaPreview(id = "tmdb:$id", type = if (tv) "series" else "movie", name = name, poster = "p$id", releaseInfo = release.take(4)),
            )
            titles[m.key] = TitleDetails(m, emptyList(), emptyList())
            return m
        }

        fun recommend(from: TitleMeta, to: List<TitleMeta>) {
            titles[from.key] = titles.getValue(from.key).copy(recommendations = to, similar = to.take(4))
        }

        val data = object : RecommendationData {
            override suspend fun tmdbId(appType: String, appId: String) = appId.removePrefix("tmdb:").toIntOrNull()
            override suspend fun details(tv: Boolean, tmdbId: Int) = titles[titleKey(tv, tmdbId)]
            override suspend fun discover(tv: Boolean, query: Map<String, String>): List<TitleMeta> {
                val genres = query["with_genres"]?.split(',', '|')?.mapNotNull { it.toIntOrNull() }
                val before = query["primary_release_date.lte"] ?: query["first_air_date.lte"]
                val minAverage = query["vote_average.gte"]?.toDoubleOrNull() ?: 0.0
                return titles.values.map { it.meta }.filter { m ->
                    m.tv == tv && (genres == null || m.genres.any { it in genres }) &&
                        (before == null || (m.releaseDate ?: "") <= before) && m.voteAverage >= minAverage
                }.sortedByDescending { it.popularity }.take(20)
            }
            override suspend fun personCredits(personId: Int) = PersonCredits(
                titles.values.map { it.meta }.filter { m -> m.cast.any { it.id == personId } }.map { m ->
                    PersonalRows.ActorCredit(m, m.cast.indexOfFirst { it.id == personId }, "Role", if (m.tv) 10 else null)
                },
                emptyList(),
            )
            override suspend fun movieCollection(id: Int): CollectionParts? {
                val parts = titles.values.map { it.meta }.filter { it.collectionId == id }.sortedBy { it.releaseDate }
                return if (parts.isEmpty()) null else CollectionParts("Saga $id", parts)
            }
            override suspend fun available(meta: TitleMeta) = meta.key !in unavailable
            override fun today() = "2026-11-19"
            override val failureCount: Int get() = failures
        }
    }

    private fun watchedFilm(m: TitleMeta, daysAgo: Int) = WatchedItem(id = "tmdb:${m.tmdbId}", type = "movie", name = m.name, markedAtEpochMs = now - daysAgo * DAY_MS)
    private fun watchedEpisodes(m: TitleMeta, count: Int, fromDaysAgo: Int, toDaysAgo: Int) = (1..count).map { ep ->
        val day = fromDaysAgo - (fromDaysAgo - toDaysAgo) * (ep - 1) / count.coerceAtLeast(1)
        WatchedItem(id = "tmdb:${m.tmdbId}", type = "series", name = m.name, season = 1, episode = ep, markedAtEpochMs = now - day * DAY_MS)
    }
    private fun saved(m: TitleMeta, daysAgo: Int?) = LibraryItem(
        id = "tmdb:${m.tmdbId}", type = if (m.tv) "series" else "movie", name = m.name,
        savedAtEpochMs = daysAgo?.let { now - it * DAY_MS } ?: 0L,
    )

    private val comedyLead = Person(5001, "Comedy Lead", 0)
    private val crimeLead = Person(5002, "Crime Lead", 0)
    private val heroLead = Person(5003, "Hero Lead", 0)

    /**
     * A broad history: comedy and crime series watched over the past year, sci-fi, romance and thrillers, then six
     * Marvel films logged in the last few days. Marvel candidates are the most popular titles in the catalogue and
     * every Marvel seed recommends all of them.
     */
    private fun broadWorld(): Triple<World, RecommendationInputs, UniverseDef> {
        val w = World()
        val comedyWatched = (1..4).map { w.add(1000 + it, true, "Comedy $it", listOf(35), "2018-01-0$it", cast = listOf(comedyLead)) }
        val crimeWatched = (1..3).map { w.add(1010 + it, true, "Crime $it", listOf(80, 18), "2017-02-0$it", cast = listOf(crimeLead)) }
        val scifiWatched = (1..3).map { w.add(1020 + it, false, "SciFi $it", listOf(878), "2016-03-0$it") }
        val romanceWatched = (1..2).map { w.add(1030 + it, false, "Romance $it", listOf(10749, 18), "2015-04-0$it") }
        val thrillerWatched = (1..2).map { w.add(1040 + it, false, "Thriller $it", listOf(53), "2019-05-0$it", collection = 7000 + it) }
        // Each thriller is the first of a three-film series (two more unseen parts).
        (1..2).forEach { s -> (2..3).forEach { part -> w.add(4000 + s * 10 + part, false, "Thriller Saga $s part $part", listOf(53), "202$part-05-01", collection = 7000 + s) } }
        val marvelWatched = (1..6).map { w.add(1100 + it, false, "Marvel $it", listOf(28, 12, 878), "201${it}-06-01", votes = 20000, popularity = 200.0, cast = listOf(heroLead), collection = 9000 + it % 2) }

        val comedy = (1..10).map { w.add(2000 + it, true, "New Comedy $it", listOf(35), "20${10 + it}-01-01", cast = listOf(comedyLead)) }
        val crime = (1..10).map { w.add(2010 + it, true, "New Crime $it", listOf(80, 18), "20${10 + it}-02-01", cast = listOf(crimeLead)) }
        val scifi = (1..10).map { w.add(2020 + it, false, "New SciFi $it", listOf(878), "20${10 + it}-03-01") }
        val romance = (1..10).map { w.add(2030 + it, false, "New Romance $it", listOf(10749, 18), "20${10 + it}-04-01") }
        val thriller = (1..10).map { w.add(2040 + it, false, "New Thriller $it", listOf(53), "20${10 + it}-05-01") }
        val marvel = (1..20).map { w.add(2100 + it, false, "More Marvel $it", listOf(28, 12, 878), "20${(5 + it).toString().padStart(2, '0')}-07-01", votes = 25000, popularity = 300.0, cast = listOf(heroLead), collection = 9000 + it % 3) }

        comedyWatched.forEach { w.recommend(it, comedy) }
        crimeWatched.forEach { w.recommend(it, crime) }
        scifiWatched.forEach { w.recommend(it, scifi) }
        romanceWatched.forEach { w.recommend(it, romance) }
        thrillerWatched.forEach { w.recommend(it, thriller) }
        marvelWatched.forEach { w.recommend(it, marvel) }

        val watched = comedyWatched.flatMap { watchedEpisodes(it, 12, 400, 150) } +
            crimeWatched.flatMap { watchedEpisodes(it, 8, 300, 130) } +
            scifiWatched.map { watchedFilm(it, 200) } + romanceWatched.map { watchedFilm(it, 180) } +
            thrillerWatched.map { watchedFilm(it, 60) } + marvelWatched.mapIndexed { i, m -> watchedFilm(m, 1 + i % 3) }
        val universe = UniverseDef("marvel", "Marvel", (marvelWatched + marvel).mapTo(HashSet()) { it.key }, emptySet())
        return Triple(w, RecommendationInputs(1, watched, emptySet(), emptyList(), emptyList()), universe)
    }

    private fun isMarvel(p: MetaPreview) = p.name.contains("Marvel")
    private fun group(p: MetaPreview) = p.name.substringAfter("New ").substringBefore(" ").let { if (isMarvel(p)) "Marvel" else it }

    // ------------------------------------------------------------------------------------------------ 1. Recent Marvel bias

    @Test
    fun test1_recentMarvelDoesNotDominate() = runTest {
        val (world, inputs, universe) = broadWorld()
        val state = RecommendationBuilder(world.data, listOf(universe)).build(inputs, now)
        val items = state.items.take(20)
        val marvel = items.count(::isMarvel)
        assertTrue(items.size >= 15, "expected a full row, got ${items.size}")
        assertTrue(marvel in 1..5, "Marvel should be present but at most ~25%: $marvel of ${items.size} ${items.map { it.name }}")
        assertTrue(items.map(::group).toSet().size >= 4, "genre variety: ${items.map(::group)}")
        assertTrue(state.isPersonal)
    }

    // ------------------------------------------------------------------------------------------------ 2. Forgotten watchlist

    @Test
    fun test2_forgottenWatchlistRanksByRelevanceNotAge() = runTest {
        val (world, base, universe) = broadWorld()
        val fitting = (1..3).map { world.add(3000 + it, true, "Saved Comedy $it", listOf(35), "2019-01-01") }
        val unrelated = (1..3).map { world.add(3010 + it, false, "Saved Horror $it", listOf(27), "2019-01-01", average = 6.0, votes = 300) }
        val recent = world.add(3021, true, "Saved Yesterday", listOf(35), "2019-01-01")
        // The unrelated titles were saved longest ago; age alone would put them first.
        val saved = fitting.map { saved(it, 60) } + unrelated.map { saved(it, 400) } + saved(recent, 3)
        val state = RecommendationBuilder(world.data, listOf(universe)).build(base.copy(saved = saved), now)
        val row = state.rows.firstOrNull { it.kind == PersonalRowKind.ForgottenWatchlist }
        assertTrue(row != null, "row should show: ${state.rows.map { it.kind }}")
        val names = row.items.map { it.name }
        assertFalse("Saved Yesterday" in names)
        assertTrue(names.indexOf("Saved Comedy 1").let { it in 0..2 }, names.toString())
        assertTrue(names.take(3).count { it.startsWith("Saved Comedy") } >= 2, names.toString())
        assertTrue(row.labels.values.any { it.startsWith("Saved") })
    }

    @Test
    fun test2b_unknownSaveDateIsEligibleButUnlabelled() {
        val m = TitleMeta(1, false, "Old", listOf(35), releaseDate = "2010-01-01")
        val e = ViewingEvidence(1, false, "Old", saved = true, savedAtEpochMs = null, lastActivityEpochMs = 0)
        val r = PersonalRows.forgottenWatchlist(listOf(e to m), TasteProfile.EMPTY, emptyMap(), now)
        assertEquals(1, r.eligible)
        assertEquals(null, r.ranked.single().label)
    }

    // ------------------------------------------------------------------------------------------------ 3. Favourite actors

    @Test
    fun test3_favouriteActorsSpreadAcrossActors() {
        val a = Person(1, "Actor A", 0)
        val b = Person(2, "Actor B", 0)
        val regular = Person(3, "Series Regular", 0)
        fun m(id: Int, cast: List<Person>, tv: Boolean = false, genres: List<Int> = listOf(18)) =
            TitleMeta(id, tv, "T$id", genres, cast = cast, releaseDate = "2015-01-01", voteAverage = 7.5, voteCount = 1000)
        val history = listOf(
            ViewingEvidence(1, false, "T1", finishedMovie = true, lastActivityEpochMs = now) to m(1, listOf(a)),
            ViewingEvidence(2, false, "T2", finishedMovie = true, lastActivityEpochMs = now) to m(2, listOf(a, b)),
            ViewingEvidence(3, false, "T3", finishedMovie = true, lastActivityEpochMs = now) to m(3, listOf(a, b)),
            ViewingEvidence(4, true, "T4", episodesWatched = 200, lastActivityEpochMs = now) to m(4, listOf(regular), tv = true),
        )
        val affinities = ActorAffinities.compute(history, now)
        assertEquals(setOf("Actor A", "Actor B"), affinities.map { it.person.name }.toSet())
        val credits = mapOf(
            1 to (10..17).map { PersonalRows.ActorCredit(m(it, listOf(a)), 0, "Lead", null) },
            2 to (20..25).map { PersonalRows.ActorCredit(m(it, listOf(b)), 1, "Lead", null) },
        )
        val row = PersonalRows.favouriteActors(affinities, credits, TasteProfile.EMPTY, setOf("movie:1", "movie:2", "movie:3"), today)
        val labels = row.ranked.take(8).mapNotNull { it.label }
        assertTrue(labels.any { it.contains("Actor A") } && labels.any { it.contains("Actor B") }, labels.toString())
    }

    @Test
    fun test3c_rowRotatesActorsAndCapsEach() {
        val actors = (1..4).map { Person(it, "Actor $it", 0) }
        fun m(id: Int, cast: List<Person>) = TitleMeta(id, false, "T$id", listOf(18), cast = cast, releaseDate = "2015-01-01", voteAverage = 7.5, voteCount = 1000)
        val affinities = actors.mapIndexed { i, p -> ActorAffinity(p, 10.0 - i, listOf("a", "b"), 1, setOf("g$i")) }
        val credits = actors.associate { p -> p.id to (1..8).map { PersonalRows.ActorCredit(m(p.id * 100 + it, listOf(p)), 0, "Lead", null) } }
        val row = PersonalRows.favouriteActors(affinities, credits, TasteProfile.EMPTY, emptySet(), today)
        val names = row.ranked.mapNotNull { it.label }
        assertEquals(listOf("With Actor 1", "With Actor 2", "With Actor 3", "With Actor 4"), names.take(4))
        assertTrue(names.groupingBy { it }.eachCount().values.all { it <= 3 })
        assertTrue(row.strength > 0)
    }

    @Test
    fun test3d_twoActorsAreNotEnoughForTheRow() {
        val actors = (1..2).map { Person(it, "Actor $it", 0) }
        fun m(id: Int) = TitleMeta(id, false, "T$id", listOf(18), releaseDate = "2015-01-01", voteAverage = 7.5, voteCount = 1000)
        val affinities = actors.map { ActorAffinity(it, 5.0, listOf("a", "b"), 1, setOf("g${it.id}")) }
        val credits = actors.associate { p -> p.id to (1..8).map { PersonalRows.ActorCredit(m(p.id * 100 + it), 0, "Lead", null) } }
        val row = PersonalRows.favouriteActors(affinities, credits, TasteProfile.EMPTY, emptySet(), today)
        assertEquals(0.0, row.strength)
        assertTrue(PersonalRows.coordinate(emptyList(), listOf(row)).rows.isEmpty())
    }

    @Test
    fun test3e_noMoreOfTheFranchiseTheActorIsKnownFrom() {
        val hero = Person(1, "Hero", 0)
        fun m(id: Int, collection: Int?) = TitleMeta(id, false, "T$id", listOf(28), collectionId = collection, releaseDate = "2015-01-01", voteAverage = 7.5, voteCount = 1000)
        val affinity = ActorAffinity(hero, 5.0, listOf("a", "b"), 1, setOf("coll:9"))
        val credits = mapOf(1 to listOf(PersonalRows.ActorCredit(m(10, 9), 0, "Lead", null), PersonalRows.ActorCredit(m(11, null), 0, "Lead", null)))
        val row = PersonalRows.favouriteActors(listOf(affinity), credits, TasteProfile.EMPTY, emptySet(), today, franchiseOf = { t -> t.collectionId?.let { "coll:$it" } })
        assertEquals(listOf("T11"), row.ranked.map { it.meta.name })
    }

    @Test
    fun test3b_cameosAndSelfAppearancesAreNotRoles() {
        val m = TitleMeta(1, false, "Doc", listOf(99), releaseDate = "2015-01-01", voteCount = 500)
        assertFalse(PersonalRows.isRealRole(PersonalRows.ActorCredit(m, 0, "Himself", null)))
        assertFalse(PersonalRows.isRealRole(PersonalRows.ActorCredit(m.copy(genres = listOf(18)), 30, "Bartender", null)))
        assertTrue(PersonalRows.isRealRole(PersonalRows.ActorCredit(m.copy(genres = listOf(18)), 1, "Detective", null)))
    }

    // ------------------------------------------------------------------------------------------------ 4. Franchise completion

    @Test
    fun test4_nextInstalmentInReleaseOrder() {
        val entries = (1..5).map { TitleMeta(it, false, "Part $it", listOf(28), releaseDate = "200$it-01-01", voteAverage = 7.0, voteCount = 1000) }
        val evidence = mapOf(
            "movie:1" to ViewingEvidence(1, false, "Part 1", finishedMovie = true, lastActivityEpochMs = now),
            "movie:2" to ViewingEvidence(2, false, "Part 2", finishedMovie = true, lastActivityEpochMs = now),
        )
        val r = PersonalRows.completeFranchise(listOf(FranchiseUnit("coll:1", "Saga", "coll:1", entries)), evidence, now)
        val pick = r.ranked.single()
        assertEquals("Part 3", pick.meta.name)
        assertEquals("Next in Saga · 2 of 5 watched", pick.label)
    }

    @Test
    fun test4b_oneUniverseCannotFillTheRow() {
        fun unit(n: Int, group: String): FranchiseUnit {
            val entries = (1..3).map { TitleMeta(n * 10 + it, false, "U$n-$it", listOf(28), releaseDate = "201$it-01-01") }
            return FranchiseUnit("coll:$n", "Unit $n", group, entries)
        }
        val units = (1..5).map { unit(it, "mcu") } + unit(6, "coll:6")
        val evidence = units.associate { u -> u.entries.first().key to ViewingEvidence(u.entries.first().tmdbId, false, "", finishedMovie = true, lastActivityEpochMs = now) }
        val r = PersonalRows.completeFranchise(units, evidence, now)
        val shown = r.ranked.take(3)
        assertTrue(shown.count { it.meta.name.startsWith("U6") } == 1, shown.map { it.meta.name }.toString())
    }

    @Test
    fun test4c_endToEndFromWatchHistory() = runTest {
        val (world, inputs, universe) = broadWorld()
        val state = RecommendationBuilder(world.data, listOf(universe)).build(inputs, now)
        val row = state.rows.firstOrNull { it.kind == PersonalRowKind.CompleteFranchise }
        assertTrue(row != null && row.items.isNotEmpty(), state.rows.map { it.kind }.toString())
        assertTrue(row.labels.values.all { it.startsWith("Next in ") })
    }

    // ------------------------------------------------------------------------------------------------ 5. Connected universe

    @Test
    fun test5_spinoffsComeFromTheVerifiedUniverseOnly() {
        val parent = TitleMeta(1, true, "Breaking Bad", listOf(80, 18), releaseDate = "2008-01-20", voteAverage = 8.9, voteCount = 15000)
        val prequel = TitleMeta(2, true, "Better Call Saul", listOf(80, 18), releaseDate = "2015-02-08", voteAverage = 8.7, voteCount = 5000)
        val film = TitleMeta(3, false, "El Camino", listOf(80, 18), releaseDate = "2019-10-11", voteAverage = 7.0, voteCount = 5000)
        val unrelated = TitleMeta(4, true, "Some Other Crime Show", listOf(80, 18), releaseDate = "2016-01-01", voteAverage = 8.0, voteCount = 9000)
        val evidence = mapOf(parent.key to ViewingEvidence(1, true, "Breaking Bad", episodesWatched = 62, seriesCompleted = true, lastActivityEpochMs = now))
        val r = PersonalRows.continueUniverse(listOf(UniverseUnit("breaking-bad", "Breaking Bad", listOf(parent, prequel, film))), evidence, TasteProfile.EMPTY, now, today)
        val names = r.ranked.map { it.meta.name }
        assertEquals(setOf("Better Call Saul", "El Camino"), names.toSet())
        assertFalse(unrelated.name in names)
        assertTrue(r.ranked.all { it.label == "From the Breaking Bad universe" })
    }

    @Test
    fun test5b_sequelsInAWatchedFilmSeriesAreLeftToCompleteTheFranchise() {
        val watched = TitleMeta(1, false, "Film 1", listOf(28), collectionId = 77, releaseDate = "2010-01-01")
        val sequel = TitleMeta(2, false, "Film 2", listOf(28), collectionId = 77, releaseDate = "2012-01-01")
        val series = TitleMeta(3, true, "Companion Series", listOf(10759), releaseDate = "2021-01-01", voteCount = 2000)
        val evidence = mapOf(watched.key to ViewingEvidence(1, false, "Film 1", finishedMovie = true, lastActivityEpochMs = now))
        val r = PersonalRows.continueUniverse(listOf(UniverseUnit("u", "U", listOf(watched, sequel, series))), evidence, TasteProfile.EMPTY, now, today)
        assertEquals(listOf("Companion Series"), r.ranked.map { it.meta.name })
    }

    // ------------------------------------------------------------------------------------------------ 6. Mixed history

    @Test
    fun test6_neitherFormatIsSuppressed() = runTest {
        val (world, inputs, universe) = broadWorld()
        val items = RecommendationBuilder(world.data, listOf(universe)).build(inputs, now).items.take(20)
        val series = items.count { it.type == "series" }
        assertTrue(series >= 3 && items.size - series >= 3, "films ${items.size - series}, series $series")
    }

    // ------------------------------------------------------------------------------------------------ 7. Sparse history

    @Test
    fun test7_noHistoryGetsTheFallbackAndNoBrokenRows() = runTest {
        val (world, _, universe) = broadWorld()
        val state = RecommendationBuilder(world.data, listOf(universe)).build(RecommendationInputs(9, emptyList(), emptySet(), emptyList(), emptyList()), now)
        assertFalse(state.isPersonal)
        assertTrue(state.loaded)
        assertTrue(state.rows.all { it.items.isNotEmpty() })
    }

    @Test
    fun test7b_oneTitleIsEnoughToStart() = runTest {
        val (world, _, universe) = broadWorld()
        val one = listOf(WatchedItem(id = "tmdb:1021", type = "movie", name = "SciFi 1", markedAtEpochMs = now - 3 * DAY_MS))
        val state = RecommendationBuilder(world.data, listOf(universe)).build(RecommendationInputs(9, one, emptySet(), emptyList(), emptyList()), now)
        assertTrue(state.items.isNotEmpty())
        assertTrue(state.rows.all { it.items.isNotEmpty() })
    }

    // ------------------------------------------------------------------------------------------------ 8. Profile isolation

    @Test
    fun test8_profilesAreBuiltIndependently() = runTest {
        val (world, inputs, universe) = broadWorld()
        val builder = RecommendationBuilder(world.data, listOf(universe))
        val comedyOnly = inputs.watched.filter { it.name.startsWith("Comedy") }
        val crimeOnly = inputs.watched.filter { it.name.startsWith("Crime") }
        val a = builder.build(RecommendationInputs(1, comedyOnly, emptySet(), emptyList(), emptyList()), now)
        val b = builder.build(RecommendationInputs(2, crimeOnly, emptySet(), emptyList(), emptyList()), now)
        assertEquals(1, a.profileId)
        assertEquals(2, b.profileId)
        assertTrue(a.items.take(5).all { "Comedy" in it.name }, a.items.map { it.name }.toString())
        assertTrue(b.items.take(5).all { "Crime" in it.name }, b.items.map { it.name }.toString())
        assertNotEquals(RecommendationEngine.signature(inputs), RecommendationEngine.signature(inputs.copy(watched = comedyOnly)))
    }

    @Test
    fun test8b_aFailedRefreshKeepsGoodRows() {
        val p = MetaPreview(id = "tmdb:1", type = "movie", name = "Kept")
        val old = RecommendationState(profileId = 1, items = listOf(p), rows = listOf(PersonalRow(PersonalRowKind.FavouriteActors, "x", listOf(p))), prominentRows = 1)
        val failed = RecommendationState(profileId = 1, items = emptyList(), rows = emptyList(), prominentRows = 0)
        val merged = RecommendationEngine.keepGood(old, failed)
        assertEquals(listOf(p), merged.items)
        assertEquals(1, merged.rows.size)
    }

    // ------------------------------------------------------------------------------------------------ 9. Cross-row duplication

    @Test
    fun test9_nearbyRowsDontRepeatTitles() {
        fun picks(range: IntRange) = range.map { RowPick(TitleMeta(it, false, "T$it", listOf(18)), 1.0 - it / 1000.0, null) }
        val main = picks(1..30)
        val rows = listOf(
            RowResult(PersonalRowKind.MightHaveMissed, picks(1..90), 0.8, 90),
            RowResult(PersonalRowKind.FavouriteActors, picks(10..80), 0.7, 70),
        )
        val plan = PersonalRows.coordinate(main, rows)
        val shown = plan.main.map { it.meta.key } + plan.rows.flatMap { r -> r.second.map { it.meta.key } }
        assertEquals(shown.size, shown.toSet().size, "a title shown twice")
    }

    @Test
    fun test9b_dedupeBackfillsRatherThanEmptyingARow() {
        fun picks(range: IntRange) = range.map { RowPick(TitleMeta(it, false, "T$it", listOf(18)), 1.0, null) }
        val plan = PersonalRows.coordinate(picks(1..20), listOf(RowResult(PersonalRowKind.MightHaveMissed, picks(1..8), 0.8, 8)))
        val missed = plan.rows.single { it.first == PersonalRowKind.MightHaveMissed }.second
        assertEquals(6, missed.size)
    }

    // ------------------------------------------------------------------------------------------------ 10. Empty eligibility

    @Test
    fun test10_rowsWithTooFewTitlesAreHidden() {
        val one = listOf(RowPick(TitleMeta(1, false, "Only", listOf(18)), 1.0, null))
        val plan = PersonalRows.coordinate(
            emptyList(),
            listOf(
                RowResult(PersonalRowKind.ForgottenWatchlist, one, 0.9, 1),
                RowResult(PersonalRowKind.FavouriteActors, emptyList(), 0.0, 0),
            ),
        )
        assertTrue(plan.rows.isEmpty())
        assertEquals(0, plan.prominent)
        assertTrue(plan.decisions.any { it.contains("hidden") })
    }

    @Test
    fun test10b_titlesThatCantBeWatchedAtHomeAreSkipped() = runTest {
        val (world, inputs, universe) = broadWorld()
        world.titles.values.filter { "New Comedy" in it.meta.name }.forEach { world.unavailable += it.meta.key }
        val state = RecommendationBuilder(world.data, listOf(universe)).build(inputs, now)
        assertTrue(state.items.none { "New Comedy" in it.name })
        assertTrue(state.rows.filter { it.kind != PersonalRowKind.ForgottenWatchlist }.all { r -> r.items.none { "New Comedy" in it.name } })
    }

    @Test
    fun completedSeriesKeysUseTmdbIds() = runTest {
        val (world, inputs, universe) = broadWorld()
        val completed = watchedItemKeys("series", "tmdb:1001")
        val state = RecommendationBuilder(world.data, listOf(universe)).build(inputs.copy(fullyWatchedSeriesKeys = completed), now)
        assertTrue(state.completedSeriesTmdbKeys.containsAll(completed))
    }
}
