import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'package:sharedinbox/data/db/database.dart';

/// Call once per test file (e.g. in setUpAll) before creating any AppDatabase.
void configureSqliteForTests() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
}

AppDatabase openTestDatabase() => AppDatabase(NativeDatabase.memory());
