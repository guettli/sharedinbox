package de.sharedinbox.ui.html

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

/**
 * Renders [html] content using the platform's native web view.
 *
 * @param html raw HTML string to display
 * @param blockNetworkImages when true, remote images are suppressed until the user approves
 * @param modifier layout modifier applied to the view
 */
@Composable
expect fun HtmlView(
    html: String,
    blockNetworkImages: Boolean,
    modifier: Modifier = Modifier,
)
