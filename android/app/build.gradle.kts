plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "de.sharedinbox.mua"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = "upload"
            val pass = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            storePassword = pass
            keyPassword = pass
            storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH") ?: error("ANDROID_KEYSTORE_PATH is not set"))
        }
    }

    defaultConfig {
        applicationId = "de.sharedinbox.mua"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required for flutter_local_notifications and other plugins that need Java 8+ APIs on API < 26.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // integration_test is a dev dependency; the Flutter plugin loader adds it as
    // debugImplementation only, but GeneratedPluginRegistrant.java (in src/main)
    // references its class in all variants. Make it available for release compilation
    // without bundling it in the APK.
    releaseCompileOnly(project(":integration_test"))
}
