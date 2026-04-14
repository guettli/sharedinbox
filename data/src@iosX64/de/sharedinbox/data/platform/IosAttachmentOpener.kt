package de.sharedinbox.data.platform

import de.sharedinbox.core.platform.AttachmentOpener

class IosAttachmentOpener : AttachmentOpener {
    override fun open(
        bytes: ByteArray,
        filename: String,
        mimeType: String,
    ) {
        // TODO: use UIDocumentInteractionController
    }
}
