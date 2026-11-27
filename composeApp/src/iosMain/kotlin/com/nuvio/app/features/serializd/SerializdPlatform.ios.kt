package com.nuvio.app.features.serializd

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.alloc
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.refTo
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.value
import platform.CoreFoundation.*
import platform.Security.*

@OptIn(ExperimentalForeignApi::class)
internal actual object PlatformSerializdSecrets : SerializdSecretStore {
    actual override fun read(profileId: Int): String? = query(profileId) { query ->
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne)
        memScoped {
            val result = alloc<CFTypeRefVar>()
            val status = SecItemCopyMatching(query, result.ptr)
            if (status == errSecItemNotFound) return@memScoped null
            check(status == errSecSuccess) { "Unable to read the Serializd sign-in (OSStatus $status)" }
            val data: CFDataRef = result.value?.reinterpret() ?: return@memScoped null
            try {
                val bytes = CFDataGetBytePtr(data) ?: return@memScoped null
                ByteArray(CFDataGetLength(data).toInt()) { bytes[it].toByte() }.decodeToString()
            } finally {
                CFRelease(data)
            }
        }
    }

    actual override fun write(profileId: Int, value: String?) = query(profileId) { query ->
        if (value == null) {
            val status = SecItemDelete(query)
            check(status == errSecSuccess || status == errSecItemNotFound) { "Unable to remove the Serializd sign-in (OSStatus $status)" }
        } else {
            val bytes = value.encodeToByteArray().toUByteArray()
            require(bytes.isNotEmpty())
            val data = CFDataCreate(null, bytes.refTo(0), bytes.size.toLong()) ?: error("Unable to encode the Serializd sign-in")
            val attributes = dictionary()
            try {
                CFDictionarySetValue(attributes, kSecValueData, data)
                val update = SecItemUpdate(query, attributes)
                if (update == errSecItemNotFound) {
                    CFDictionarySetValue(query, kSecValueData, data)
                    // Stays on this device: never part of a backup or another device's Keychain. Readable after the first unlock so a
                    // background sync can sign in.
                    CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                    val added = SecItemAdd(query, null)
                    check(added == errSecSuccess) { "Unable to save the Serializd sign-in (OSStatus $added)" }
                } else {
                    check(update == errSecSuccess) { "Unable to update the Serializd sign-in (OSStatus $update)" }
                }
            } finally {
                CFRelease(attributes)
                CFRelease(data)
            }
        }
    }

    private fun dictionary(): CFMutableDictionaryRef =
        CFDictionaryCreateMutable(null, 0L, kCFTypeDictionaryKeyCallBacks.ptr, kCFTypeDictionaryValueCallBacks.ptr) ?: error("Unable to create the Keychain query")

    private inline fun <T> query(profileId: Int, block: (CFMutableDictionaryRef) -> T): T {
        val service = CFStringCreateWithCString(null, "com.nuvio.media.serializd", kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain service")
        val account = CFStringCreateWithCString(null, "profile.$profileId", kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain account")
        val query = dictionary()
        try {
            CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(query, kSecAttrService, service)
            CFDictionarySetValue(query, kSecAttrAccount, account)
            return block(query)
        } finally {
            CFRelease(query); CFRelease(account); CFRelease(service)
        }
    }
}

internal actual fun createSerializdHttpClient(): HttpClient = HttpClient(Darwin) {
    followRedirects = false
    expectSuccess = false
    install(HttpTimeout) {
        // Longer than the transport's own 60 s, so the transport's decision (a lost reply to a write is "may have landed") is the one that applies.
        requestTimeoutMillis = 75_000
        connectTimeoutMillis = 20_000
        socketTimeoutMillis = 75_000
    }
    engine {
        configureSession {
            // The API is called with a bearer token set per request: nothing is kept or sent by the system.
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
        }
    }
}
