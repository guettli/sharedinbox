package de.sharedinbox.desktop

import androidx.compose.ui.graphics.painter.BitmapPainter
import androidx.compose.ui.res.loadImageBitmap
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import de.sharedinbox.ui.App
import java.awt.Color
import java.awt.Font
import java.awt.RenderingHints
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO

fun main() = application {
    val windowState = rememberWindowState()
    val icon = BitmapPainter(loadImageBitmap(ByteArrayInputStream(appIconBytes())))

    Tray(
        icon = icon,
        tooltip = "SharedInbox",
        menu = {
            Item("Open SharedInbox") { windowState.isMinimized = false }
            Separator()
            Item("Quit") { exitApplication() }
        },
    )

    Window(
        onCloseRequest = { windowState.isMinimized = true },
        state = windowState,
        title = "SharedInbox",
        icon = icon,
    ) {
        App()
    }
}

/** Renders a simple "@" icon into a PNG byte array. */
private fun appIconBytes(): ByteArray {
    val size = 64
    val image = BufferedImage(size, size, BufferedImage.TYPE_INT_ARGB)
    val g = image.createGraphics()
    g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)
    g.color = Color(0x1565C0)
    g.fillOval(0, 0, size, size)
    g.color = Color.WHITE
    g.font = Font("Dialog", Font.BOLD, 36)
    val fm = g.fontMetrics
    val text = "@"
    g.drawString(text, (size - fm.stringWidth(text)) / 2, (size + fm.ascent - fm.descent) / 2)
    g.dispose()
    val out = ByteArrayOutputStream()
    ImageIO.write(image, "PNG", out)
    return out.toByteArray()
}
