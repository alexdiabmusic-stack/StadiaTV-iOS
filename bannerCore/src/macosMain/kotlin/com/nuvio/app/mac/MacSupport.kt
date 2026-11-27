package com.nuvio.app.mac

import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** A failure inside one background job is logged and dropped; it must not take the app down with it. */
internal val macExceptionHandler = CoroutineExceptionHandler { _, error -> println("[core] background job failed: ${error.message}") }

/** The scope the Mac layer runs its work in: main thread, supervised, with failures contained. */
internal fun macScope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main + macExceptionHandler)
