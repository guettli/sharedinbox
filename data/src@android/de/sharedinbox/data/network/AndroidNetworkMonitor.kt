package de.sharedinbox.data.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import de.sharedinbox.core.network.NetworkMonitor
import de.sharedinbox.core.network.NetworkType

class AndroidNetworkMonitor(
    private val context: Context,
) : NetworkMonitor {
    override fun currentNetworkType(): NetworkType {
        val cm =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return NetworkType.WIFI_OR_UNMETERED
        val network = cm.activeNetwork ?: return NetworkType.WIFI_OR_UNMETERED
        val caps = cm.getNetworkCapabilities(network) ?: return NetworkType.WIFI_OR_UNMETERED
        return if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
            NetworkType.WIFI_OR_UNMETERED
        } else {
            NetworkType.MOBILE
        }
    }
}
