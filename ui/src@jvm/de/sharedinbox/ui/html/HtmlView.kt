package de.sharedinbox.ui.html

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
actual fun HtmlView(
    html: String,
    blockNetworkImages: Boolean,
    modifier: Modifier,
) {
    Text(
        text = htmlToPlainText(html),
        style = MaterialTheme.typography.bodyMedium,
        modifier = modifier,
    )
}

private fun htmlToPlainText(html: String): String {
    val blockTags = Regex("<(br|p|div|tr|li|h[1-6])(\\s[^>]*)?/?>", RegexOption.IGNORE_CASE)
    val anyTag = Regex("<[^>]+>")
    val entities =
        mapOf(
            "&amp;" to "&",
            "&lt;" to "<",
            "&gt;" to ">",
            "&quot;" to "\"",
            "&apos;" to "'",
            "&nbsp;" to " ",
            "&#39;" to "'",
            "&#160;" to " ",
        )
    var text = blockTags.replace(html, "\n")
    text = anyTag.replace(text, "")
    for ((entity, replacement) in entities) {
        text = text.replace(entity, replacement, ignoreCase = true)
    }
    text = Regex("\n{3,}").replace(text, "\n\n")
    return text.trim()
}
