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
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        create("release") {
            // Hardcoded alias matching t.sh
            keyAlias = "upload"
            // Use the same password for both key and keystore
            val pass = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            storePassword = pass
            keyPassword = pass
            storeFile = file("upload-keystore.jks")
        }
    }

    defaultConfig {
        applicationId = "de.sharedinbox.mua"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Use the signing config defined above for release builds.
            // If the keystore file exists (e.g. in CI or manually placed), sign it.
            signingConfig = if (signingConfigs.getByName("release").storeFile?.exists() == true) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

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
    // integration_test is a dev dependency; the Flutter plugin loader adds it as
    // debugImplementation only, but GeneratedPluginRegistrant.java (in src/main)
    // references its class in all variants. Make it available for release compilation
    // without bundling it in the APK.
    releaseCompileOnly(project(":integration_test"))
}
