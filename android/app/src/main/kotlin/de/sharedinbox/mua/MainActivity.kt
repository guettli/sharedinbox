package de.sharedinbox.mua

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var rawEmailDownloader: RawEmailDownloader? = null
    private var mailIntentBridge: MailIntentBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        rawEmailDownloader = RawEmailDownloader(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
        mailIntentBridge = MailIntentBridge(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        ).also { it.initialIntent = intent }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // singleTop keeps a single activity instance, so a new "compose
        // email" intent arrives here instead of via configureFlutterEngine.
        // The bridge forwards it to Dart via its EventChannel.
        mailIntentBridge?.deliver(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        rawEmailDownloader?.dispose()
        rawEmailDownloader = null
        mailIntentBridge?.dispose()
        mailIntentBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
