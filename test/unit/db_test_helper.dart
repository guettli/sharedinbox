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

/// Inserts a bare account row [id] (type [accountType]) into [db], unless
/// it exists. Foreign keys are on, so a test needs it before it inserts any
/// row that belongs to the account (mailboxes, emails, sync state, logs).
Future<void> seedAccountRow(
  AppDatabase db,
  String id, {
  String accountType = 'imap',
}) =>
    db.into(db.accounts).insert(
          AccountsCompanion.insert(
            id: id,
            displayName: id,
            email: '$id@example.com',
            imapHost: 'imap.example.com',
            imapPort: 993,
            imapSsl: true,
            smtpHost: 'smtp.example.com',
            smtpPort: 465,
            smtpSsl: true,
            accountType: Value(accountType),
          ),
          mode: InsertMode.insertOrIgnore,
        );

/// Runs [body] with foreign keys off, to seed rows that builds before
/// schema v62 could leave behind (rows of a removed account, bodies of
/// deleted emails).
Future<void> withoutForeignKeys(
  AppDatabase db,
  Future<void> Function() body,
) async {
  await db.customStatement('PRAGMA foreign_keys = OFF');
  try {
    await body();
  } finally {
    await db.customStatement('PRAGMA foreign_keys = ON');
  }
}

/// [openTestDatabase] with a bare account row for each of [accountIds].
Future<AppDatabase> openTestDatabaseWithAccounts(
  List<String> accountIds,
) async {
  final db = openTestDatabase();
  for (final id in accountIds) {
    await seedAccountRow(db, id);
  }
  return db;
}

/// Inserts the `INBOX` mailbox (role `inbox`) for [accountId] into [db] —
/// shared seed so suites don't each re-declare the same companion.
Future<void> seedInboxMailbox(AppDatabase db, String accountId) =>
    db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: '$accountId:INBOX',
            accountId: accountId,
            path: 'INBOX',
            name: 'INBOX',
            role: const Value('inbox'),
          ),
        );
