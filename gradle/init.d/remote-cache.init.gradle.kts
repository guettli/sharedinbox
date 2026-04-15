if (System.getenv("CI") == "true") {
    val cacheUser = requireNotNull(System.getenv("GRADLE_CACHE_USER")) {
        "GRADLE_CACHE_USER must be set in CI"
    }
    val cacheToken = requireNotNull(System.getenv("GRADLE_CACHE_TOKEN")) {
        "GRADLE_CACHE_TOKEN must be set in CI"
    }

    gradle.settingsEvaluated {
        buildCache {
            remote<HttpBuildCache> {
                url = uri("https://gradle-cache.thomas-guettler.de/cache/")
                isPush = true
                isEnabled = true
                credentials {
                    username = cacheUser
                    password = cacheToken
                }
            }
        }
    }
}
