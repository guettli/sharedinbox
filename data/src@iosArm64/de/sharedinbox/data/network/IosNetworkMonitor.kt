package de.sharedinbox.data.network

import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.network.NetworkType

/** iOS implementation — defaults to WiFi/unmetered; can be extended with NWPathMonitor. */
class IosNetworkMonitor : NetworkMonitor {
    override fun currentNetworkType(): NetworkType = NetworkType.WIFI_OR_UNMETERED
}
