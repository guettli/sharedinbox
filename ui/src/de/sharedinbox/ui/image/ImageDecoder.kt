package de.sharedinbox.ui.image

import androidx.compose.ui.graphics.ImageBitmap

/** Decodes raw image bytes (JPEG, PNG, GIF, WebP) to an [ImageBitmap], or null on failure. */
expect fun decodeImage(bytes: ByteArray): ImageBitmap?
