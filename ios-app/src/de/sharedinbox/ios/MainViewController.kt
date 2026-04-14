package de.sharedinbox.ios

import androidx.compose.ui.window.ComposeUIViewController
import de.sharedinbox.ui.App

@Suppress("FunctionName", "unused") // called from Swift
fun MainViewController() = ComposeUIViewController {
    App()
}
