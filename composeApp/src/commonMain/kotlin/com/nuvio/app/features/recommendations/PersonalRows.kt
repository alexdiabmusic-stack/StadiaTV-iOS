package com.nuvio.app.features.recommendations

import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/*
 * The five personal discovery rows and the coordinator that decides which appear on Home. Each strategy has its own
 * eligibility and ranking; all share the taste profile, the evidence and the diversity tools from
 * RecommendationScoring. Everything here is pure and unit-tested.
 */

enum class PersonalRowKind(val title: String) {
    CompleteFranchise("Complete the Franchise"),
    ContinueUniverse("Continue Your Universe"),
    ForgottenWatchlist("Forgotten Watchlist Gems"),
    FavouriteActors("More From Your Favourite Actors"),
    MightHaveMissed("You Might Have Missed"),
}

/** Tunable rules for the rows; the defaults are the spec's starting values. */
data class RowRules(
    val rowSize: Int = 16,
    val mainSize: Int = 20,
    val forgottenAfterDays: Int = 30,
    val missedMinAgeYears: Int = 5,
    val maxFranchiseShare: Double = 0.25,
    val maxPerActor: Int = 3,
    /** More From Your Favourite Actors only shows when this many different actors have picks. */
    val minActors: Int = 3,
    val maxPerUniverse: Int = 3,
    val maxPerFranchiseGroup: Int = 2,
    val prominentRows: Int = 3,
    val minSize: Map<PersonalRowKind, Int> = mapOf(
        PersonalRowKind.CompleteFranchise to 3,
        PersonalRowKind.ContinueUniverse to 3,
        PersonalRowKind.ForgottenWatchlist to 4,
        PersonalRowKind.FavouriteActors to 5,
        PersonalRowKind.MightHaveMissed to 6,
    ),
    /** Below this strength a row is not shown even if it has enough titles. */
    val minStrength: Double = 0.12,
)

data class RowPick(val meta: TitleMeta, val score: Double, val label: String?)

data class RowResult(
    val kind: PersonalRowKind,
    /** Ranked picks, longer than the row so de-duplication can backfill. */
    val ranked: List<RowPick>,
    /** How relevant the row is for this profile (0..1); decides which rows Home shows first. */
    val strength: Double,
    val eligible: Int,
    val notes: List<String> = emptyList(),
)

/** A verified film series (a TMDB movie collection): released parts in release order. */
data class FranchiseUnit(
    val id: String,
    val name: String,
    /** The universe it belongs to (e.g. "mcu"), or its own id; the row shows at most a couple of units per group. */
    val group: String,
    val entries: List<TitleMeta>,
)

/** A verified continuity (BannerTV's curated universes): every released film and series in it. */
data class UniverseUnit(val id: String, val name: String, val members: List<TitleMeta>)

object PersonalRows {
    // ------------------------------------------------------------------------------------------- D: Complete the Franchise

