import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:sharedinbox/data/db/database.dart';

/// Deterministic app version stamped for tests. Code that reads the version at
/// runtime (e.g. the outbox User-Agent header) sees this value.
const testAppVersion = '9.9.9';

/// Call once per test file (e.g. in setUpAll) before creating any AppDatabase.
void configureSqliteForTests() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
}

/// Prime [PackageInfo.fromPlatform] with a fixed value so code paths that read
/// the app version work under `flutter test` without a platform channel. This
/// only sets a static cache, so it is safe to call from `package:test` suites
/// that have no Flutter test binding.
void configurePackageInfoForTests() {
  PackageInfo.setMockInitialValues(
    appName: 'SharedInbox',
    packageName: 'org.sharedinbox',
    version: testAppVersion,
    buildNumber: '1',
    buildSignature: '',
  );
}

AppDatabase openTestDatabase() => AppDatabase(NativeDatabase.memory());
