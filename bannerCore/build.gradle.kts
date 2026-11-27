import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

// BannerCore: the Compose-free Kotlin core shared by the Android/iPhone app (composeApp) and the native Mac app.
// It holds logic only (no UI, no network of its own): recommendations, Explore catalog and selection, Home row order,
// watched keys and the core data models. Package names are unchanged (com.nuvio.app...) so moving code in is import-free.
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidKotlinMultiplatformLibrary)
    alias(libs.plugins.kotlinxSerialization)
}

kotlin {
    android {
        namespace = "com.nuvio.core"
        compileSdk {
            version = release(libs.versions.android.compileSdk.get().toInt()) {
                minorApiLevel = libs.versions.android.compileSdkMinor.get().toInt()
            }
        }
        minSdk = libs.versions.android.minSdk.get().toInt()
        withHostTest { }
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_11)
        }
    }

    // The Mac app links BannerCore as an XCFramework (Swift package binary target): ./gradlew :bannerCore:assembleBannerCoreDebugXCFramework
    val macXcframework = XCFramework("BannerCore")
    macosArm64().binaries.framework {
        baseName = "BannerCore"
        isStatic = true
        macXcframework.add(this)
    }
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "BannerCore"
            isStatic = true
        }
    }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kermit)
            api(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.atomicfu)
            // Account, add-on and catalog data layer
            api(libs.ktor.client.content.negotiation)
            api(libs.ktor.serialization.kotlinx.json)
            api(libs.supabase.postgrest)
            api(libs.supabase.auth)
            api(libs.supabase.functions)
            api(libs.supabase.storage)
            api(libs.supabase.realtime)
        }
        macosMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:${libs.versions.kotlinx.coroutines.get()}")
            implementation("io.ktor:ktor-client-mock:${libs.versions.ktor.get()}")
        }
    }
}
