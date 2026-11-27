package com.nuvio.app.features.player

internal actual object IosPlaybackEngineSettingsStorage {
    actual val isAvailable: Boolean = false
    actual fun loadEngine(): IosPlaybackEngine = IosPlaybackEngine.Automatic
    actual fun saveEngine(engine: IosPlaybackEngine) = Unit
    actual fun loadEmergencyFallback(): Boolean = false
    actual fun saveEmergencyFallback(enabled: Boolean) = Unit
}
