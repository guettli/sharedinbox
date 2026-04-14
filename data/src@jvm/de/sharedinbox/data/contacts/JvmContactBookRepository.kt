package de.sharedinbox.data.contacts

import de.sharedinbox.core.repository.Contact
import de.sharedinbox.core.repository.ContactBookRepository

/** Desktop has no system contact book. */
class JvmContactBookRepository : ContactBookRepository {
    override suspend fun searchContacts(query: String): List<Contact> = emptyList()
}
