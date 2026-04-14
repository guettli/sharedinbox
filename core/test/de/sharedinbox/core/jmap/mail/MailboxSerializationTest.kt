package de.sharedinbox.core.jmap.mail

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MailboxSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val fullRights =
        MailboxRights(
            mayReadItems = true,
            mayAddItems = true,
            mayRemoveItems = true,
            maySetSeen = true,
            maySetKeywords = true,
            mayCreateChild = true,
            mayRename = true,
            mayDelete = true,
            maySubmit = true,
        )

    private val readOnlyRights =
        MailboxRights(
            mayReadItems = true,
            mayAddItems = false,
            mayRemoveItems = false,
            maySetSeen = false,
            maySetKeywords = false,
            mayCreateChild = false,
            mayRename = false,
            mayDelete = false,
            maySubmit = false,
        )

    @Test
    fun mailboxRights_full_roundTrip() {
        val decoded = json.decodeFromString<MailboxRights>(json.encodeToString(fullRights))
        assertEquals(fullRights, decoded)
        assertEquals(true, decoded.mayDelete)
    }

    @Test
    fun mailboxRights_readOnly_roundTrip() {
        val decoded = json.decodeFromString<MailboxRights>(json.encodeToString(readOnlyRights))
        assertEquals(readOnlyRights, decoded)
        assertEquals(false, decoded.mayAddItems)
    }

    @Test
    fun mailbox_inbox_roundTrip() {
        val mailbox =
            Mailbox(
                id = "m1",
                name = "Inbox",
                role = MailboxRole.INBOX,
                sortOrder = 1,
                totalEmails = 42,
                unreadEmails = 5,
                totalThreads = 30,
                unreadThreads = 3,
                myRights = fullRights,
                isSubscribed = true,
            )
        val decoded = json.decodeFromString<Mailbox>(json.encodeToString(mailbox))
        assertEquals(mailbox, decoded)
        assertEquals("Inbox", decoded.name)
        assertEquals(5, decoded.unreadEmails)
    }

    @Test
    fun mailbox_withParent_roundTrip() {
        val mailbox =
            Mailbox(
                id = "m2",
                name = "Work",
                parentId = "m1",
                myRights = fullRights,
            )
        val decoded = json.decodeFromString<Mailbox>(json.encodeToString(mailbox))
        assertEquals("m1", decoded.parentId)
    }

    @Test
    fun mailbox_noRole_hasNullRole() {
        val mailbox = Mailbox(id = "m3", name = "Custom", myRights = readOnlyRights)
        assertNull(mailbox.role)
        assertNull(mailbox.parentId)
        assertEquals(0, mailbox.sortOrder)
    }

    @Test
    fun mailboxRole_constants() {
        assertEquals("inbox", MailboxRole.INBOX)
        assertEquals("sent", MailboxRole.SENT)
        assertEquals("trash", MailboxRole.TRASH)
        assertEquals("drafts", MailboxRole.DRAFTS)
        assertEquals("archive", MailboxRole.ARCHIVE)
        assertEquals("junk", MailboxRole.SPAM)
    }
}
