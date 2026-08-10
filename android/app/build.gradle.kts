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

    val ksPath: String? = System.getenv("ANDROID_KEYSTORE_PATH")

    if (ksPath != null) {
        signingConfigs {
            create("release") {
                keyAlias = "upload"
                val pass = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: ""
                storePassword = pass
                keyPassword = pass
                storeFile = file(ksPath)
            }
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

    lint {
        // lintVital runs automatically as part of every release build. The lint
        // bundled with the current AGP crashes (NoSuchMethodError in
        // JavaDocParser) while analysing url_launcher_android's UrlLauncher.java,
        // failing :url_launcher_android:lintVitalAnalyzeRelease and aborting the
        // whole release build. That is a bug in lint, not in our code, and our
        // Dart sources are already gated by `flutter analyze`, so skip the
        // release-build lint check.
        checkReleaseBuilds = false
    }

    buildTypes {
        release {
            if (ksPath != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            // R8 + resource shrinking. Produces build/app/outputs/mapping/release/mapping.txt
            // which is uploaded alongside the AAB so Play Console can deobfuscate
            // crash and ANR stack traces (see scripts/deploy_playstore.py).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    // Flutter's embedding bundles PlayStoreDeferredComponentManager, which references
    // com.google.android.play.core.* classes (tasks.Task, splitinstall.*). We don't use
    // deferred components, but AGP 9.x's release build trace-references step fails on
    // these missing references. compileOnly satisfies the static check without bundling
    // the library into the APK.
    releaseCompileOnly("com.google.android.play:core:1.10.3")
}

// Exclude the JVM tink artifact in favor of tink-android. Both artifacts ship
// overlapping classes (e.g. com.google.crypto.tink.Aead), which fails the
// `:app:checkDebugDuplicateClasses` task when something pulls in `tink` while
// another dependency (e.g. flutter_secure_storage) pulls in `tink-android`.
// `tink-android` contains everything `tink` does plus Android-specific code,
// so dropping `tink` is safe. See https://github.com/tink-crypto/tink-java.
configurations.configureEach {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
