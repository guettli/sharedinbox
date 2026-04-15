package de.sharedinbox.ui.html

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import kotlinx.cinterop.ExperimentalForeignApi
import platform.CoreGraphics.CGRectZero
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration

@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun HtmlView(
    html: String,
    blockNetworkImages: Boolean,
    modifier: Modifier,
) {
    // Prepend a style block to hide images when they are not yet approved
    val content =
        if (blockNetworkImages) {
            "<style>img{display:none}</style>$html"
        } else {
            html
        }

    UIKitView(
        factory = {
            WKWebView(
                frame = CGRectZero.readValue(),
                configuration = WKWebViewConfiguration(),
            ).also { wv ->
                // Disable WKWebView's own scroll; the Compose column handles scrolling
                wv.scrollView.scrollEnabled = false
                wv.loadHTMLString(content, baseURL = null)
            }
        },
        update = { wv ->
            wv.loadHTMLString(content, baseURL = null)
        },
        modifier = modifier,
    )
}
