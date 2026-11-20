import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart' show setUp, setUpAll, tearDown;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import '../db_test_helper.dart';
import '../recording_app_log_repository.dart';
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
  late final AccountRepositoryImpl accounts;
  late final EmailRepositoryImpl emails;

  /// The mailbox repository on the same database and server (folder
  /// listings, and the folder actions it queues).
  late final MailboxRepositoryImpl mailboxes;
  DateTime now = DateTime.utc(2026, 11, 16, 12);

  /// The repository's cache folder (attachment downloads), a fresh temp
  /// folder per rig, made when first asked for.
  late final Directory cacheDir =
      Directory.systemTemp.createTempSync('stateful_imap_rig');

  static Future<StatefulImapRig> open(
    StatefulFakeImapServer server, {
    required List<(String, String)> folders,
    AppLogger? appLogger,
    OverlayConsistencySampler? consistencySampler,
  }) async {
    final rig = StatefulImapRig._(server, openTestDatabase());
    final db = rig.db;
    final accounts =
        rig.accounts = AccountRepositoryImpl(db, FakeSecureStorage());
    rig.mailboxes = MailboxRepositoryImpl(
      db,
      accounts,
      imapConnect: (_, __, ___) async => server.connect(),
      appLogger: appLogger,
      now: () => rig.now,
    );
    rig.emails = EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: (_, __, ___) async => server.connect(),
      smtpConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no SMTP in this test')),
      // Asked only when the server advertises OBJECTID.
      fetchObjectIds: (client, sequence, _) =>
          (client as StatefulFakeImapClient).emailIdsOf(sequence),
      fetchPreviewSnippets: (_, __, ___) async => const {},
      now: () => rig.now,
      appLogger: appLogger,
      consistencySampler: consistencySampler,
      getCacheDir: () async => rig.cacheDir,
    );
    await accounts.addAccount(statefulRigAccount, 'pw');
    for (final (path, role) in folders) {
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: '${statefulRigAccount.id}:$path',
              accountId: statefulRigAccount.id,
              path: path,
              name: path,
              srvName: Value(path),
              role: Value(role),
            ),
          );
    }
    await rig.emails.syncEmails(statefulRigAccount.id, 'INBOX');
    return rig;
  }
}

/// Opens [rig] for a test about one mail, `a@test`, in INBOX, with a filler
/// mail in Archive (so a mail moved there gets another UID than it had in
/// INBOX) and Archive synced too. The App Log goes to the returned recorder.
Future<RecordingAppLogRepository> openRigWithMailA({
  required Map<String, int> uidValidityByFolder,
  required List<(String, String)> folders,
  bool objectIds = false,
}) async {
  final logs = RecordingAppLogRepository();
  rig = await StatefulImapRig.open(
    StatefulFakeImapServer(
      uidValidityByFolder: uidValidityByFolder,
      objectIds: objectIds,
    )
      ..deliver('INBOX', 'a@test')
      ..deliver('Archive', 'filler@test'),
    folders: folders,
    appLogger: AppLogger(logs),
  );
  await rig.emails.syncEmails(statefulRigAccount.id, 'Archive');
  return logs;
}

/// [openRigWithMailA] with INBOX (UIDVALIDITY 11) and Archive (22) and no
/// Trash folder, so a delete is a delete for good.
Future<RecordingAppLogRepository> openRigInboxArchive() => openRigWithMailA(
      uidValidityByFolder: {'INBOX': 11, 'Archive': 22},
      folders: [('INBOX', 'inbox'), ('Archive', 'archive')],
    );

/// [openRigInboxArchive], then the mails [inbox] (Message-ID → flags)
/// delivered to INBOX after `a@test`, and INBOX synced again.
Future<RecordingAppLogRepository> openRigInboxArchiveWith(
  Map<String, List<String>> inbox,
) async {
  final logs = await openRigInboxArchive();
  for (final MapEntry(key: messageId, value: flags) in inbox.entries) {
    server.deliver('INBOX', messageId, flags: flags);
  }
  await emails.syncEmails(statefulRigAccount.id, 'INBOX');
  return logs;
}

/// Registers the suite's setup: each test opens the rig with
/// [openRigInboxArchiveWith] ([inbox]), hands its App Log recorder to
/// [onLogs], and closes the database afterwards.
void useRigInboxArchive(
  Map<String, List<String>> inbox,
  void Function(RecordingAppLogRepository logs) onLogs,
) {
  setUpAll(configureSqliteForTests);
  setUp(() async => onLogs(await openRigInboxArchiveWith(inbox)));
  tearDown(() => db.close());
}

/// The rows of the mail [messageId] in the rig's database.
Future<List<Email>> rigRowsOf(String messageId) =>
    (db.select(db.emails)..where((t) => t.messageId.equals(messageId))).get();

/// Lists the rig account's folders (IMAP `LIST`, through the mailbox
/// repository), as every sync cycle does first.
Future<void> rigListFolders() =>
    rig.mailboxes.syncMailboxes(statefulRigAccount.id);

/// Caches [text] as the body of row [emailId] in the rig's database.
Future<void> rigAddBody(String emailId, String text) =>
    db.into(db.emailBodies).insert(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value(text),
          ),
        );

/// The cached text body of row [emailId], or null.
Future<String?> rigBodyOf(String emailId) async => (await (db.select(
      db.emailBodies,
    )..where((t) => t.emailId.equals(emailId)))
            .getSingleOrNull())
        ?.textBody;

/// The queued changes of the rig's database.
Future<List<PendingChangeRow>> rigOps() => db.select(db.pendingChanges).get();

/// The overlay invariants the rig's database breaks (none, normally).
Future<List<ConsistencyProblem>> rigProblems() =>
    EmailStateWriter(db).consistencyProblems();

/// The rows of `a@test` ([openRigWithMailA]).
Future<List<Email>> rowsOfA() =>
    (db.select(db.emails)..where((t) => t.messageId.equals('a@test'))).get();

/// The one row of `a@test`.
Future<Email> rowOfA() async => (await rowsOfA()).single;

/// The rig of the running test, opened in its `setUp`; the getters below
/// read it, so a suite can say `db` and `emails` like any other.
late StatefulImapRig rig;
AppDatabase get db => rig.db;
EmailRepositoryImpl get emails => rig.emails;
StatefulFakeImapServer get server => rig.server;
DateTime get now => rig.now;
set now(DateTime value) => rig.now = value;
