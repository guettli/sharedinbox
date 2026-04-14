package de.sharedinbox.core.jmap.sieve

import kotlinx.serialization.Serializable

/**
 * A Sieve script stored on the server (JMAP Sieve, draft-ietf-extra-jmap-sieve).
 *
 * [blobId] points to the script content and can be downloaded via the JMAP blob endpoint.
 * [isActive] is true when this is the script currently executed for incoming mail.
 */
@Serializable
data class SieveScript(
    val id: String = "",
    val name: String? = null,
    val blobId: String = "",
    val isActive: Boolean = false,
)
