package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.serializd.SerializdTone

/** The words for what Letterboxd's queue did and how each viewing stands, shared by every app's views so they all say the same thing. */
object LetterboxdLabels {
    fun type(type: LetterboxdOperationType): String = when (type) {
        LetterboxdOperationType.CreateDiaryEntry -> "Diary entry"
        LetterboxdOperationType.SetRating -> "Rating"
        LetterboxdOperationType.PublishReview -> "Review"
        LetterboxdOperationType.SetLike -> "Like"
        LetterboxdOperationType.ImportDiary -> "Import"
        LetterboxdOperationType.Verify -> "Check"
    }

    fun status(status: LetterboxdOperationStatus): String = when (status) {
        LetterboxdOperationStatus.Pending -> "Queued"
        LetterboxdOperationStatus.InProgress -> "Sending"
        LetterboxdOperationStatus.Succeeded -> "Done"
        LetterboxdOperationStatus.Skipped -> "Skipped"
        LetterboxdOperationStatus.RetryScheduled -> "Will retry"
        LetterboxdOperationStatus.NeedsReconnect -> "Reconnect needed"
        LetterboxdOperationStatus.NeedsReconciliation -> "Confirming"
        LetterboxdOperationStatus.ActionRequired -> "Needs you"
        LetterboxdOperationStatus.Failed -> "Failed"
    }

    fun error(error: LetterboxdErrorCategory): String = when (error) {
        LetterboxdErrorCategory.None -> ""
        LetterboxdErrorCategory.Offline -> "No connection"
        LetterboxdErrorCategory.SessionExpired -> "Letterboxd sign-in expired"
        LetterboxdErrorCategory.ReconnectionRequired -> "Reconnect Letterboxd"
        LetterboxdErrorCategory.Blocked -> "Letterboxd is asking for a bot check; waiting"
        LetterboxdErrorCategory.RateLimited -> "Letterboxd asked to slow down"
        LetterboxdErrorCategory.ServerError -> "Letterboxd had a problem"
        LetterboxdErrorCategory.FilmNotFound -> "No matching Letterboxd film"
        LetterboxdErrorCategory.NotAFilm -> "Not a film on Letterboxd"
        LetterboxdErrorCategory.Unsupported -> "Not possible through the website session"
        LetterboxdErrorCategory.Ambiguous -> "Outcome unclear; checking before anything is resent"
        LetterboxdErrorCategory.Unexpected -> "Unexpected answer from Letterboxd"
    }

    /** Whether a status means the member may want to act on it (retry, reconnect, decide). */
    fun needsAttention(status: LetterboxdOperationStatus): Boolean = status in LetterboxdScreenText.STOPPED

    /** How one viewing stands on Letterboxd, in words, with a tone. [canLog] is true when it could still be sent. */
    data class ViewingStatus(val label: String, val tone: SerializdTone, val canLog: Boolean = false)

    fun viewingStatus(viewing: LetterboxdViewing, ops: List<LetterboxdOperation>, hasAccount: Boolean): ViewingStatus {
        val latest = ops.filter { it.viewingId == viewing.id }.maxByOrNull { it.createdAtMs }
        return when {
            viewing.source == "import" -> ViewingStatus("Imported from Letterboxd", SerializdTone.Good)
            viewing.onDiary -> ViewingStatus(if (viewing.reviewPublished) "On Letterboxd with review" else "On Letterboxd", SerializdTone.Good)
            viewing.localOnly && latest == null -> ViewingStatus("Kept here: already logged that day", SerializdTone.Neutral)
            latest == null -> ViewingStatus(if (hasAccount) "Not sent to Letterboxd" else "Letterboxd not connected", SerializdTone.Neutral, canLog = hasAccount)
            latest.status == LetterboxdOperationStatus.Pending || latest.status == LetterboxdOperationStatus.InProgress || latest.status == LetterboxdOperationStatus.RetryScheduled ->
                ViewingStatus("Waiting to send", SerializdTone.Warning)
            latest.status == LetterboxdOperationStatus.NeedsReconnect -> ViewingStatus("Reconnect Letterboxd to send", SerializdTone.Warning)
            latest.status == LetterboxdOperationStatus.NeedsReconciliation -> ViewingStatus("Confirming on your diary", SerializdTone.Warning)
            latest.status == LetterboxdOperationStatus.ActionRequired -> ViewingStatus("Needs your attention", SerializdTone.Warning)
            latest.status == LetterboxdOperationStatus.Failed -> ViewingStatus("Could not send", SerializdTone.Problem)
            latest.status == LetterboxdOperationStatus.Skipped -> ViewingStatus("Already on Letterboxd", SerializdTone.Good)
            else -> ViewingStatus("On Letterboxd", SerializdTone.Good)
        }
    }
}
