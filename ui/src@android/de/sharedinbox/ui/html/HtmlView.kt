package de.sharedinbox.ui.html

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

@Composable
actual fun HtmlView(
    html: String,
    blockNetworkImages: Boolean,
    modifier: Modifier,
) {
    var contentHeightDp by remember { mutableIntStateOf(0) }

    AndroidView(
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.blockNetworkImage = blockNetworkImages
                isVerticalScrollBarEnabled = false
                webViewClient =
                    object : WebViewClient() {
                        override fun onPageFinished(
                            view: WebView?,
                            url: String?,
                        ) {
                            // Measure content height in CSS pixels (≈ dp on Android)
                            view?.evaluateJavascript(
                                "(function() { return document.body.scrollHeight; })()",
                            ) { result ->
                                result?.toIntOrNull()?.let { contentHeightDp = it }
                            }
                        }
                    }
            }
        },
        update = { webView ->
            webView.settings.blockNetworkImage = blockNetworkImages
            webView.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
        },
        modifier =
            modifier.then(
                if (contentHeightDp > 0) Modifier.height(contentHeightDp.dp) else Modifier.height(200.dp),
            ),
    )
}
