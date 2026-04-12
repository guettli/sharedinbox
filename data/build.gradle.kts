// Gradle-interop mode: this file sits alongside module.yaml to apply the SQLDelight plugin,
// which is incompatible with Amper standalone. Amper handles everything else.
plugins {
    id("app.cash.sqldelight") version "2.3.2"
}

sqldelight {
    databases {
        create("SharedInboxDatabase") {
            packageName.set("de.sharedinbox.data.db")
            // Explicit srcDirs for Amper compatibility (Amper uses flat src/ not src/commonMain/).
            srcDirs.setFrom("src/sqldelight")
        }
    }
}
