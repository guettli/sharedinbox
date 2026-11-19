// An IMAP `BAD` answer to a change command (#1316): one about the command
// itself (a flag or folder name the server rejects) fails the change at
// once, with Retry / Discard; one about the connection's state, and a lost
// connection, stay failures that may pass (SYNC.md §6).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = statefulRigAccount;

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingAppLogRepository logs;
  setUp(() async => logs = await openRigInboxArchive());
  tearDown(() => db.close());

  Future<void> flush() => emails.flushPendingChanges(_acc.id, 'pw');
  Future<PendingChangeRow> change() async => (await rigOps()).single;

  /// Every [command] gets [error] until the test clears it.
  void fail(String command, Object error) =>
      server.failBefore = (c) => c == command ? error : null;

  /// The `pending_change.bad_command` warns of the App Log.
  List<AppLogEntry> badWarns() => [
        for (final r in logs.rows)
          if (r.event == 'pending_change.bad_command') r,
      ];

  /// Expects [c] failed at once, with the server's text, listed on the
  /// Pending Changes screen, and one App Log warn quoting [text].
  Future<void> expectFailedOnBad(PendingChangeRow c, String text) async {
    expect(c.state, 'failed');
    expect(c.attempts, 1);
    expect(c.lastError, 'BAD $text');
    final failed = await emails.observeFailedMutations(_acc.id).first;
    expect(failed.map((f) => (f.id, f.failed)), [(c.id, true)]);
    await pumpEventQueue();
    final warn = badWarns().single;
    expect(warn.level, AppLogLevel.warn);
    expect(warn.message, contains('BAD $text'));
    expect(
      (jsonDecode(warn.dataJson!) as Map)['serverText'],
      'BAD $text',
    );
  }

  test('a BAD on STORE fails the change at once; Retry sends it again',
      () async {
    final id = (await rowOfA()).id;
    await emails.setFlag(id, flagged: true);
    fail('STORE', StatefulFakeImapServer.badAnswer('Invalid flag name'));

    await flush();

    await expectFailedOnBad(await change(), 'Invalid flag name');
    // No longer folds: the mail shows the server's state again.
    expect((await rowOfA()).isFlagged, isFalse);

    server.failBefore = null;
    await emails.retryMutation((await change()).id);
    await flush();
    expect(server.find('a@test')!.message.flagged, isTrue);
  });

  test('a BAD on MOVE fails the move at once; the mail shows in INBOX again',
      () async {
    final id = (await rowOfA()).id;
    await emails.moveEmail(id, 'Archive');
    expect((await rowOfA()).mailboxPath, 'Archive');
    fail('MOVE', StatefulFakeImapServer.badAnswer('Invalid mailbox name'));

    await flush();

    await expectFailedOnBad(await change(), 'Invalid mailbox name');
    expect((await rowOfA()).mailboxPath, 'INBOX');
    expect(server.find('a@test')!.folder.path, 'INBOX');

    server.failBefore = null;
    await emails.retryMutation((await change()).id);
    await flush();
    expect(server.find('a@test')!.folder.path, 'Archive');
  });

  test('a BAD on a folder CREATE fails the create at once', () async {
    await rig.mailboxes.createMailbox(_acc.id, 'Projects');
    fail('CREATE', StatefulFakeImapServer.badAnswer('Invalid mailbox name'));

    await flush();

    final c = await change();
    expect(c.changeType, 'create_mailbox');
    expect(c.state, 'failed');
    expect(c.attempts, 1);
    expect(c.lastError, contains('BAD Invalid mailbox name'));
    final failed = await emails.observeFailedMutations(_acc.id).first;
    expect(failed.map((f) => (f.id, f.failed)), [(c.id, true)]);
    await pumpEventQueue();
    final warn = badWarns().single;
    expect(warn.message, contains('BAD Invalid mailbox name'));
    expect(
      logs.rows.map((r) => r.event),
      isNot(contains('pending_change.rejected')),
    );

    server.failBefore = null;
    await emails.retryMutation(c.id);
    await flush();
    expect(server.folders.keys, contains('Projects'));
  });

  for (final text in [
    'Command not allowed in this state',
    'No mailbox selected',
    'Not authenticated',
    '[UNAVAILABLE] Try again later',
  ]) {
    test('a BAD about the connection ("$text") may pass: retried', () async {
      await emails.setFlag((await rowOfA()).id, flagged: true);
      fail('STORE', StatefulFakeImapServer.badAnswer(text));

      await flush();

      final c = await change();
      expect(c.state, 'pending');
      expect(c.attempts, 1);
      expect(c.lastError, 'BAD $text');
      expect((await rowOfA()).isFlagged, isTrue, reason: 'still protected');
      await pumpEventQueue();
      expect(badWarns(), isEmpty);
    });
  }

  test('a lost connection on STORE may pass: retried, not failed', () async {
    await emails.setFlag((await rowOfA()).id, flagged: true);
    fail('STORE', const SocketException('Connection reset by peer'));

    await flush();

    final c = await change();
    expect(c.state, 'pending');
    expect(c.attempts, 1);
    await pumpEventQueue();
    expect(badWarns(), isEmpty);
  });
}
