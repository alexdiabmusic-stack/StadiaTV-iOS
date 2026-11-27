package com.nuvio.app.features.sports

/** The few things the Sports hub asks of the app around it: a short message, and notification permission. */
object SportsHost {
    /** Shows [text] briefly (a toast on the phone, a banner on the Mac). */
    var toast: (text: String, durationMillis: Long) -> Unit = { _, _ -> }

    /** Asks the person to allow notifications; true when they now are. */
    var requestNotifications: suspend () -> Boolean = { false }
}
