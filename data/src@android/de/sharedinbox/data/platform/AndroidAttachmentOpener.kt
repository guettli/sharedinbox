package de.sharedinbox.data.platform

import de.sharedinbox.core.platform.AttachmentOpener

class AndroidAttachmentOpener : AttachmentOpener {
    override fun open(bytes: ByteArray, filename: String, mimeType: String) {
        // TODO: save to Downloads folder and open with Intent
    }
}
