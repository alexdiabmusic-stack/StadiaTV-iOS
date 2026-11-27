package com.nuvio.app.core.platform

/**
 * What the shared core needs from the app that hosts it: build-time configuration, which profile is active, and how to
 * clear local data on sign-out. The iPhone/Android app and the Mac app each install their own at launch.
 */
class CoreConfig(
    val supabaseUrl: String = "",
    val supabaseAnonKey: String = "",
    val supabaseFallbackUrl: String = "",
    val appVersionName: String = "dev",
)

/** The profile the person is currently using, as far as the shared data layer needs to know. */
interface ProfileContext {
    val activeProfileId: Int

    /** True when a secondary profile has chosen to use the primary profile's add-ons. */
    val usesPrimaryAddonsFromSecondaryProfile: Boolean
}

/** Clears everything stored locally for the account when the person signs out or deletes it. */
fun interface AccountDataWiper {
    suspend fun wipe(accountUserId: String?)
}

object CoreRuntime {
    var config: CoreConfig = CoreConfig()
    var profileContext: ProfileContext = object : ProfileContext {
        override val activeProfileId: Int = 1
        override val usesPrimaryAddonsFromSecondaryProfile: Boolean = false
    }
    var accountDataWiper: AccountDataWiper? = null
}