    /**
     * Film series the profile has started: at least one entry finished and at least one released entry not yet
     * started. The pick is the next unwatched entry after the furthest one watched (release order, which is always
     * verifiable), or the earliest unwatched one when the profile skipped ahead. One pick per series and at most a
     * couple per universe, so one Marvel film doesn't fill the row with the MCU.
     */
    fun completeFranchise(
        units: List<FranchiseUnit>,
        evidence: Map<String, ViewingEvidence>,
        nowMs: Long,
        rules: RowRules = RowRules(),
    ): RowResult {
        data class Option(val unit: FranchiseUnit, val next: TitleMeta, val watched: Int, val total: Int, val lastActivity: Long)
        val options = units.mapNotNull { unit ->
            val entries = unit.entries
            if (entries.size < 2) return@mapNotNull null
            val finished = entries.mapIndexedNotNull { i, m -> i.takeIf { evidence[m.key]?.let { it.finishedMovie || it.seriesCompleted } == true } }
            if (finished.isEmpty()) return@mapNotNull null
            val unwatched = entries.withIndex().filter { (_, m) -> evidence[m.key]?.started != true }
            if (unwatched.isEmpty()) return@mapNotNull null
            val next = unwatched.firstOrNull { it.index > finished.max() } ?: unwatched.first()
            val last = entries.mapNotNull { evidence[it.key]?.lastActivityEpochMs }.maxOrNull() ?: 0L
            Option(unit, next.value, finished.size, entries.size, last)
        }
        val scored = options.map { o ->
            val progress = o.watched.toDouble() / o.total
            val recency = 0.5.pow((nowMs - o.lastActivity).coerceAtLeast(0L) / DAY_MS / 60.0)
            o to (0.4 * progress + 0.3 * recency + 0.3 * (CandidateScoring.quality(o.next) + 0.5) / 1.5)
        }.sortedByDescending { it.second }
        val perGroup = HashMap<String, Int>()
        val ranked = ArrayList<RowPick>()
        val overflow = ArrayList<RowPick>()
        for ((o, s) in scored) {
            val label = "Next in ${o.unit.name} · ${o.watched} of ${o.total} watched"
            val pick = RowPick(o.next, s, label)
            val n = perGroup[o.unit.group] ?: 0
            if (n < rules.maxPerFranchiseGroup) { ranked += pick; perGroup[o.unit.group] = n + 1 } else overflow += pick
        }
        // Past the first couple per universe, more of the same universe only fill in behind the others, four at most.
        val shownPerGroup = HashMap<String, Int>()
        val all = (ranked + overflow).distinctBy { it.meta.key }.filter { p ->
            val group = scored.first { it.first.next.key == p.meta.key }.first.unit.group
            val n = shownPerGroup[group] ?: 0
            if (n >= 4) false else { shownPerGroup[group] = n + 1; true }
        }
        val groups = perGroup.size
        return RowResult(
            PersonalRowKind.CompleteFranchise, all,
            strength = if (all.isEmpty()) 0.0 else min(1.0, 0.35 + 0.15 * groups + 0.25 * (scored.firstOrNull()?.second ?: 0.0)),
            eligible = options.size,
            notes = listOf("$groups franchise groups, ${options.size} unfinished series"),
        )
    }

    // ------------------------------------------------------------------------------------------- E: Continue Your Universe

    /**
     * Branches of universes the profile has meaningfully watched: spinoffs, prequels, companion series and films in
     * the same continuity. A member that is a sequel in a film series the profile already watches is left to Complete
     * the Franchise. Accessible entry points (widely watched, well rated) rank above deep cuts, and a branch in the
     * other format (a series for someone who only watched the films) gets a small lift.
     */
    fun continueUniverse(
        universes: List<UniverseUnit>,
        evidence: Map<String, ViewingEvidence>,
        taste: TasteProfile,
        nowMs: Long,
        today: String,
        excluded: Set<String> = emptySet(),
        rules: RowRules = RowRules(),
    ): RowResult {
        val candidates = ArrayList<Triple<UniverseUnit, TitleMeta, Double>>()
        var engagedUniverses = 0
        for (u in universes) {
            val watchedMembers = u.members.filter { m -> evidence[m.key]?.let { RecommendationScoring.meaningful(it, nowMs) } == true }
            if (watchedMembers.isEmpty()) continue
            engagedUniverses++
            val engagement = min(1.0, watchedMembers.sumOf { RecommendationScoring.engagement(evidence.getValue(it.key), nowMs) } / 3.0)
            val watchedCollections = u.members.filter { evidence[it.key]?.started == true }.mapNotNull { it.collectionId }.toSet()
            val watchedTv = watchedMembers.any { it.tv }
            val watchedFilms = watchedMembers.any { !it.tv }
            u.members.filter { m ->
                evidence[m.key]?.started != true && m.key !in excluded && m.releasedBy(today) &&
                    (m.collectionId == null || m.collectionId !in watchedCollections)
            }.forEach { m ->
                val accessibility = min(1.0, ln(m.voteCount + 1.0) / ln(5000.0))
                val crossMedia = if ((m.tv && !watchedTv) || (!m.tv && !watchedFilms)) 0.1 else 0.0
                val s = 0.35 * engagement + 0.2 * taste.genreMatch(m.genres) + 0.2 * (CandidateScoring.quality(m) + 0.5) / 1.5 +
                    0.15 * accessibility + crossMedia
                candidates += Triple(u, m, s)
            }
        }
        val perUniverse = HashMap<String, Int>()
        val ranked = Diversity.mmr(
            candidates.distinctBy { it.second.key }, size = candidates.size,
            relevance = { it.third }, similarity = { a, b -> if (a.first.id == b.first.id) 0.4 else 0.0 },
        ).filter { (u, _, _) ->
            val n = perUniverse[u.id] ?: 0
            if (n >= rules.maxPerUniverse) false else { perUniverse[u.id] = n + 1; true }
        }.map { (u, m, s) -> RowPick(m, s, "From the ${u.name} universe") }
        return RowResult(
            PersonalRowKind.ContinueUniverse, ranked,
            strength = if (ranked.isEmpty()) 0.0 else min(1.0, 0.3 + 0.2 * perUniverse.size + 0.3 * ranked.take(5).map { it.score }.average()),
            eligible = candidates.size,
            notes = listOf("$engagedUniverses engaged universes, ${perUniverse.size} with unwatched branches"),
        )
    }

