import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sinhron.sinhron"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sinhron.sinhron"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ADR-040 — Android 8+: notification channels, Keystore AES-GCM, CallStyle via AndroidX.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ADR-040 — release signing: `scripts/android_release.sh` writes a
    // temporary android/key.properties (git-ignored) pointing at the key kept
    // outside the repo (~/Documents/Keys/sinhron). Without it a release build
    // is NOT signed and installs nowhere (security review 2026-11, critic:10):
    // it used to take the debug key silently — a phone with such a build gets
    // no updates and trusts whoever has that debug key. CI, which only checks
    // the build, asks for the debug key with SINHRON_DEBUG_SIGNED=1.
    val keyProps = Properties().apply {
        rootProject.file("key.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
    }
    signingConfigs {
        if (!keyProps.isEmpty) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug").takeIf { System.getenv("SINHRON_DEBUG_SIGNED") == "1" }
        }
    }
}

flutter {
    source = "../.."
}

// ADR-040 — AndroidX, CameraX + ZXing core for QR, the UnifiedPush connector
// for push; ADR-057 revisits "no Google": FCM where Google services are.
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("com.google.zxing:core:3.5.3")
    // CameraX hands back a Guava ListenableFuture; the small `listenablefuture`
    // artifact resolves to an empty placeholder here, so the full library
    // (release builds shrink it).
    implementation("com.google.guava:guava:33.3.1-android")
    implementation("org.unifiedpush.android:connector:3.3.5")
    // ADR-057 — Google push (FCM): the one thing that wakes a phone where
    // Sinhron was swiped away and nothing else is installed. Only the
    // messaging library — no google-services plugin, no google-services.json
    // in the APK (the server hands the Firebase ids at run time, Fcm.kt).
    implementation("com.google.firebase:firebase-messaging:25.1.3")
    // ADR-048 — round video messages: crop to a square + hardware H.264.
    implementation("androidx.media3:media3-transformer:1.4.1")
    implementation("androidx.media3:media3-effect:1.4.1")
    implementation("androidx.media3:media3-common:1.4.1")
    // ADR-059 — the secret words to the phone's password manager (Credential
    // Manager; play-services-auth carries it on Android 13 and older).
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    // ADR-073 — "Sign in with Google" for the chat backup in Drive's app data
    // folder (Identity AuthorizationClient; the same play-services-auth the
    // line above already brings in).
    implementation("com.google.android.gms:play-services-auth:21.2.0")
}
