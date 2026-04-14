package de.sharedinbox.data.contacts

import de.sharedinbox.core.repository.Contact
import de.sharedinbox.core.repository.ContactBookRepository

/**
 * iOS contact book stub.
 *
 * Full implementation would use CNContactStore via platform.Contacts.*
 * and call requestAccess(for:completionHandler:) on first use.
 */
class IosContactBookRepository : ContactBookRepository {
    override suspend fun searchContacts(query: String): List<Contact> = emptyList()
}
