package de.sharedinbox.core.jmap.contacts

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * RFC 9610 / JSContact (RFC 9553) — a single contact card.
 *
 * Only the fields needed for autocomplete are deserialised; the rest are
 * ignored via [ignoreUnknownKeys].
 */
@Serializable
data class ContactCard(
    val id: String,
    /** JSContact `fullName` — display name of the contact. */
    val fullName: String? = null,
    /** JSContact `emails` — map of label → email entry. */
    val emails: Map<String, ContactEmail> = emptyMap(),
)

@Serializable
data class ContactEmail(
    @SerialName("@type") val type: String = "EmailAddress",
    val address: String,
)
