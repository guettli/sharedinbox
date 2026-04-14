package de.sharedinbox.core.jmap.mail

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.time.Instant

class EmailSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun emailAddress_withName_roundTrip() {
        val addr = EmailAddress(name = "Alice", email = "alice@example.com")
        val decoded = json.decodeFromString<EmailAddress>(json.encodeToString(addr))
        assertEquals(addr, decoded)
        assertEquals("Alice", decoded.name)
        assertEquals("alice@example.com", decoded.email)
    }

    @Test
    fun emailAddress_withoutName_roundTrip() {
        val addr = EmailAddress(email = "bob@example.com")
        val decoded = json.decodeFromString<EmailAddress>(json.encodeToString(addr))
        assertEquals(addr, decoded)
        assertNull(decoded.name)
    }

    @Test
    fun emailBodyValue_roundTrip() {
        val body = EmailBodyValue(value = "Hello world", isEncodingProblem = false, isTruncated = true)
        val decoded = json.decodeFromString<EmailBodyValue>(json.encodeToString(body))
        assertEquals(body, decoded)
        assertEquals("Hello world", decoded.value)
        assertEquals(true, decoded.isTruncated)
    }

    @Test
    fun emailBodyValue_defaults() {
        val body = EmailBodyValue(value = "text")
        assertEquals(false, body.isEncodingProblem)
        assertEquals(false, body.isTruncated)
    }

    @Test
    fun emailBodyPart_full_roundTrip() {
        val part =
            EmailBodyPart(
                partId = "1",
                blobId = "blob1",
                type = "text/plain",
                charset = "utf-8",
                name = "file.txt",
                size = 1024,
                disposition = "attachment",
            )
        val decoded = json.decodeFromString<EmailBodyPart>(json.encodeToString(part))
        assertEquals(part, decoded)
    }

    @Test
    fun emailBodyPart_minimalFields() {
        val part = EmailBodyPart(type = "text/html")
        assertNull(part.partId)
        assertNull(part.blobId)
        assertNull(part.size)
    }

    @Test
    fun email_minimalFields_roundTrip() {
        val email =
            Email(
                id = "e1",
                blobId = "b1",
                threadId = "t1",
                mailboxIds = mapOf("m1" to true),
                receivedAt = Instant.parse("2024-06-01T12:00:00Z"),
            )
        val decoded = json.decodeFromString<Email>(json.encodeToString(email))
        assertEquals(email, decoded)
        assertEquals("e1", decoded.id)
        assertEquals(false, decoded.hasAttachment)
    }

    @Test
    fun email_allFields_roundTrip() {
        val email =
            Email(
                id = "e2",
                blobId = "b2",
                threadId = "t2",
                mailboxIds = mapOf("m1" to true, "m2" to false),
                keywords = mapOf(EmailKeyword.SEEN to true, EmailKeyword.FLAGGED to false),
                subject = "Hello",
                sentAt = Instant.parse("2024-06-01T11:59:00Z"),
                receivedAt = Instant.parse("2024-06-01T12:00:00Z"),
                from = listOf(EmailAddress("Alice", "alice@example.com")),
                to = listOf(EmailAddress(email = "bob@example.com")),
                cc = listOf(EmailAddress("Carol", "carol@example.com")),
                replyTo = listOf(EmailAddress(email = "noreply@example.com")),
                preview = "Hello there",
                hasAttachment = true,
                bodyValues = mapOf("1" to EmailBodyValue("body text")),
                textBody = listOf(EmailBodyPart(partId = "1", type = "text/plain")),
                htmlBody = listOf(EmailBodyPart(partId = "2", type = "text/html")),
                attachments = listOf(EmailBodyPart(blobId = "blob2", type = "application/pdf", name = "doc.pdf")),
            )
        val decoded = json.decodeFromString<Email>(json.encodeToString(email))
        assertEquals(email, decoded)
        assertEquals("Hello", decoded.subject)
        assertEquals(true, decoded.hasAttachment)
        assertEquals(1, decoded.attachments.size)
    }

    @Test
    fun emailKeyword_constants() {
        assertEquals("\$seen", EmailKeyword.SEEN)
        assertEquals("\$flagged", EmailKeyword.FLAGGED)
        assertEquals("\$answered", EmailKeyword.ANSWERED)
        assertEquals("\$draft", EmailKeyword.DRAFT)
    }

    @Test
    fun emailDraft_construction() {
        val draft =
            EmailDraft(
                from = EmailAddress("Alice", "alice@example.com"),
                to = listOf(EmailAddress(email = "bob@example.com")),
                subject = "Test subject",
                textBody = "Body text",
            )
        assertEquals("Test subject", draft.subject)
        assertEquals("Body text", draft.textBody)
        assertEquals(emptyList(), draft.cc)
        assertNull(draft.inReplyToEmailId)
    }

    @Test
    fun emailDraft_withReply() {
        val draft =
            EmailDraft(
                from = EmailAddress(email = "alice@example.com"),
                to = listOf(EmailAddress(email = "bob@example.com")),
                cc = listOf(EmailAddress(email = "carol@example.com")),
                subject = "Re: Test",
                textBody = "Reply text",
                inReplyToEmailId = "orig-id",
            )
        assertEquals("orig-id", draft.inReplyToEmailId)
        assertEquals(1, draft.cc.size)
    }
}
