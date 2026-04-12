package de.sharedinbox.desktop

import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = "SharedInbox",
    ) {
        // TODO Phase 10: App()
    }
}
