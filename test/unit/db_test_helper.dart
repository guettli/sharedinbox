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
