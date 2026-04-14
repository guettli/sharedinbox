package de.sharedinbox.data.repository

import de.sharedinbox.core.repository.ImageTrustRepository
import de.sharedinbox.data.db.SharedInboxDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class ImageTrustRepositoryImpl(
    private val db: SharedInboxDatabase,
) : ImageTrustRepository {
    override suspend fun isTrusted(
        accountId: String,
        emailId: String,
    ): Boolean =
        withContext(Dispatchers.Default) {
            db.imageTrustQueries.isImageTrusted(accountId, emailId).executeAsOne() > 0
        }

    override suspend fun grantTrust(
        accountId: String,
        emailId: String,
    ): Unit =
        withContext(Dispatchers.Default) {
            db.imageTrustQueries.grantImageTrust(accountId, emailId)
        }
}
