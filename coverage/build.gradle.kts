// Coverage project — mirrors the pattern used by codegen/.
// Amper standalone cannot load Gradle plugins, so coverage runs here.
//
// Usage:
//   ./gradlew --project-dir coverage test             # run tests only
//   ./gradlew --project-dir coverage koverVerify      # verify ≥ 70 % line coverage
//   ./gradlew --project-dir coverage test koverVerify # both (used by task check)

plugins {
    kotlin("jvm") version "2.3.20"
    kotlin("plugin.serialization") version "2.3.20"
    id("org.jetbrains.kotlinx.kover") version "0.9.1"
}

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(21)
}

// Mirror the dependencies declared in core/module.yaml
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-core:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")

    testImplementation(kotlin("test"))
    testImplementation("org.junit.platform:junit-platform-launcher:1.11.4")
}

// Point directly at core's source and test trees (no duplication of source files)
sourceSets {
    main {
        kotlin.srcDirs("../core/src")
    }
    test {
        kotlin.srcDirs("../core/test")
    }
}

kover {
    reports {
        verify {
            rule {
                bound {
                    minValue = 70
                }
            }
        }
    }
}
