package de.sharedinbox.mua

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Writes raw .eml content to the user's public Downloads folder so the
 * system file picker surfaces it under "Recently used".
 *
 * - API 29+ uses MediaStore.Downloads (no runtime permission required and
 *   the file is automatically indexed by DocumentsUI).
 * - API < 29 falls back to writing into the legacy public Downloads
 *   directory. WRITE_EXTERNAL_STORAGE is not requested because we do not
 *   target devices older than API 23 and the legacy path is unavailable on
 *   newer scoped-storage devices anyway.
 */
class RawEmailDownloader(messenger: BinaryMessenger, private val context: Context) {
    private val channel = MethodChannel(messenger, CHANNEL)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val filename = call.argument<String>("filename")
                    val content = call.argument<String>("content")
                    if (filename.isNullOrEmpty() || content == null) {
                        result.error("INVALID_ARGS", "filename and content are required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveToDownloads(filename, content))
                    } catch (e: Exception) {
                        result.error("WRITE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun saveToDownloads(filename: String, content: String): String {
        val bytes = content.toByteArray(Charsets.UTF_8)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return saveViaMediaStore(filename, bytes)
        }
        return saveLegacy(filename, bytes)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveViaMediaStore(filename: String, bytes: ByteArray): String {
        val resolver = context.contentResolver
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.MIME_TYPE, "message/rfc822")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("MediaStore.insert returned null")
        try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IllegalStateException("openOutputStream returned null")
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        val finalize = ContentValues().apply {
            put(MediaStore.Downloads.IS_PENDING, 0)
        }
        resolver.update(uri, finalize, null, null)
        return uri.toString()
    }

    @Suppress("DEPRECATION")
    private fun saveLegacy(filename: String, bytes: ByteArray): String {
        val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("Could not create Downloads directory: ${dir.absolutePath}")
        }
        val file = File(dir, filename)
        file.writeBytes(bytes)
        return file.absolutePath
    }

    companion object {
        const val CHANNEL = "sharedinbox/raw_email_downloader"
    }
}
