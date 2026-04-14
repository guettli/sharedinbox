package de.sharedinbox.core.repository

/**
 * User-configurable thresholds that control how aggressively emails are synced
 * depending on the current network type.
 *
 * Email headers and text bodies always sync regardless of network.
 * Attachment blobs are gated by [mobileMbLimit] / [wifiMbLimit] and the email
 * must be recent enough according to [mobileDays] / [wifiDays].
 */
data class SyncSettings(
    /** On mobile data: only sync emails newer than this many days. */
    val mobileDays: Int = 60,
    /** On mobile data: skip attachment blobs larger than this many MB. */
    val mobileMbLimit: Int = 1,
    /** On WiFi / unmetered: only sync emails newer than this many days. */
    val wifiDays: Int = 400,
    /** On WiFi / unmetered: skip attachment blobs larger than this many MB. */
    val wifiMbLimit: Int = 10,
)

interface SyncSettingsRepository {
    suspend fun get(): SyncSettings

    suspend fun save(settings: SyncSettings)
}
