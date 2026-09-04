import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Deterministic app version injected into code that stamps it (e.g. the
/// outbox `User-Agent` header) so tests can assert a stable value.
const testAppVersion = '9.9.9';

/// Call once per test file (e.g. in setUpAll) before creating any AppDatabase.
void configureSqliteForTests() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
}

AppDatabase openTestDatabase() => AppDatabase(NativeDatabase.memory());
