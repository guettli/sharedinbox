package de.sharedinbox.data.contacts

import android.content.Context
import android.provider.ContactsContract
import de.sharedinbox.core.repository.Contact
import de.sharedinbox.core.repository.ContactBookRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AndroidContactBookRepository(
    private val context: Context,
) : ContactBookRepository {
    override suspend fun searchContacts(query: String): List<Contact> =
        withContext(Dispatchers.IO) {
            val results = mutableListOf<Contact>()
            runCatching {
                val uri = ContactsContract.CommonDataKinds.Email.CONTENT_URI
                val projection =
                    arrayOf(
                        ContactsContract.CommonDataKinds.Email.ADDRESS,
                        ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY,
                    )
                val selection =
                    "${ContactsContract.CommonDataKinds.Email.ADDRESS} LIKE ? OR " +
                        "${ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY} LIKE ?"
                val selectionArgs = arrayOf("%$query%", "%$query%")
                context.contentResolver
                    .query(uri, projection, selection, selectionArgs, null)
                    ?.use { cursor ->
                        val emailIdx =
                            cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.ADDRESS)
                        val nameIdx =
                            cursor.getColumnIndex(ContactsContract.CommonDataKinds.Email.DISPLAY_NAME_PRIMARY)
                        while (cursor.moveToNext() && results.size < 20) {
                            val email = cursor.getString(emailIdx) ?: continue
                            val name = cursor.getString(nameIdx)
                            results += Contact(name = name, email = email)
                        }
                    }
            }
            results
        }
}
