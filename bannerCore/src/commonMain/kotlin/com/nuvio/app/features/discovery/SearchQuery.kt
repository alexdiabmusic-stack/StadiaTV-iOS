package com.nuvio.app.features.discovery

enum class SearchMediaType { MOVIE, SERIES }
enum class WatchedFilter { UNWATCHED, WATCHED }
enum class ChipKind { MEDIA_TYPE, GENRE, KEYWORD, PERSON, SIMILAR_TO, YEARS, RUNTIME, RATING, EXCLUDE, WATCHED, SAVED, AVAILABILITY }

/** One detected filter, shown as an editable chip so the viewer can remove it instead of trusting a silent guess. */
data class SearchChip(val id: String, val kind: ChipKind, val label: String)

data class ParsedSearch(
    val raw: String,
    val mediaType: SearchMediaType? = null,
    val genres: List<String> = emptyList(),
    val keywords: List<String> = emptyList(),
    val people: List<String> = emptyList(),
    val similarTo: String? = null,
    val yearFrom: Int? = null,
    val yearTo: Int? = null,
    val maxRuntimeMin: Int? = null,
    val minRuntimeMin: Int? = null,
    val minRating: Double? = null,
    val excluded: List<String> = emptyList(),
    val watched: WatchedFilter? = null,
    val savedOnly: Boolean = false,
    val availableNow: Boolean = false,
    /** What is left after the filters are taken out: an ordinary title search. */
    val residualText: String = "",
    val chips: List<SearchChip> = emptyList(),
) {
    /** False for an ordinary title search, which is sent through exactly as typed. */
    val isStructured: Boolean get() = chips.isNotEmpty()

    /** The same search with one chip taken off. */
    fun without(chipId: String): ParsedSearch {
        val chip = chips.firstOrNull { it.id == chipId } ?: return this
        val rest = copy(chips = chips - chip)
        return when (chip.kind) {
            ChipKind.MEDIA_TYPE -> rest.copy(mediaType = null)
            ChipKind.GENRE -> rest.copy(genres = genres - chip.label)
            ChipKind.KEYWORD -> rest.copy(keywords = keywords - chip.label)
            ChipKind.PERSON -> rest.copy(people = people - chip.label)
            ChipKind.SIMILAR_TO -> rest.copy(similarTo = null)
            ChipKind.YEARS -> rest.copy(yearFrom = null, yearTo = null)
            ChipKind.RUNTIME -> rest.copy(maxRuntimeMin = null, minRuntimeMin = null)
            ChipKind.RATING -> rest.copy(minRating = null)
            ChipKind.EXCLUDE -> rest.copy(excluded = excluded - chip.label.removePrefix("Not "))
            ChipKind.WATCHED -> rest.copy(watched = null)
            ChipKind.SAVED -> rest.copy(savedOnly = false)
            ChipKind.AVAILABILITY -> rest.copy(availableNow = false)
        }
    }
}

/** What can be sent straight to TMDB Discover, and what still needs a lookup (names to ids). */
data class DiscoverQuery(
    val params: Map<String, String>,
    val unresolvedKeywords: List<String>,
    val unresolvedPeople: List<String>,
    val unresolvedExcludedCompanies: List<String>,
    /** Filters TMDB cannot answer; the app applies them to the results from local state. */
    val localWatchedFilter: WatchedFilter?,
    val localSavedOnly: Boolean,
    val localAvailableNow: Boolean,
)

/**
 * Deterministic natural-language search: no network and no AI service. It reads a query like "crime series similar to Breaking
 * Bad" into filters, and returns them as chips. A query with no filters is an ordinary title search, untouched.
 */
object SearchQueryParser {
    private val genreIds = mapOf(
        "Action" to 28, "Adventure" to 12, "Animation" to 16, "Comedy" to 35, "Crime" to 80, "Documentary" to 99, "Drama" to 18,
        "Family" to 10751, "Fantasy" to 14, "History" to 36, "Horror" to 27, "Music" to 10402, "Mystery" to 9648, "Romance" to 10749,
        "Science Fiction" to 878, "Thriller" to 53, "War" to 10752, "Western" to 37,
    )
    // TMDB uses combined genres for TV.
    private val tvGenreIds = genreIds + mapOf("Action" to 10759, "Adventure" to 10759, "Science Fiction" to 10765, "Fantasy" to 10765, "War" to 10768)

