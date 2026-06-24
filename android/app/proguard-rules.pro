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

# AndroidX WorkManager keeps its queue in a Room database whose generated
# implementation (androidx.work.impl.WorkDatabase_Impl) is instantiated
# reflectively by Room at process start, via androidx.startup's
# InitializationProvider. R8 stripped the generated no-arg constructor, so
# release builds crashed on launch before Flutter even started:
#   FATAL EXCEPTION: Unable to get provider androidx.startup.InitializationProvider
#   Caused by: NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
# Keep the no-arg constructor of every Room database implementation so Room's
# reflective lookup (Class.getDeclaredConstructor().newInstance()) succeeds. (#100)
-keep class * extends androidx.room.RoomDatabase { <init>(); }