    // ------------------------------------------------------------------------------------------- A: Forgotten Watchlist Gems

    /**
     * Saved titles never started and saved at least [RowRules.forgottenAfterDays] ago. A title whose save date the
     * library didn't record can't be shown to be recent, so it stays eligible with a neutral age (and no "Saved ..."
     * label). Ranked by long-term fit first, then current interest, age and quality, with genre variety.
     */
    fun forgottenWatchlist(
        saved: List<Pair<ViewingEvidence, TitleMeta>>,
        taste: TasteProfile,
        actors: Map<Int, Double>,
        nowMs: Long,
        rules: RowRules = RowRules(),
    ): RowResult {
        val minAge = rules.forgottenAfterDays * DAY_MS
        val eligible = saved.filter { (e, _) ->
            e.saved && !e.started && !e.disliked && (e.savedAtEpochMs == null || nowMs - e.savedAtEpochMs >= minAge)
        }
        val scored = eligible.map { (e, m) ->
            val ageDays = e.savedAtEpochMs?.let { (nowMs - it) / DAY_MS }
            val age = if (ageDays == null) 0.4 else min(1.0, ln(ageDays / 30.0 + 1) / ln(13.0))
            val fit = 0.6 * taste.genreMatch(m.genres) + 0.2 * taste.keywordMatch(m.keywords) +
                0.2 * (m.cast.take(5).maxOfOrNull { actors[it.id] ?: 0.0 } ?: 0.0)
            val recent = max(taste.windowGenreMatch(TasteWindow.Recent, m.genres), taste.windowGenreMatch(TasteWindow.MediumTerm, m.genres))
            val s = 0.45 * fit + 0.15 * recent + 0.2 * age + 0.2 * (CandidateScoring.quality(m) + 0.5) / 1.5
            RowPick(m, s, ageDays?.let { savedLabel(it) })
        }
        val ranked = Diversity.mmr(scored, scored.size, { it.score }, { a, b -> Diversity.jaccard(a.meta.genres, b.meta.genres) })
        return RowResult(
            PersonalRowKind.ForgottenWatchlist, ranked,
            strength = if (ranked.isEmpty()) 0.0 else min(1.0, eligible.size / 8.0) * (0.4 + ranked.take(8).map { it.score }.average()),
            eligible = eligible.size,
            notes = listOf("${saved.size} saved, ${eligible.size} never started and old enough"),
        )
    }

    fun savedLabel(ageDays: Long): String = when {
        ageDays >= 365 -> if (ageDays < 730) "Saved a year ago" else "Saved ${ageDays / 365} years ago"
        ageDays >= 60 -> "Saved ${ageDays / 30} months ago"
        ageDays >= 30 -> "Saved a month ago"
        else -> "Saved ${max(1, ageDays / 7)} weeks ago"
    }

    // ------------------------------------------------------------------------------------------- C: Favourite actors

    /** A role an actor played, as found in their credits. */
    data class ActorCredit(val meta: TitleMeta, val order: Int?, val character: String?, val episodeCount: Int?)

    private val NOT_A_ROLE = Regex("""\b(self|himself|herself|themselves|host|narrator|uncredited|archive)\b""", RegexOption.IGNORE_CASE)

    /** Main roles only: billed near the top of a film, or a regular in a series; not cameos, hosting or appearances as themselves. */
    fun isRealRole(c: ActorCredit): Boolean {
        if (c.character.isNullOrBlank() || NOT_A_ROLE.containsMatchIn(c.character)) return false
        if (c.meta.genres.any { it in NON_TASTE_GENRES || it == 10764 }) return false
        return if (c.meta.tv) (c.episodeCount ?: 0) >= 6 || (c.order ?: 99) <= 3 else (c.order ?: 99) <= 4
    }

