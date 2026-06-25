package de.sharedinbox.mua

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Forwards "compose a new email" intents from Android to Dart.
 *
 * Supports:
 *  - `ACTION_VIEW` / `ACTION_SENDTO` with a `mailto:` URI
 *    (browsers, contacts app, address-book clicks).
 *  - `ACTION_SEND` / `ACTION_SEND_MULTIPLE` from the system share sheet —
 *    text becomes the body, content:// URIs are copied to the app cache so
 *    Dart can reach them as plain file paths.
 *
 * The cold-start path uses a MethodChannel (`getInitialIntent`); the warm
 * path uses an EventChannel, so an intent arriving via `onNewIntent` after
 * the Flutter engine is already running still reaches Dart.
 */
class MailIntentBridge(messenger: BinaryMessenger, private val context: Context) {
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    /**
     * The launch intent. Consumed by [getInitialIntent] so a foreground
     * configuration change does not replay the same intent twice.
     */
    var initialIntent: Intent? = null

    init {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> {
                    val intent = initialIntent
                    initialIntent = null
                    result.success(intent?.let { parseIntent(it) })
                }
                else -> result.notImplemented()
            }
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    /** Called from `MainActivity.onNewIntent` for warm-start intents. */
    fun deliver(intent: Intent) {
        val parsed = parseIntent(intent) ?: return
        eventSink?.success(parsed)
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    private fun parseIntent(intent: Intent): Map<String, Any?>? {
        return when (intent.action) {
            Intent.ACTION_VIEW, Intent.ACTION_SENDTO -> parseMailto(intent)
            Intent.ACTION_SEND -> parseSend(intent, multiple = false)
            Intent.ACTION_SEND_MULTIPLE -> parseSend(intent, multiple = true)
            else -> null
        }
    }

    private fun parseMailto(intent: Intent): Map<String, Any?>? {
        val data = intent.data ?: return null
        if (data.scheme != "mailto") return null
        return parseMailtoUri(data)
    }

    private fun parseSend(intent: Intent, multiple: Boolean): Map<String, Any?> {
        val to = intent.getStringArrayExtra(Intent.EXTRA_EMAIL)?.joinToString(", ")
        val cc = intent.getStringArrayExtra(Intent.EXTRA_CC)?.joinToString(", ")
        val bcc = intent.getStringArrayExtra(Intent.EXTRA_BCC)?.joinToString(", ")
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val body = intent.getStringExtra(Intent.EXTRA_TEXT)
        val attachments = collectAttachments(intent, multiple)
        return mapOf(
            "to" to to,
            "cc" to cc,
            "bcc" to bcc,
            "subject" to subject,
            "body" to body,
            "attachmentPaths" to attachments,
        )
    }

    private fun collectAttachments(intent: Intent, multiple: Boolean): List<String> {
        val uris: List<Uri> = if (multiple) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        } else {
            @Suppress("DEPRECATION")
            val single = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (single == null) emptyList() else listOf(single)
        }
        if (uris.isEmpty()) return emptyList()
        val out = mutableListOf<String>()
        for (uri in uris) {
            val copied = copyToCache(uri) ?: continue
            out.add(copied)
        }
        return out
    }

    /**
     * Copies a content:// (or file://) URI to the app cache so the Dart side
     * can treat it as a regular file path. Returns null on any I/O failure;
     * the rest of the attachments still go through.
     */
    private fun copyToCache(uri: Uri): String? {
        val resolver = context.contentResolver
        val name = queryDisplayName(resolver, uri) ?: "attachment-${UUID.randomUUID()}"
        val safeName = name.replace(File.separatorChar, '_')
        val dir = File(context.cacheDir, "mail_intent_attachments").apply { mkdirs() }
        // Prefix with a UUID so two attachments with the same display name
        // don't clobber each other.
        val dest = File(dir, "${UUID.randomUUID()}-$safeName")
        return try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(dest).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            dest.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (!c.moveToFirst()) return@use null
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx < 0) null else c.getString(idx)
            }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        const val METHOD_CHANNEL = "sharedinbox/mail_intent"
        const val EVENT_CHANNEL = "sharedinbox/mail_intent_events"

        /**
         * Parses a `mailto:` URI per RFC 6068. Public so unit-test fixtures
         * can exercise the parser without an Activity.
         *
         *  - The path is treated as a comma-separated recipient list.
         *  - Query keys `cc`, `bcc`, `subject`, `body` (case-insensitive)
         *    populate the corresponding fields. Multiple values for the same
         *    key are joined with ", ".
         *  - Unknown query keys are ignored.
         */
        @JvmStatic
        fun parseMailtoUri(uri: Uri): Map<String, Any?> {
            val ssp = uri.schemeSpecificPart.orEmpty()
            val queryStart = ssp.indexOf('?')
            val rawTo = if (queryStart < 0) ssp else ssp.substring(0, queryStart)
            val to = if (rawTo.isEmpty()) null else Uri.decode(rawTo)

            // We can't use Uri.getQueryParameter — Android's parser only
            // recognises queries on hierarchical (`//`) URIs.
            val rawQuery = if (queryStart < 0) "" else ssp.substring(queryStart + 1)
            val params = mutableMapOf<String, MutableList<String>>()
            if (rawQuery.isNotEmpty()) {
                for (pair in rawQuery.split('&')) {
                    if (pair.isEmpty()) continue
                    val eq = pair.indexOf('=')
                    val key = if (eq >= 0) pair.substring(0, eq) else pair
                    val value = if (eq >= 0) pair.substring(eq + 1) else ""
                    val decodedKey = Uri.decode(key).lowercase()
                    val decodedValue = Uri.decode(value)
                    params.getOrPut(decodedKey) { mutableListOf() }.add(decodedValue)
                }
            }
            return mapOf(
                "to" to to,
                "cc" to params["cc"]?.joinToString(", "),
                "bcc" to params["bcc"]?.joinToString(", "),
                "subject" to params["subject"]?.joinToString(", "),
                "body" to params["body"]?.joinToString("\n"),
                "attachmentPaths" to emptyList<String>(),
            )
        }
    }
}
