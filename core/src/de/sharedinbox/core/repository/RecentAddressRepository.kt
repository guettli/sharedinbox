package de.sharedinbox.core.repository

import de.sharedinbox.core.jmap.mail.EmailAddress

data class RecentAddress(
    val email: String,
    val name: String?,
    val useCount: Int,
    val lastUsedEpochMillis: Long,
)

interface RecentAddressRepository {
    /** Returns up to 50 recently used addresses for [accountId], newest first. */
    suspend fun getRecentAddresses(accountId: String): List<RecentAddress>

    /**
     * Searches recent addresses by substring match on email or display name.
     * Returns up to 20 results ordered by use count then recency.
     */
    suspend fun searchAddresses(
        accountId: String,
        query: String,
    ): List<RecentAddress>

    /** Records [address] as used for [accountId], creating or bumping the counter. */
    suspend fun recordUsage(
        accountId: String,
        address: EmailAddress,
    )
}