    private val genreWords = mapOf(
        "action" to "Action", "adventure" to "Adventure", "animation" to "Animation", "animated" to "Animation", "comedy" to "Comedy", "comedies" to "Comedy",
        "crime" to "Crime", "documentary" to "Documentary", "documentaries" to "Documentary", "drama" to "Drama", "family" to "Family", "fantasy" to "Fantasy",
        "history" to "History", "historical" to "History", "horror" to "Horror", "mystery" to "Mystery", "mysteries" to "Mystery", "romance" to "Romance",
        "romantic" to "Romance", "science fiction" to "Science Fiction", "sci-fi" to "Science Fiction", "scifi" to "Science Fiction", "thriller" to "Thriller",
        "thrillers" to "Thriller", "war" to "War", "western" to "Western", "westerns" to "Western",
    )
    private val keywordWords = mapOf("feel-good" to "feel-good", "feel good" to "feel-good", "christmas" to "christmas", "holiday" to "christmas", "heist" to "heist", "cozy" to "cozy", "mind-bending" to "mind-bending")
    private val numberWords = mapOf("one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5, "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10, "an" to 1, "a" to 1)

    fun parse(query: String, currentYear: Int): ParsedSearch {
        val raw = query.trim()
        // Quoted text is an exact title: nothing is interpreted.
        if (raw.length >= 2 && raw.startsWith("\"") && raw.endsWith("\"")) return ParsedSearch(raw, residualText = raw.trim('"'))
        var text = " $raw "
        val chips = ArrayList<SearchChip>()
        fun consume(regex: Regex): MatchResult? = regex.find(text)?.also { text = text.replaceRange(it.range, " ") }
        fun chip(kind: ChipKind, label: String) { chips += SearchChip("${kind.name}:${label.lowercase()}", kind, label) }

        // Exclusions, people and "similar to" use capitalised names, so they read the original case first.
        val excluded = ArrayList<String>()
        Regex("""\b(?:that aren't|that are not|aren't|not|without|except|excluding)\s+([A-Z][\w'.&-]*(?:\s+[A-Z][\w'.&-]*)*)""").findAll(text).toList().forEach {
            excluded += it.groupValues[1].trim(); text = text.replace(it.value, " "); chip(ChipKind.EXCLUDE, "Not ${it.groupValues[1].trim()}")
        }
        val people = ArrayList<String>()
        Regex("""\b(?:starring|featuring|directed by|with)\s+([A-Z][\w'.-]*(?:\s+[A-Z][\w'.-]*)*)""").findAll(text).toList().forEach {
            people += it.groupValues[1].trim(); text = text.replace(it.value, " "); chip(ChipKind.PERSON, it.groupValues[1].trim())
        }
        var similar: String? = null
        consume(Regex("""\b(?:similar to|like|such as)\s+([A-Z][\w'.:-]*(?:\s+[A-Z0-9][\w'.:-]*)*)"""))?.let { similar = it.groupValues[1].trim(); chip(ChipKind.SIMILAR_TO, "Similar to ${similar}") }

        var yearFrom: Int? = null; var yearTo: Int? = null
        consume(Regex("""\bfrom the (?:last|past) (\w+) years?\b""", RegexOption.IGNORE_CASE))?.let {
            val n = it.groupValues[1].lowercase().let { w -> w.toIntOrNull() ?: numberWords[w] }
            if (n != null) { yearFrom = currentYear - n; yearTo = currentYear; chip(ChipKind.YEARS, "Last $n years") }
        }
        if (yearFrom == null) consume(Regex("""\b(?:from|in) the (\d{4})s\b|\b(?:from|in) the (\d{2})s\b""", RegexOption.IGNORE_CASE))?.let {
            val full = it.groupValues[1].toIntOrNull(); val short = it.groupValues[2].toIntOrNull()
            val start = full ?: short?.let { s -> if (s >= 30) 1900 + s else 2000 + s }
            if (start != null) { yearFrom = start; yearTo = start + 9; chip(ChipKind.YEARS, "${start}s") }
        }
        var maxRuntime: Int? = null; var minRuntime: Int? = null
        consume(Regex("""\b(?:under|shorter than|less than|no longer than)\s+(?:(\d+)\s*(?:min(?:ute)?s?|hours?|hrs?)|(\w+)\s+hours?)\b""", RegexOption.IGNORE_CASE))?.let { m ->
            val unitIsHours = m.value.contains("hour", true) || m.value.contains("hr", true)
            val n = m.groupValues[1].toIntOrNull() ?: numberWords[m.groupValues[2].lowercase()]
            if (n != null) { maxRuntime = if (unitIsHours) n * 60 else n; chip(ChipKind.RUNTIME, "Under $maxRuntime min") }
        }
        consume(Regex("""\b(?:over|longer than|more than)\s+(\d+)\s*(?:min(?:ute)?s?|hours?)\b""", RegexOption.IGNORE_CASE))?.let { m ->
            val n = m.groupValues[1].toInt(); minRuntime = if (m.value.contains("hour", true)) n * 60 else n; chip(ChipKind.RUNTIME, "Over $minRuntime min")
        }
        var minRating: Double? = null
        consume(Regex("""\b(?:critically )?acclaimed\b|\bhighly rated\b|\bwell[- ]reviewed\b""", RegexOption.IGNORE_CASE))?.let { minRating = 7.5; chip(ChipKind.RATING, "Acclaimed") }
        var watched: WatchedFilter? = null
        consume(Regex("""\b(?:that )?i (?:haven't|have not|hasn't) (?:watched|seen)\b|\bunwatched\b|\bnot (?:yet )?watched\b""", RegexOption.IGNORE_CASE))?.let { watched = WatchedFilter.UNWATCHED; chip(ChipKind.WATCHED, "Unwatched") }
        var saved = false
        consume(Regex("""\b(?:in|on) my (?:list|watchlist)\b|\bsaved\b""", RegexOption.IGNORE_CASE))?.let { saved = true; chip(ChipKind.SAVED, "In my list") }
        var availableNow = false
        consume(Regex("""\b(?:available )?(?:to watch )?tonight\b|\bavailable (?:to watch )?now\b""", RegexOption.IGNORE_CASE))?.let { availableNow = true; chip(ChipKind.AVAILABILITY, "Available now") }

        var type: SearchMediaType? = null
        consume(Regex("""\b(?:movies?|films?)\b""", RegexOption.IGNORE_CASE))?.let { type = SearchMediaType.MOVIE; chip(ChipKind.MEDIA_TYPE, "Movies") }
        if (type == null) consume(Regex("""\b(?:series|tv shows?|shows?|tv)\b""", RegexOption.IGNORE_CASE))?.let { type = SearchMediaType.SERIES; chip(ChipKind.MEDIA_TYPE, "TV series") }

        val genres = ArrayList<String>(); val keywords = ArrayList<String>()
        for ((word, genre) in genreWords.entries.sortedByDescending { it.key.length }) {
            val r = Regex("""\b${Regex.escape(word)}\b""", RegexOption.IGNORE_CASE)
            if (r.containsMatchIn(text)) { text = r.replace(text, " "); if (genre !in genres) { genres += genre; chip(ChipKind.GENRE, genre) } }
        }
        for ((word, key) in keywordWords) {
            val r = Regex("""\b${Regex.escape(word)}\b""", RegexOption.IGNORE_CASE)
            if (r.containsMatchIn(text)) { text = r.replace(text, " "); if (key !in keywords) { keywords += key; chip(ChipKind.KEYWORD, key) } }
        }

        // Nothing detected: an ordinary title search, exactly as typed.
        if (chips.isEmpty()) return ParsedSearch(raw, residualText = raw)
        val stop = setOf("i", "the", "a", "an", "that", "are", "is", "from", "in", "to", "watch", "of", "and", "for", "on", "my", "me", "some", "good")
        val residual = text.split(Regex("\\s+")).filter { it.isNotBlank() && it.lowercase() !in stop }.joinToString(" ")
        return ParsedSearch(raw, type, genres, keywords, people, similar, yearFrom, yearTo, maxRuntime, minRuntime, minRating, excluded, watched, saved, availableNow, residual, chips)
    }

