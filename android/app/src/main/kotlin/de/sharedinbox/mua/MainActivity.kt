package de.sharedinbox.mua

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var rawEmailDownloader: RawEmailDownloader? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        rawEmailDownloader = RawEmailDownloader(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        rawEmailDownloader?.dispose()
        rawEmailDownloader = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
