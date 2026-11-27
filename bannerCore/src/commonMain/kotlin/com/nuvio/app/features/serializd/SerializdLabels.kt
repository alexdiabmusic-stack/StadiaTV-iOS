package com.nuvio.app.features.serializd

/** The words for what the queue did, shared by every app's "Sync activity" view so they all say the same thing. */
object SerializdLabels {
    fun type(type: SerializdOperationType): String = when (type) {
        SerializdOperationType.MarkEpisodeWatched -> "Watched mark"
        SerializdOperationType.CreateDiaryEntry -> "Diary entry"
        SerializdOperationType.SubmitRating -> "Rating"
        SerializdOperationType.SubmitReview -> "Review"
        SerializdOperationType.RemoveWatchedMarker -> "Remove watched mark"
        SerializdOperationType.ImportHistory -> "Import"
        SerializdOperationType.Verify -> "Check"
    }

    fun status(status: SerializdOperationStatus): String = when (status) {
        SerializdOperationStatus.Pending -> "Queued"
        SerializdOperationStatus.InProgress -> "Sending"
        SerializdOperationStatus.Synced -> "Done"
        SerializdOperationStatus.Skipped -> "Skipped"
        SerializdOperationStatus.RetryScheduled -> "Will retry"
        SerializdOperationStatus.NeedsReconnect -> "Reconnect needed"
        SerializdOperationStatus.ReconciliationRequired -> "Confirming"
        SerializdOperationStatus.ActionRequired -> "Needs you"
        SerializdOperationStatus.FailedPermanent -> "Stopped"
    }

    fun error(error: SerializdErrorCategory): String = when (error) {
        SerializdErrorCategory.None -> ""
        SerializdErrorCategory.Offline -> "Network: no connection"
        SerializdErrorCategory.BadCredentials -> "Sign-in: email or password refused"
        SerializdErrorCategory.SessionExpired -> "Sign-in: session expired"
        SerializdErrorCategory.ReconnectionRequired -> "Sign-in: reconnect Serializd"
        SerializdErrorCategory.RateLimited -> "Serializd asked to slow down"
        SerializdErrorCategory.ServerError -> "Serializd had a problem"
        SerializdErrorCategory.MetadataMissing -> "Matching: not on Serializd yet; will look again"
        SerializdErrorCategory.MetadataMismatch -> "Matching: Serializd numbers this show differently, so it was not logged"
        SerializdErrorCategory.Rejected -> "Serializd refused the request"
        SerializdErrorCategory.Ambiguous -> "Unclear whether it arrived; checking your diary before anything is resent"
        SerializdErrorCategory.Unsupported -> "Not possible from here; open Serializd"
        SerializdErrorCategory.Unexpected -> "Unexpected answer from Serializd"
    }

    /** Whether a status means the member may want to act on it (retry, reconnect). */
    fun needsAttention(status: SerializdOperationStatus): Boolean = when (status) {
        SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.ActionRequired -> true
        else -> false
    }
}
