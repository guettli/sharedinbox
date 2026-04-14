package de.sharedinbox.core.network

enum class NetworkType {
    /** Cellular / mobile data. */
    MOBILE,

    /** WiFi or other unmetered connection. */
    WIFI_OR_UNMETERED,
}

/**
 * Platform-specific network type detector.
 *
 * The default implementation (used on desktop/JVM) always returns
 * [NetworkType.WIFI_OR_UNMETERED]. Platform modules may bind a richer
 * implementation (e.g. Android's ConnectivityManager).
 */
interface NetworkMonitor {
    fun currentNetworkType(): NetworkType
}
