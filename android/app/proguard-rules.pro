# integration_test is a dev dependency; its plugin class is referenced in
# GeneratedPluginRegistrant.java but not bundled in release. Suppress R8 warnings
# for its transitive Guava dependency.
-dontwarn com.google.common.util.concurrent.SettableFuture

# Keep Flutter embedding entry points so plugin registration and JNI dispatch
# survive R8 shrinking. Each plugin ships its own consumer-proguard rules, so
# we only add the framework-level keeps here.
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }

# workmanager looks up the WorkerFactory and worker classes via reflection at
# runtime; without this keep the background-sync worker is stripped.
-keep class be.tramckrijte.workmanager.** { *; }
