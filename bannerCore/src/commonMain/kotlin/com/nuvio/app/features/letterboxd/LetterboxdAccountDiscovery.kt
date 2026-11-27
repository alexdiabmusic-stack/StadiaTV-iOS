package com.nuvio.app.features.letterboxd

/** What the sign-in screens need to know about Letterboxd, without reaching into the parsers. */
object LetterboxdSignInSupport {
    const val SIGN_IN_URL = "https://letterboxd.com/sign-in/"
    const val HOST = "letterboxd.com"

    /** The cookie that marks a signed-in session. */
    fun isSignedIn(cookieNames: Collection<String>): Boolean = LetterboxdSession.SESSION_COOKIE in cookieNames

    fun isValidUsername(name: String): Boolean = Regex("^[A-Za-z0-9_]{2,15}$").matches(name)

    /** The username from a page the signed-in member was served, or null when the markup is not one this knows. */
    fun usernameFromPage(html: String): String? = LetterboxdHtml.username(html)
}

object LetterboxdAccountDiscovery {
    /**
     * The signed-in member's username. The account settings page carries it in a form field; the home page is the fallback.
     * Null means "could not tell": the member then types it, and it is checked against the site before it is used.
     */
    suspend fun discoverUsername(session: LetterboxdSession): String? {
        val pages = listOf("/settings/", "/")
        for (path in pages) {
            val r = try { session.send(LetterboxdRequest("GET", path, session.navHeaders())) } catch (e: LetterboxdException.SessionExpired) { throw e } catch (e: LetterboxdException) { continue }
            if (r.status !in 200..299) continue
            val fromField = LetterboxdHtml.hiddenInput(r.body, "username")?.takeIf(LetterboxdSignInSupport::isValidUsername)
            val name = fromField ?: LetterboxdHtml.username(r.body)
            if (name != null) return name
        }
        return null
    }

    /** Whether a profile page exists for [username]. */
    suspend fun profileExists(session: LetterboxdSession, username: String): Boolean {
        val r = session.send(LetterboxdRequest("GET", "/$username/", session.navHeaders()))
        return r.status in 200..299
    }
}
