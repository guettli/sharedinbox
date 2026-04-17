import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/open.dart';

import 'package:sharedinbox/data/db/database.dart';

/// Call once per test file (e.g. in setUpAll) before creating any AppDatabase.
void configureSqliteForTests() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => DynamicLibrary.open('/usr/lib/x86_64-linux-gnu/libsqlite3.so.0'),
    );
  }
}

AppDatabase openTestDatabase() => AppDatabase(NativeDatabase.memory());
