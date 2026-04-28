package dev.flutter.plugins.integration_test;

import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * No-op stub used in release builds.
 * The real IntegrationTestPlugin lives in the integration_test SDK package
 * which is a dev-only dependency. GeneratedPluginRegistrant references it in
 * all build variants, so without this stub the release build throws
 * NoClassDefFoundError at startup, aborting plugin registration entirely.
 */
public class IntegrationTestPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {}

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}
}
