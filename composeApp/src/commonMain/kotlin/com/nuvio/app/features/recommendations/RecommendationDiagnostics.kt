package com.nuvio.app.features.recommendations

/**
 * What the last build did, for checking recommendation quality on a development build. Collected only when
 * [RecommendationEngine.diagnosticsEnabled] is on (debug builds), kept in memory, never logged or sent anywhere.
 */
data class RecommendationDiagnostics(val sections: List<Pair<String, List<String>>>)

private val GENRE_NAMES = mapOf(
    28 to "Action", 12 to "Adventure", 16 to "Animation", 35 to "Comedy", 80 to "Crime", 99 to "Documentary",
    18 to "Drama", 10751 to "Family", 14 to "Fantasy", 36 to "History", 27 to "Horror", 10402 to "Music",
    9648 to "Mystery", 10749 to "Romance", 878 to "Science Fiction", 53 to "Thriller", 10752 to "War", 37 to "Western",
    10759 to "Action & Adventure", 10762 to "Kids", 10764 to "Reality", 10765 to "Sci-Fi & Fantasy", 10766 to "Soap",
    10768 to "War & Politics", 10770 to "TV Movie",
)

fun genreName(id: Int): String = GENRE_NAMES[id] ?: "Genre $id"

private fun Double.pct(): String = "${(this * 100).toInt()}%"
private fun Double.r2(): String = ((this * 100).toInt() / 100.0).toString()

internal class DiagnosticsCollector {
    private val sections = ArrayList<Pair<String, List<String>>>()

    fun history(inputs: RecommendationInputs, evidence: List<AppEvidence>) {
        val films = evidence.count { !it.evidence.tv && it.evidence.started }
        val series = evidence.count { it.evidence.tv && it.evidence.started }
        sections += "History" to listOf(
            "Watched entries: ${inputs.watched.size} (episodes and films)",
            "Progress entries: ${inputs.progress.size}",
            "Saved titles: ${inputs.saved.size}",
            "Ratings available: ${inputs.ratings.size}",
            "Distinct titles watched or started: $films films, $series series",
        )
    }

    fun resolved(asked: Int, found: Int, noId: Int, noDetails: Int) {
        sections += "Metadata" to listOf(
            "Looked up $asked titles, $found with full details",
            "No TMDB id: $noId (live sports streams, files, or ids TMDB doesn't know)",
            "Details failed or excluded: $noDetails",
        )
    }

    fun taste(taste: TasteProfile, actors: List<ActorAffinity>, seeds: List<Seed>) {
        val lines = ArrayList<String>()
        taste.effectiveWeights.forEach { (w, weight) -> lines += "$w weight ${weight.pct()} from ${taste.windows[w]?.titles ?: 0} titles" }
        lines += "Series share: ${taste.seriesShare.pct()}"
        sections += "Time windows" to lines
        listOf(TasteWindow.LongTerm, TasteWindow.MediumTerm, TasteWindow.Recent, TasteWindow.Explicit).forEach { w ->
            val g = taste.windows[w]?.genres.orEmpty().entries.sortedByDescending { it.value }.take(6)
            if (g.isNotEmpty()) sections += "Genres: $w" to g.map { "${genreName(it.key)} ${it.value.pct()}" }
        }
        sections += "Genres: blended" to taste.genres.entries.sortedByDescending { it.value }.take(8).map { "${genreName(it.key)} ${it.value.r2()}" }
        sections += "Franchise share of attention" to taste.franchises.entries.sortedByDescending { it.value }.take(6).map { "${it.key} ${it.value.pct()}" }
        sections += "Actor affinities" to actors.take(10).map { a -> "${a.person.name}: ${a.score.r2()} from ${a.titles.size} titles (${a.titles.take(4).joinToString()})" }
        sections += "Seeds" to seeds.map { "${it.meta.name} [${it.window}] weight ${it.weight.r2()}" }
    }

    fun candidates(pool: List<Candidate>) {
        val bySource = CandidateSource.entries.associateWith { s -> pool.count { s in it.sources } }
        sections += "Candidate sources" to (listOf("Pool: ${pool.size} unseen titles") + bySource.map { "${it.key}: ${it.value}" })
    }

    fun main(ranked: List<ScoredCandidate>, franchiseOf: (TitleMeta) -> String?) {
        val shown = ranked.take(20)
        sections += "Recommended For You scores" to shown.map { s ->
            val p = s.parts.entries.joinToString(" ") { "${it.key}=${it.value.r2()}" }
            "${s.meta.name} (${if (s.meta.tv) "series" else "film"}) ${s.relevance.r2()} · $p" +
                (franchiseOf(s.meta)?.let { " · $it" } ?: "") + (s.reason?.let { " · via $it" } ?: "")
        }
        val genres = shown.flatMap { it.meta.genres.take(2) }.groupingBy { genreName(it) }.eachCount().entries.sortedByDescending { it.value }
        sections += "Recommended For You distribution" to listOf(
            "Films ${shown.count { !it.meta.tv }}, series ${shown.count { it.meta.tv }}",
            "Genres: " + genres.joinToString { "${it.key} ${it.value}" },
            "Franchises: " + shown.mapNotNull { franchiseOf(it.meta) }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }
                .joinToString { "${it.key} ${it.value}" }.ifBlank { "none" },
        )
    }

    fun rows(rows: List<RowResult>) {
        rows.forEach { r ->
            sections += "${r.kind.title} (strength ${r.strength.r2()}, ${r.eligible} eligible)" to
                (r.notes + r.ranked.take(10).map { "${it.meta.name} ${it.score.r2()}${it.label?.let { l -> " · $l" } ?: ""}" })
        }
    }

    fun plan(plan: PersonalRows.Plan, unavailable: List<String>) {
        sections += "Home row decisions" to (plan.decisions + "Prominent rows: ${plan.prominent}")
        if (unavailable.isNotEmpty()) sections += "Excluded: not available to watch at home" to unavailable.take(30)
    }

    fun result(): RecommendationDiagnostics {
        val d = RecommendationDiagnostics(sections.toList() + ("Cache events" to RecommendationEngine.cacheLog()))
        // Debug builds only (the collector exists only then): mirror to the device log for reading off a simulator.
        d.sections.forEach { (title, lines) -> co.touchlab.kermit.Logger.withTag("RecsDiag").i { "## $title\n" + lines.joinToString("\n") } }
        return d
    }
}
