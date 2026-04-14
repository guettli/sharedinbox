package de.sharedinbox.data.platform

import de.sharedinbox.core.platform.AttachmentOpener
import java.awt.Desktop
import java.io.File

class JvmAttachmentOpener : AttachmentOpener {
    override fun open(
        bytes: ByteArray,
        filename: String,
        mimeType: String,
    ) {
        val suffix = filename.substringAfterLast('.', "").let { if (it.isNotBlank()) ".$it" else "" }
        val tmp = File.createTempFile("sharedinbox-", suffix)
        tmp.deleteOnExit()
        tmp.writeBytes(bytes)
        if (Desktop.isDesktopSupported()) {
            Desktop.getDesktop().open(tmp)
        }
    }
}
