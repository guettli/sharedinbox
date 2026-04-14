package de.sharedinbox.core.repository

/** A single entry from the platform contact book. */
data class Contact(
    val name: String?,
    val email: String,
)

/**
 * Searches the device's native contact book.
 *
 * Platform implementations handle their own permission model:
 * - Android: queries [ContactsContract] (READ_CONTACTS permission required)
 * - iOS: queries [CNContactStore] (permission prompt on first use)
 * - JVM/desktop: always returns an empty list
 */
interface ContactBookRepository {
    /**
     * Returns contacts whose name or email contains [query] (case-insensitive).
     * Returns at most 20 results. Returns an empty list if permission is denied.
     */
    suspend fun searchContacts(query: String): List<Contact>
}