    /** TMDB Discover parameters for what is understood. Names that need an id lookup are returned for the app to resolve. */
    fun toDiscover(search: ParsedSearch, type: SearchMediaType = search.mediaType ?: SearchMediaType.MOVIE): DiscoverQuery {
        val p = LinkedHashMap<String, String>()
        val ids = if (type == SearchMediaType.SERIES) tvGenreIds else genreIds
        search.genres.mapNotNull { ids[it] }.distinct().takeIf { it.isNotEmpty() }?.let { p["with_genres"] = it.joinToString(",") }
        val dateField = if (type == SearchMediaType.SERIES) "first_air_date" else "primary_release_date"
        search.yearFrom?.let { p["$dateField.gte"] = "$it-01-01" }
        search.yearTo?.let { p["$dateField.lte"] = "$it-12-31" }
        search.maxRuntimeMin?.let { p["with_runtime.lte"] = "$it" }
        search.minRuntimeMin?.let { p["with_runtime.gte"] = "$it" }
        search.minRating?.let { p["vote_average.gte"] = "$it"; p["vote_count.gte"] = "200" }
        p["sort_by"] = "popularity.desc"
        return DiscoverQuery(p, search.keywords, search.people, search.excluded, search.watched, search.savedOnly, search.availableNow)
    }
}
