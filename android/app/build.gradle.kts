import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin
    // plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Reads android/app/google-services.json and generates the config resources
    // firebase_core loads natively.
    id("com.google.gms.google-services")
}

// ── Signing config ─────────────────────────────────────────────────────────────
//
// Priority order (highest first):
//   1. Environment variables  — used by GitHub Actions CI
//   2. android/keystore.properties — used by local developer machines
//   3. debug key               — fallback so `assembleDebug` still works
//
// The environment-variable path is activated when KEY_STORE_BASE64 is set,
// meaning CI has base64-encoded the .jks and stored it as a secret.
// The keystore.properties path is activated when the file exists on disk.
// Neither path is committed to git; both are covered by .gitignore.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// Helper: prefer env var, fall back to keystore.properties, then default.
fun signingProp(envName: String, propName: String, default: String = ""): String {
    return System.getenv(envName)
        ?: (keystoreProperties[propName] as? String)
        ?: default
}

android {
    namespace = "com.sae.presensi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by the desugaring of java.time, which cloud_firestore uses.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.sae.presensi"

        // Pinned rather than inherited from the Flutter SDK, which rewrites it on
        // `flutter create`: firebase_core needs 23+, and so does a reliable
        // `Location.isMocked`, on which the anti-fake-GPS check depends. A floor
        // below 23 would ship a build that cannot detect an injected position.
        minSdk = flutter.minSdkVersion

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Indonesian and English only. Declaring the full list keeps unused
        // android.jar translations out of the APK; Material's own strings follow
        // the app locale rather than the device locale.
        resourceConfigurations += listOf("id", "en")
    }

    signingConfigs {
        // Release signing: reads from env vars (CI) or keystore.properties (local).
        // Falls back to the debug key when neither is available so debug builds
        // continue working without any setup.
        val envStoreFile = signingProp("KEY_STORE", "storeFile")
        val envStoreBase64 = System.getenv("KEY_STORE_BASE64") ?: ""
        val envStorePassword = signingProp("KEY_STORE_PASSWORD", "storePassword")
        val envKeyAlias = signingProp("KEY_ALIAS", "keyAlias")
        val envKeyPassword = signingProp("KEY_PASSWORD", "keyPassword")

        // Only create the release signing config when the keystore actually
        // exists on disk. CI always exports KEY_STORE (a path), whether or not
        // the keystore secret was configured, so testing `envStoreFile` for
        // emptiness alone would create a config pointing at a file that was
        // never written — the link step then fails instead of falling back to
        // the debug key as documented.
        val storeFileExists = envStoreFile.isNotEmpty() && file(envStoreFile).exists()

        // Using a partially-filled config would fail at link time with a cryptic
        // error; failing loudly here is easier to diagnose.
        if (storeFileExists || envStoreBase64.isNotEmpty()) {
            create("release") {
                // CI path: keystore is base64-encoded in KEY_STORE_BASE64,
                // decoded to a temp file by the workflow before Gradle runs.
                // Local path: storeFile is an absolute path in keystore.properties.
                storeFile = if (envStoreFile.isNotEmpty()) {
                    file(envStoreFile)
                } else {
                    // The workflow decodes KEY_STORE_BASE64 to this path.
                    rootProject.file("release.keystore.jks")
                }
                storePassword = envStorePassword
                keyAlias = envKeyAlias
                keyPassword = envKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Use the release signing config when available; fall back to debug.
            //
            // The fallback exists so `flutter build apk --release` works on a
            // machine with no keystore — useful for checking that a release build
            // compiles at all. It is NOT a shipping configuration: an APK signed
            // with the debug key cannot be updated on a device that already has a
            // real one, and Play Store rejects it outright.
            //
            // `SAE_RELEASE_UNSIGNED` opts out explicitly. CI sets it only when no
            // keystore secret is configured, so a signed-release pipeline fails
            // loudly instead of publishing an APK nobody can update.
            val releaseSigning = signingConfigs.findByName("release")
            signingConfig = releaseSigning ?: run {
                val allowDebugFallback =
                    System.getenv("SAE_RELEASE_UNSIGNED") == "1" ||
                        (gradle.startParameter.taskNames.any { it.contains("Debug", ignoreCase = true) })
                if (!allowDebugFallback) {
                    throw GradleException(
                        "Release signing key not found.\n" +
                            "Set KEY_STORE / KEY_STORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD, or " +
                            "provide android/keystore.properties.\n" +
                            "To build an unsigned release for a compile check only, set " +
                            "SAE_RELEASE_UNSIGNED=1."
                    )
                }
                signingConfigs.getByName("debug")
            }

            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Java resources are excluded from packaging: the Flutter tool ships them in
    // the asset bundle, and shipping them twice inflates the APK for no benefit.
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
