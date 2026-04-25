plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
}

android {
    namespace = "com.teale.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.teale.android"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"

        buildConfigField(
            "String",
            "GATEWAY_BASE_URL",
            "\"${project.findProperty("teale.gatewayBaseUrl") ?: "https://gateway.teale.com"}\""
        )
        buildConfigField(
            "String",
            "RELAY_URL",
            "\"${project.findProperty("teale.relayUrl") ?: "wss://relay.teale.com/ws"}\""
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        create("release") {
            // Pre-release keystore committed to the repo for sideload convenience.
            // For Play Store: replace with a cold-stored signing key before v1.0.
            storeFile = file("teale-release.keystore")
            storePassword = "teale-pre-release"
            keyAlias = "teale"
            keyPassword = "teale-pre-release"
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        resources {
            excludes += setOf(
                "META-INF/LICENSE.md",
                "META-INF/LICENSE-notice.md",
                "META-INF/AL2.0",
                "META-INF/LGPL2.1",
            )
        }
    }

    sourceSets {
        getByName("main") {
            kotlin.srcDirs("src/main/kotlin")
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.13.1")
    // AppCompat pulls in AppCompatDelegate.setApplicationLocales() — runtime
    // language switching on Android 10+ with system integration on 13+.
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.5")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.5")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.5")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.0")

    // Room for chat persistence
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")

    // DataStore for settings
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Keystore-backed encrypted prefs
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // OkHttp + SSE
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:okhttp-sse:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // kotlinx serialization (1.6.3 is the last release compatible with Kotlin 1.9.x)
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")

    // Ed25519 keys (Android-compatible, pure-Java)
    implementation("net.i2p.crypto:eddsa:0.3.0")

    // Location (FusedLocationProvider)
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Scheduled background work
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    testImplementation("junit:junit:4.13.2")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
