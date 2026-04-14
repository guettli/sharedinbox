package de.sharedinbox.core.repository

/**
 * Tracks which emails the user has explicitly trusted to load images.
 *
 * Trust is persistent: once granted for an email it survives app restarts.
 * Users grant trust by tapping "Load images" in the email detail view.
 */
interface ImageTrustRepository {
    /** Returns true if the user has granted image-load trust for this email. */
    suspend fun isTrusted(
        accountId: String,
        emailId: String,
    ): Boolean

    /** Grants image-load trust for [emailId]. Idempotent. */
    suspend fun grantTrust(
        accountId: String,
        emailId: String,
    )
}
