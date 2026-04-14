package de.sharedinbox.core.platform

/**
 * Platform-specific handler for opening a downloaded attachment.
 *
 * JVM: saves to a temp file and opens it with the OS default viewer.
 * Android/iOS: stub — can be extended later.
 */
interface AttachmentOpener {
    fun open(bytes: ByteArray, filename: String, mimeType: String)
}
