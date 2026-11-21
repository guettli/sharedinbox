import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_state_writer.dart';

import '../db_test_helper.dart';
import '../recording_app_log_repository.dart';
import 'stateful_imap_rig.dart';

/// The rig of the tests about queued changes whose folder another IMAP
/// client renamed or moved (#1329, #1339): [openRigWithMailA] with INBOX
/// (UIDVALIDITY 11) and Archive (22), its App Log, and the sync-loop kicks
/// the repository sent.
class FolderFollowRig {
  /// The rig of a test suite: registers its sqlite setup.
  FolderFollowRig.forSuite() {
    setUpAll(configureSqliteForTests);
  }

  late RecordingAppLogRepository logs;
  late List<String> kicks;
  late StreamSubscription<String> _kickSub;

  /// Registers the group's setup and teardown, with or without OBJECTID.
  void use({required bool objectIds}) {
    setUp(() async {
      logs = await openRigWithMailA(
        uidValidityByFolder: {'INBOX': 11, 'Archive': 22},
        folders: [('INBOX', 'inbox'), ('Archive', 'archive')],
        objectIds: objectIds,
      );
      kicks = [];
      _kickSub = emails.onChangesQueued.listen(kicks.add);
    });
    tearDown(() async {
      await _kickSub.cancel();
      await db.close();
    });
  }

  /// The App Log's events so far.
  Iterable<String> events() => logs.rows.map((r) => r.event);
}

/// The flush a sync cycle starts with.
Future<void> rigFlush() =>
    emails.flushPendingChanges(statefulRigAccount.id, 'pw');

/// One sync cycle: the flush first, then the folder listing.
Future<void> rigCycle() async {
  await rigFlush();
  await rigListFolders();
}

/// Expects the overlay and folder invariants to hold.
Future<void> expectRigConsistent() async {
  expect(await EmailStateWriter(db).consistencyProblems(), isEmpty);
  expect(await MailboxStateWriter(db).consistencyProblems(), isEmpty);
}

/// Flushes while no folder listing runs: once, 23 hours later (expects
/// [stateOf] still `pending`), and 2 more hours later, past the 24-hour
/// cap of a change waiting for a listing.
Future<void> flushPastListingWaitCap(Future<String> Function() stateOf) async {
  await rigFlush();
  now = now.add(const Duration(hours: 23));
  await rigFlush();
  expect(await stateOf(), 'pending');
  now = now.add(const Duration(hours: 2));
  await rigFlush();
}
