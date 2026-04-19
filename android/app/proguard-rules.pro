# integration_test is a dev dependency; its plugin class is referenced in
# GeneratedPluginRegistrant.java but not bundled in release. Suppress R8 warnings
# for its transitive Guava dependency.
-dontwarn com.google.common.util.concurrent.SettableFuture
