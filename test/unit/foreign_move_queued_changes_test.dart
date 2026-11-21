// Changes queued for a mail that another IMAP client then moves (#1326,
// #1327). Sent to the UID the mail left, a flag STORE answers OK and
// changes nothing, and a MOVE moves nothing: neither may count as done.
// A flag change is kept until the sync carries the row over to the mail's
// new place and is sent there; a move without a Message-ID fails visibly;
// a failed move's Retry goes where the mail is now.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _account = statefulRigAccount;
const _noMid = '${noMessageIdPrefix}x';

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;

  Future<void> open({bool objectIds = false, bool uidPlus = true}) async {
    logs = RecordingAppLogRepository();
    rig = await StatefulImapRig.open(
      StatefulFakeImapServer(
        uidValidityByFolder: {'INBOX': 11, 'Archive': 22, 'Jobs': 33},
        objectIds: objectIds,
        uidPlus: uidPlus,
      )
        ..deliver('INBOX', 'a@test')
        ..deliver('INBOX', _noMid)
        // So a mail moved to Archive gets another UID than it had in INBOX.
        ..deliver('Archive', 'filler@test'),
      folders: [('INBOX', 'inbox'), ('Archive', 'archive'), ('Jobs', '')],
      appLogger: AppLogger(logs),
    );
    await emails.syncEmails(_account.id, 'Archive');
    await emails.syncEmails(_account.id, 'Jobs');
  }

  tearDown(() => db.close());

  Future<void> sync(String folder) => emails.syncEmails(_account.id, folder);
  Future<void> flush() => emails.flushPendingChanges(_account.id, 'pw');

  Iterable<AppLogEntry> logsOf(String event) =>
      logs.rows.where((l) => l.event == event);

  Future<Email> rowOfNoMid() async => (await db.select(db.emails).get())
      .singleWhere((e) => e.messageId == null);

  Map<String, dynamic> payloadOf(PendingChangeRow change) =>
      jsonDecode(change.payload) as Map<String, dynamic>;

  group('#1326: a flag change queued before another client moved the mail', () {
    setUp(open);

    test('is not acked at the old UID, and is sent to the new place', () async {
      final id = (await rowOfA()).id;
      await emails.setFlag(id, seen: true);
      server.moveElsewhere('a@test', 'Archive');

      await flush();

      // The STORE hit nothing: not acked, not dropped.
      expect(server.find('a@test')!.message.seen, isFalse);
      final kept = (await unsettledChanges(db)).single;
      expect(kept.state, 'pending');
      expect(kept.lastError, contains('gone from INBOX'));
      final vanished = logsOf('pending_change.target_vanished').single;
      expect(vanished.level, AppLogLevel.warn);
      expect(vanished.emailId, id);
      expect(vanished.message, contains('Mail a@test'));

      // Source first: INBOX finds it gone, Archive adopts the row.
      await sync('INBOX');
      await sync('Archive');
      final payload = payloadOf((await unsettledChanges(db)).single);
      expect(
        (payload['mailboxPath'], payload['uid'], payload['srcVanished']),
        ('Archive', 2, null),
      );
      expect(
        logsOf('email.foreign_move_adopted').single.message,
        contains('1 queued change(s) of it now address it in Archive'),
      );

      await flush();

      expect(server.find('a@test')!.folder.path, 'Archive');
      expect(server.find('a@test')!.message.seen, isTrue);
      expect(await unsettledChanges(db), isEmpty);
      final e = await rowOfA();
      expect((e.id, e.mailboxPath, e.isSeen), (id, 'Archive', true));
      expect(await rigProblems(), isEmpty);
    });

    test('read and star follow it when the destination syncs first', () async {
      final id = (await rowOfA()).id;
      await emails.setFlag(id, seen: true);
      await emails.setFlag(id, flagged: true);
      server.moveElsewhere('a@test', 'Archive');

      await flush();
      expect(await unsettledChanges(db), hasLength(2));
      await sync('Archive');
      await sync('INBOX');
      await flush();

      final onServer = server.find('a@test')!;
      expect(onServer.folder.path, 'Archive');
      expect((onServer.message.seen, onServer.message.flagged), (true, true));
      expect(await unsettledChanges(db), isEmpty);
      expect((await rowOfA()).id, id);
    });

    test('a STORE answered without FETCH is checked by a FETCH of the UID',
        () async {
      server.storeAnswersFetch = false;
      final id = (await rowOfA()).id;
      await emails.setFlag(id, flagged: true);
      // A mail that is still there: the FETCH finds it, the change is done.
      await flush();
      expect(server.find('a@test')!.message.flagged, isTrue);
      expect(await unsettledChanges(db), isEmpty);

      await emails.setFlag(id, seen: true);
      server.moveElsewhere('a@test', 'Archive');
      await flush();
      expect(server.find('a@test')!.message.seen, isFalse);
      expect((await unsettledChanges(db)).single.state, 'pending');

      await sync('INBOX');
      await sync('Archive');
      await flush();
      expect(server.find('a@test')!.message.seen, isTrue);
      expect(await unsettledChanges(db), isEmpty);
    });

    test('fails visibly when the mail was deleted elsewhere', () async {
      final id = (await rowOfA()).id;
      await emails.setFlag(id, seen: true);
      server.expungeElsewhere('a@test');

      await flush();
      expect((await unsettledChanges(db)).single.state, 'pending');
      // The wait for a foreign move's destination ends: no folder has it.
      await sync('INBOX');
      await rigListFolders();
      await sync('Archive');
      await sync('Jobs');
      await flush();

      final failed = (await unsettledChanges(db)).single;
      expect(failed.state, 'failed');
      final gone = logsOf('pending_change.message_gone').single;
      expect(gone.level, AppLogLevel.warn);
      // The row goes with its last change settled; the change stays listed
      // with the mail's subject.
      await flush();
      expect(await rowsOfA(), isEmpty);
      final listed =
          (await emails.observePendingChanges(_account.id).first).single;
      expect(listed.id, failed.id);
      expect(listed.subject, 'Mail a@test');
    });
  });

  group('#1327: a queued move after another client moved the mail', () {
    test(
        'without a Message-ID, with EMAILID: flag and move follow it '
        '(destination first)', () async {
      await open(objectIds: true);
      final id = (await rowOfNoMid()).id;
      await emails.setFlag(id, seen: true);
      await emails.moveEmail(id, 'Jobs');
      server.moveElsewhere(_noMid, 'Archive');

      await flush();
      // Neither counts as done: the read change hit nothing, and the move
      // waits behind it.
      expect(server.find(_noMid)!.folder.path, 'Archive');
      expect(
        [for (final c in await unsettledChanges(db)) c.state],
        ['pending', 'pending'],
      );

      await sync('Archive');
      await sync('INBOX');
      // The App Log names the folder the mail left, not the one the queued
      // move shows it in.
      final merged = logsOf('email.duplicate_merged').single;
      expect(merged.message, contains('moved from INBOX to Archive'));
      expect(merged.message, contains('2 queued change(s)'));
      final data = jsonDecode(merged.dataJson!) as Map<String, dynamic>;
      expect((data['from'], data['to']), ('INBOX', 'Archive'));

      await flush();

      final onServer = server.find(_noMid)!;
      expect((onServer.folder.path, onServer.message.seen), ('Jobs', true));
      expect(await unsettledChanges(db), isEmpty);
      final e = await rowOfNoMid();
      expect((e.id, e.mailboxPath, e.isSeen), (id, 'Jobs', true));
      expect(await rigProblems(), isEmpty);
    });

    test('without a Message-ID nor EMAILID: both fail visibly, none is done',
        () async {
      await open();
      final id = (await rowOfNoMid()).id;
      await emails.setFlag(id, seen: true);
      await emails.moveEmail(id, 'Jobs');
      server.moveElsewhere(_noMid, 'Archive');

      await flush();
      await sync('INBOX');
      await sync('Archive');
      await flush();

      final changes = await unsettledChanges(db);
      expect(
        [for (final c in changes) (c.changeType, c.state)],
        [('flag_seen', 'failed'), ('move', 'failed')],
      );
      expect(logsOf('pending_change.message_gone'), hasLength(2));
      final onServer = server.find(_noMid)!;
      expect((onServer.folder.path, onServer.message.seen), ('Archive', false));
      // Listed with the mail's subject, also once its row is removed.
      await flush();
      expect(
        (await db.select(db.emails).get()).where((e) => e.id == id),
        isEmpty,
      );
      final listed = await emails.observePendingChanges(_account.id).first;
      expect(
        [for (final c in listed) c.subject],
        ['Mail $_noMid', 'Mail $_noMid'],
      );
    });

    for (final uidPlus in [true, false]) {
      test(
          'a move alone of a mail without a Message-ID fails visibly '
          '(UIDPLUS: $uidPlus)', () async {
        await open(uidPlus: uidPlus);
        final id = (await rowOfNoMid()).id;
        await emails.moveEmail(id, 'Jobs');
        server.moveElsewhere(_noMid, 'Archive');

        await flush();

        final change = (await unsettledChanges(db)).single;
        expect(change.state, 'failed');
        expect(server.find(_noMid)!.folder.path, 'Archive');
        expect(logsOf('pending_change.message_gone'), hasLength(1));
      });
    }

    test('with a Message-ID: a read change and a move follow the mail',
        () async {
      await open();
      final id = (await rowOfA()).id;
      await emails.setFlag(id, seen: true);
      await emails.moveEmail(id, 'Jobs');
      server.moveElsewhere('a@test', 'Archive');

      await flush();
      await sync('INBOX');
      // The move was never sent: it does not explain the absence, the row
      // waits for the mail's new place.
      expect((await rowOfA()).foreignMoveWaitSeq, isNotNull);
      await sync('Archive');
      await flush();

      final onServer = server.find('a@test')!;
      expect((onServer.folder.path, onServer.message.seen), ('Jobs', true));
      expect(await unsettledChanges(db), isEmpty);
      final e = await rowOfA();
      expect((e.id, e.mailboxPath), (id, 'Jobs'));
    });

    test(
        'with a Message-ID: a failed move shows its subject, and Retry moves '
        'the mail from where it is now', () async {
      await open();
      final id = (await rowOfA()).id;
      await emails.moveEmail(id, 'Jobs');
      server.moveElsewhere('a@test', 'Archive');

      await flush();
      final failed = (await unsettledChanges(db)).single;
      expect(failed.state, 'failed');
      expect(failed.lastError, contains('in neither mailbox'));
      await sync('INBOX');
      await sync('Archive');

      final listed =
          (await emails.observePendingChanges(_account.id).first).single;
      expect(listed.subject, 'Mail a@test');

      await emails.retryMutation(failed.id);
      final retried = (await unsettledChanges(db)).single;
      final payload = payloadOf(retried);
      expect(
        (payload['mailboxPath'], payload['uid'], payload['uidValidity']),
        ('Archive', 2, 22),
      );
      expect(logsOf('pending_change.retry_retargeted'), hasLength(1));

      await flush();

      expect(server.find('a@test')!.folder.path, 'Jobs');
      expect(await unsettledChanges(db), isEmpty);
      final shown = [
        for (final e in await rowsOfA())
          if (e.mailboxPath.isNotEmpty) e.mailboxPath,
      ];
      expect(shown, ['Jobs']);
      expect(await rigProblems(), isEmpty);
    });
  });
}
