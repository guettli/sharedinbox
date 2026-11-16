import 'package:drift/drift.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import '../db_test_helper.dart';
import 'fake_secure_storage.dart';
import 'stateful_fake_imap.dart';

/// The IMAP account of a [StatefulImapRig].
const statefulRigAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

/// An [EmailRepositoryImpl] on a fresh database, talking to [server] as
/// [statefulRigAccount], with a mailbox row for each folder (path, role)
/// and INBOX synced once. Its clock is [now], which a test may move.
class StatefulImapRig {
  StatefulImapRig._(this.server, this.db);

  final StatefulFakeImapServer server;
  final AppDatabase db;
  late final EmailRepositoryImpl emails;
  DateTime now = DateTime.utc(2026, 11, 16, 12);

  static Future<StatefulImapRig> open(
    StatefulFakeImapServer server, {
    required List<(String, String)> folders,
  }) async {
    final rig = StatefulImapRig._(server, openTestDatabase());
    final db = rig.db;
    final accounts = AccountRepositoryImpl(db, FakeSecureStorage());
    rig.emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: (_, __, ___) async => server.connect(),
      smtpConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no SMTP in this test')),
      fetchObjectIds: (_, __, ___) async => const {},
      fetchPreviewSnippets: (_, __, ___) async => const {},
      now: () => rig.now,
    );
    await accounts.addAccount(statefulRigAccount, 'pw');
    for (final (path, role) in folders) {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: '${statefulRigAccount.id}:$path',
              accountId: statefulRigAccount.id,
              path: path,
              name: path,
              role: Value(role),
            ),
          );
    }
    await rig.emails.syncEmails(statefulRigAccount.id, 'INBOX');
    return rig;
  }
}

/// The rig of the running test, opened in its `setUp`; the getters below
/// read it, so a suite can say `db` and `emails` like any other.
late StatefulImapRig rig;
AppDatabase get db => rig.db;
EmailRepositoryImpl get emails => rig.emails;
StatefulFakeImapServer get server => rig.server;
DateTime get now => rig.now;
set now(DateTime value) => rig.now = value;
