package de.sharedinbox.data.repository

import de.sharedinbox.core.repository.SyncSettings
import de.sharedinbox.core.repository.SyncSettingsRepository
import de.sharedinbox.data.db.SharedInboxDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SyncSettingsRepositoryImpl(
    private val db: SharedInboxDatabase,
) : SyncSettingsRepository {
    override suspend fun get(): SyncSettings =
        withContext(Dispatchers.IO) {
            db.settingsQueries
                .selectSyncSettings()
                .executeAsOneOrNull()
                ?.toDomain()
                ?: SyncSettings()
        }

    override suspend fun save(settings: SyncSettings): Unit =
        withContext(Dispatchers.IO) {
            db.settingsQueries.upsertSyncSettings(
                mobile_days = settings.mobileDays.toLong(),
                mobile_mb_limit = settings.mobileMbLimit.toLong(),
                wifi_days = settings.wifiDays.toLong(),
                wifi_mb_limit = settings.wifiMbLimit.toLong(),
            )
        }
}

private fun de.sharedinbox.data.db.SelectSyncSettings.toDomain() =
    SyncSettings(
        mobileDays = mobile_days.toInt(),
        mobileMbLimit = mobile_mb_limit.toInt(),
        wifiDays = wifi_days.toInt(),
        wifiMbLimit = wifi_mb_limit.toInt(),
    )
