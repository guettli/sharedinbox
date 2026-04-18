import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

// ── Tables ────────────────────────────────────────────────────────────────────

class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get email => text()();
  TextColumn get imapHost => text()();
  IntColumn get imapPort => integer()();
  BoolColumn get imapSsl => boolean()();
  TextColumn get smtpHost => text()();
  IntColumn get smtpPort => integer()();
  BoolColumn get smtpSsl => boolean()();
  // Added in schema v2:
  TextColumn get accountType =>
      text().withDefault(const Constant('imap'))();
  TextColumn get jmapUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MailboxRow')
class Mailboxes extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get path => text()();
  TextColumn get name => text()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  IntColumn get totalCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Emails extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get mailboxPath => text()();
  IntColumn get uid => integer()();
  TextColumn get subject => text().nullable()();
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get receivedAt => dateTime()();
  // JSON-encoded List<{name,email}>
  TextColumn get fromJson => text().withDefault(const Constant('[]'))();
  TextColumn get toAddresses => text().withDefault(const Constant('[]'))();
  TextColumn get ccJson => text().withDefault(const Constant('[]'))();
  TextColumn get preview => text().nullable()();
  BoolColumn get isSeen => boolean().withDefault(const Constant(false))();
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();
  BoolColumn get hasAttachment =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

class EmailBodies extends Table {
  TextColumn get emailId =>
      text().references(Emails, #id, onDelete: KeyAction.cascade)();
  TextColumn get textBody => text().nullable()();
  TextColumn get htmlBody => text().nullable()();
  // JSON-encoded List<{filename,contentType,size}>
  TextColumn get attachmentsJson =>
      text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {emailId};
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(tables: [Accounts, Mailboxes, Emails, EmailBodies])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(accounts, accounts.accountType);
            await m.addColumn(accounts, accounts.jmapUrl);
          }
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'sharedinbox.db'));
    return NativeDatabase.createInBackground(file);
  });
}