    /**
     * Unseen main roles of the actors the profile keeps watching, outside the franchises the profile already knows
     * them from (no "more Avengers with Chris Evans"; Knives Out is fine). Each actor contributes at most
     * [RowRules.maxPerActor] titles, and the row is ordered actor by actor (each actor's best pick, then each actor's
     * second, ...) so the first screen shows several actors. The row needs [RowRules.minActors] actors with picks.
     */
    fun favouriteActors(
        affinities: List<ActorAffinity>,
        credits: Map<Int, List<ActorCredit>>,
        taste: TasteProfile,
        excluded: Set<String>,
        today: String,
        rules: RowRules = RowRules(),
        franchiseOf: (TitleMeta) -> String? = { null },
    ): RowResult {
        val top = affinities.firstOrNull()?.score ?: return RowResult(PersonalRowKind.FavouriteActors, emptyList(), 0.0, 0)
        data class Option(val actor: ActorAffinity, val meta: TitleMeta, val score: Double)
        val options = affinities.flatMap { a ->
            credits[a.person.id].orEmpty()
                .filter { isRealRole(it) && it.meta.key !in excluded && it.meta.releasedBy(today) && it.meta.voteCount >= 80 }
                .filter { c -> (franchiseOf(c.meta) ?: c.meta.key) !in a.groups }
                .map { c ->
                    val m = c.meta
                    Option(a, m, 0.45 * (a.score / top) + 0.35 * taste.genreMatch(m.genres) + 0.2 * (CandidateScoring.quality(m) + 0.5) / 1.5)
                }
        }.groupBy { it.meta.key }.values.map { same -> same.maxBy { it.score } }
        // Each actor's own picks, best first and varied in genre, capped.
        val perActor = options.groupBy { it.actor.person.id }.mapValues { (_, list) ->
            Diversity.mmr(list, rules.maxPerActor, { it.score }, { a, b -> Diversity.jaccard(a.meta.genres, b.meta.genres) })
        }
        val actorOrder = affinities.map { it.person.id }.filter { it in perActor }
        val ranked = (0 until rules.maxPerActor).flatMap { round -> actorOrder.mapNotNull { perActor.getValue(it).getOrNull(round) } }
            .map { RowPick(it.meta, it.score, "With ${it.actor.person.name}") }
        val actorsWithPicks = actorOrder.size
        val multiFranchise = affinities.count { it.groups.size >= 2 }
        return RowResult(
            PersonalRowKind.FavouriteActors, ranked,
            strength = if (actorsWithPicks < rules.minActors) 0.0 else min(1.0, 0.25 + 0.1 * multiFranchise + 0.1 * min(actorsWithPicks, 5)),
            eligible = options.size,
            notes = listOf("$actorsWithPicks actors with unseen roles (${rules.minActors} needed)") +
                affinities.take(10).map { "${it.person.name}: ${it.titles.size} titles in ${it.groups.size} franchises/standalones (score ${(it.score * 100).toInt() / 100.0})" },
        )
    }

    // ------------------------------------------------------------------------------------------- B: You Might Have Missed

    /**
     * Older films and series (at least [RowRules.missedMinAgeYears] years old) that fit the profile's long-term taste,
     * well rated by enough viewers, favouring the less obvious ones and a spread of decades. Labels only state facts
     * the metadata supports.
     */
    fun mightHaveMissed(
        candidates: List<TitleMeta>,
        taste: TasteProfile,
        actors: Map<Int, Pair<Double, String>>,
        today: String,
        rules: RowRules = RowRules(),
        mainstreamShare: Double = 0.0,
    ): RowResult {
        val thisYear = today.take(4).toIntOrNull() ?: 0
        val eligible = candidates.distinctBy { it.key }.filter { m ->
            val year = m.year ?: return@filter false
            year <= thisYear - rules.missedMinAgeYears && m.voteAverage >= 7.0 && m.voteCount >= (if (m.tv) 150 else 300)
        }
        val scored = eligible.map { m ->
            val longTerm = max(taste.windowGenreMatch(TasteWindow.LongTerm, m.genres), taste.genreMatch(m.genres))
            val novelty = 1 - min(1.0, ln(m.popularity + 1) / ln(200.0))
            val media = if (m.tv) taste.seriesShare else 1 - taste.seriesShare
            val s = 0.45 * longTerm + 0.1 * taste.keywordMatch(m.keywords) + 0.25 * (CandidateScoring.quality(m) + 0.5) / 1.5 +
                0.12 * novelty + 0.08 * media
            val label = when {
                m.creators.any { (taste.creators[it.id] ?: 0.0) > 0.0 } -> if (m.tv) "From a creator you've watched" else "From a director you've watched"
                else -> m.cast.take(4).firstOrNull { it.id in actors }?.let { "With ${it.name}" }
            }
            RowPick(m, s, label)
        }
        val ranked = Diversity.mmr(
            scored, scored.size, { it.score },
            { a, b ->
                0.5 * Diversity.jaccard(a.meta.genres, b.meta.genres) +
                    (if (a.meta.year?.div(10) == b.meta.year?.div(10)) 0.25 else 0.0) +
                    (if (a.meta.collectionId != null && a.meta.collectionId == b.meta.collectionId) 0.25 else 0.0)
            },
        )
        return RowResult(
            PersonalRowKind.MightHaveMissed, ranked,
            strength = if (ranked.isEmpty()) 0.0 else min(1.0, eligible.size / 12.0) * (0.25 + 0.5 * ranked.take(8).map { it.score }.average() + 0.25 * mainstreamShare),
            eligible = eligible.size,
            notes = listOf("${eligible.size} older titles qualified"),
        )
    }

