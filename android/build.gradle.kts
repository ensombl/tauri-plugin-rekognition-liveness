plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    // Kotlin 2.0+ replaces the legacy `composeOptions { kotlinCompilerExtensionVersion = ... }`
    // mechanism with this Gradle plugin. Without it, AGP's `compose = true`
    // flag does not consistently activate the compose compiler inside the
    // Tauri-bundled submodule — symptom: AbstractMethodError on Content()
    // because the override never gets the Composer/changed-int parameters.
    // Version inherits from the buildscript classpath in gen/android/build.gradle.kts.
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.tauri.rekognitionliveness"
    compileSdk = 34

    defaultConfig {
        // Compose + Amplify Liveness UI require API 24+
        minSdk = 24

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        // JDK 17 is the AGP 8.x default and what the rest of the modern
        // Android toolchain (Compose Compiler 2.x, Kotlin 2.x, Amplify
        // Liveness 1.10) is built against. Java 21 (used as the build JDK
        // by recent Android Studio / command-line gradle) emits
        // source/target=8 deprecation warnings; bumping clears them.
        // Tauri's auto-generated consumer app module is unaffected — DEX
        // conversion handles per-module bytecode levels independently, so
        // an app on a lower target still consumes our class files fine.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }
    // No `composeOptions` block — under the Kotlin Compose Gradle plugin
    // (Kotlin 2.0+), the compiler is bundled with the Kotlin distribution and
    // does not need a separate `kotlinCompilerExtensionVersion` pin.
}

// Force CameraX to a 16 KB-aligned version regardless of what Amplify Liveness
// transitively pins. CameraX 1.4.0 (Oct 2024) was the first release with 16 KB
// alignment for libimage_processing_util_jni.so. Belt-and-suspenders alongside
// the Amplify 1.10 bump — guards against future Amplify-internal CameraX pin
// regressions. Safe: Amplify only consumes the public CameraX API.
configurations.all {
    resolutionStrategy {
        force("androidx.camera:camera-core:1.4.0")
        force("androidx.camera:camera-camera2:1.4.0")
        force("androidx.camera:camera-lifecycle:1.4.0")
        force("androidx.camera:camera-view:1.4.0")
    }
}

dependencies {
    // Tauri Android runtime
    implementation(project(":tauri-android"))

    // Compose BOM keeps every compose-* artifact on a mutually tested set of
    // versions — pulls compose-ui, compose-material3, etc. through one knob.
    // 2025.04.00 pairs with Kotlin 2.2.0 + Compose Compiler 2.2.0.
    implementation(platform("androidx.compose:compose-bom:2025.04.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.8.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")

    // AWS Amplify Face Liveness — provides the FaceLivenessDetector composable
    // that handles camera capture + WebSocket streaming to Rekognition Streaming
    // entirely on-device. Frame data never crosses Tauri IPC.
    // Amplify Liveness 1.6.0+ ships 16 KB-aligned native libs (resolves
    // aws-amplify/amplify-ui-android#161). 1.10.0 fixes a critical dependency
    // issue from 1.8.2 / 1.9.0 (which were deprecated by Amplify), so it's
    // the safe latest. Compatible with our Kotlin 2.2.0 toolchain.
    implementation("com.amplifyframework.ui:liveness:1.10.0")
}
