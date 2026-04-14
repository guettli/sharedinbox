package de.sharedinbox.data.network

import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.network.NetworkType

/** Desktop/JVM always treats the connection as unmetered WiFi. */
class JvmNetworkMonitor : NetworkMonitor {
    override fun currentNetworkType(): NetworkType = NetworkType.WIFI_OR_UNMETERED
}