    // ------------------------------------------------------------------------------------------- Coordinator

    data class Plan(
        val main: List<RowPick>,
        /** Rows to show, most relevant first; the first [prominent] go higher up Home. */
        val rows: List<Pair<PersonalRowKind, List<RowPick>>>,
        val prominent: Int,
        val decisions: List<String>,
    )

    /**
     * Places titles where they make most sense and decides which rows show. Claims go in order of purpose: the next
     * franchise instalment, then universe branches, then Recommended For You, then the watchlist, actors and older
     * titles; a title already shown higher up is skipped. If skipping would leave a row too short, it is topped up
     * with already-shown titles rather than emptied. Rows that are too short or too weak are hidden. The strongest
     * [RowRules.prominentRows] go higher up Home; the rest follow further down.
     */
    fun coordinate(
        main: List<RowPick>,
        rows: List<RowResult>,
        rules: RowRules = RowRules(),
        available: (TitleMeta) -> Boolean = { true },
    ): Plan {
        val claimed = HashSet<String>()
        val decisions = ArrayList<String>()
        val byKind = rows.associateBy { it.kind }
        fun take(list: List<RowPick>, size: Int, min: Int, checkAvailability: Boolean): List<RowPick> {
            val usable = list.filter { !checkAvailability || available(it.meta) }
            val fresh = usable.filter { it.meta.key !in claimed }.take(size)
            val result = if (fresh.size >= min || usable.size < min) fresh else (fresh + usable.filter { it !in fresh }).take(min)
            claimed += result.map { it.meta.key }
            return result
        }
        val out = LinkedHashMap<PersonalRowKind, List<RowPick>>()
        fun claim(kind: PersonalRowKind) {
            val r = byKind[kind] ?: return
            val min = rules.minSize.getValue(kind)
            val picks = take(r.ranked, rules.rowSize, min, checkAvailability = kind != PersonalRowKind.ForgottenWatchlist)
            when {
                picks.size < min -> decisions += "${kind.title}: hidden (${picks.size} of $min needed, ${r.eligible} eligible)"
                r.strength < rules.minStrength -> decisions += "${kind.title}: hidden (strength ${r.strength.fmt()})"
                else -> { out[kind] = picks; decisions += "${kind.title}: ${picks.size} titles, strength ${r.strength.fmt()}" }
            }
        }
        claim(PersonalRowKind.CompleteFranchise)
        claim(PersonalRowKind.ContinueUniverse)
        val mainPicks = take(main, rules.mainSize, 6, checkAvailability = true)
        decisions += "Recommended For You: ${mainPicks.size} titles"
        claim(PersonalRowKind.ForgottenWatchlist)
        claim(PersonalRowKind.FavouriteActors)
        claim(PersonalRowKind.MightHaveMissed)
        val ordered = out.entries.sortedByDescending { byKind.getValue(it.key).strength }.map { it.key to it.value }
        return Plan(mainPicks, ordered, min(rules.prominentRows, ordered.size), decisions)
    }

    private fun Double.fmt(): String = ((this * 100).toInt() / 100.0).toString()
}
