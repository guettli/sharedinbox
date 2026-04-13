// Standalone code-generation project.
// Purpose: run SQLDelight schema → Kotlin code generation and copy the output
// into data/src/ so that Amper (standalone mode) can compile it.
//
// Usage:  ./gradlew -p codegen generateAndCopy
//
// The data/build.gradle.kts cannot be processed by Amper standalone, so this
// separate mini-project does the code-gen step.

plugins {
    kotlin("multiplatform") version "2.3.20"
    id("app.cash.sqldelight") version "2.3.2"
}

repositories {
    mavenCentral()
    google()
}

kotlin {
    jvm()
}

sqldelight {
    databases {
        create("SharedInboxDatabase") {
            packageName.set("de.sharedinbox.data.db")
            srcDirs.setFrom("../data/src/sqldelight")
        }
    }
}

val generatedSrc = layout.buildDirectory.dir("generated/sqldelight/code/SharedInboxDatabase/commonMain")
val dataSrcDir = rootDir.resolve("../data/src/generated")

tasks.register<Copy>("generateAndCopy") {
    dependsOn("generateCommonMainSharedInboxDatabaseInterface")
    from(generatedSrc)
    into(dataSrcDir)
    includeEmptyDirs = false
}
