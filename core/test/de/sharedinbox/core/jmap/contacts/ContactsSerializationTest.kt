package de.sharedinbox.core.jmap.contacts

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ContactsSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun contactEmail_roundTrip() {
        val email = ContactEmail(address = "alice@example.com")
        val decoded = json.decodeFromString<ContactEmail>(json.encodeToString(email))
        assertEquals("alice@example.com", decoded.address)
        assertEquals("EmailAddress", decoded.type)
    }

    @Test
    fun contactEmail_customType_roundTrip() {
        val email = ContactEmail(type = "work", address = "alice@work.example.com")
        val decoded = json.decodeFromString<ContactEmail>(json.encodeToString(email))
        assertEquals("work", decoded.type)
        assertEquals("alice@work.example.com", decoded.address)
    }

    @Test
    fun contactCard_minimal_roundTrip() {
        val card = ContactCard(id = "card1")
        val decoded = json.decodeFromString<ContactCard>(json.encodeToString(card))
        assertEquals("card1", decoded.id)
        assertNull(decoded.fullName)
        assertEquals(emptyMap(), decoded.emails)
    }

    @Test
    fun contactCard_full_roundTrip() {
        val card = ContactCard(
            id = "card2",
            fullName = "Alice Smith",
            emails = mapOf("work" to ContactEmail(address = "alice@example.com")),
        )
        val decoded = json.decodeFromString<ContactCard>(json.encodeToString(card))
        assertEquals("card2", decoded.id)
        assertEquals("Alice Smith", decoded.fullName)
        assertEquals(1, decoded.emails.size)
        assertEquals("alice@example.com", decoded.emails["work"]?.address)
    }

    @Test
    fun contactCard_multipleEmails() {
        val card = ContactCard(
            id = "card3",
            fullName = "Bob",
            emails = mapOf(
                "home" to ContactEmail(address = "bob@home.example.com"),
                "work" to ContactEmail(address = "bob@work.example.com"),
            ),
        )
        assertEquals(2, card.emails.size)
    }

    @Test
    fun contactCard_ignoresUnknownFields() {
        val wireJson = """{"id":"c1","fullName":"Alice","emails":{},"unknownField":"x"}"""
        val card = json.decodeFromString<ContactCard>(wireJson)
        assertEquals("c1", card.id)
    }
}
