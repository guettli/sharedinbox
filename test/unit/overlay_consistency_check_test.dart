// The sampled consistency checks of the `keywords` overlay (SYNC-REDESIGN.md
// §8 phase 3b): after a sync run, at most once per interval per account, a
// bounded sample of rows is checked; each broken row is logged to the App
// Log and then repaired by re-folding it.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';

import 'db_test_helper.dart';
import 'helpers/stateful_fake_imap.dart';
import 'helpers/stateful_imap_rig.dart';
import 'recording_app_log_repository.dart';

const _acc = 'acc-1';
const _other = 'acc-2';

void main() {
  setUpAll(configureSqliteForTests);

  late AppDatabase db;
  late RecordingAppLogRepository log;
  late EmailStateWriter writer;

  setUp(() async {
    db = await openTestDatabaseWithAccounts([_acc, _other]);
    log = RecordingAppLogRepository();
    writer = EmailStateWriter(db, appLogger: AppLogger(log));
  });
  tearDown(() => db.close());

  /// [count] consistent, unread rows `<account>-<n>`.
  Future<void> rows(int count, {String account = _acc}) async {
    for (var i = 0; i < count; i++) {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: '$account-$i',
              accountId: account,
              mailboxPath: 'INBOX',
              uid: i + 1,
              receivedAt: DateTime.utc(2026),
            ),
          );
    }
  }

  /// Breaks row [id] behind the writer's back.
  Future<void> corrupt(String id, String set) =>
      db.customStatement('UPDATE emails SET $set WHERE id = ?', [id]);

  Future<void> queue(String id, Map<String, Object?> payload) =>
      db.into(db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: _acc,
              resourceType: 'email',
              resourceId: id,
              changeType: 'flag_seen',
              payload: jsonEncode(payload),
              createdAt: DateTime.utc(2026),
            ),
          );

  List<AppLogEntry> inconsistent() => [
        for (final r in log.rows)
          if (r.event == 'overlay.inconsistent') r,
      ];

  group('consistencyProblems', () {
    test('names the fields out of line', () async {
      await rows(3);
      await corrupt('$_acc-0', 'is_seen = 1');
      await corrupt('$_acc-1', 'local_is_flagged = 1, is_flagged = 1');
      await queue('$_acc-2', {'seen': true});
      // The op folds to local_is_seen = 1, but the row was never folded.

      final problems = {
        for (final p in await writer.consistencyProblems()) p.emailId: p,
      };

      expect(problems.keys, {'$_acc-0', '$_acc-1', '$_acc-2'});
      expect(problems['$_acc-0']!.fields, ['is_seen']);
      expect(problems['$_acc-1']!.fields, ['local_is_flagged']);
      expect(problems['$_acc-1']!.withoutOps, isTrue);
      expect(problems['$_acc-2']!.fields, ['local_is_seen']);
      expect(problems['$_acc-2']!.withoutOps, isFalse);
    });

    test('a snooze compares at second precision, 0 as "not snoozed"', () async {
      await rows(2);
      await corrupt(
        '$_acc-0',
        'srv_snoozed_until = 1800000000, snoozed_until = 1800000000',
      );
      // An unsnooze queued and folded: local 0 (cleared), effective NULL.
      await queue('$_acc-1', {'seen': false});
      await db.customStatement(
        "UPDATE pending_changes SET change_type = 'unsnooze', "
        "payload = '{}' WHERE resource_id = ?",
        ['$_acc-1'],
      );
      await writer.refold('$_acc-1');

      expect(await writer.consistencyProblems(), isEmpty);
      await corrupt('$_acc-0', 'snoozed_until = NULL');
      expect(
        (await writer.consistencyProblems()).single.fields,
        ['snoozed_until'],
      );
    });

    test('is limited to the given rows and account', () async {
      await rows(3);
      await rows(1, account: _other);
      for (final id in ['$_acc-0', '$_acc-1', '$_other-0']) {
        await corrupt(id, 'is_seen = 1');
      }

      expect(
        [
          for (final p in await writer.consistencyProblems(
            accountId: _acc,
            emailIds: ['$_acc-1', '$_acc-2', '$_other-0'],
          ))
            p.emailId,
        ],
        ['$_acc-1'],
      );
    });
  });

  group('checkSample', () {
    test('logs each broken row with its fields, then re-folds it', () async {
      await rows(2);
      await corrupt('$_acc-0', 'is_flagged = 1');
      await corrupt('$_acc-1', 'local_is_seen = 1, is_seen = 1');

      final problems = await writer.checkSample(_acc, sampleSize: 10);

      expect(
        problems.map((p) => p.emailId),
        unorderedEquals(['$_acc-0', '$_acc-1']),
      );
      final lines = inconsistent();
      expect(lines, hasLength(2));
      for (final line in lines) {
        expect(line.level, AppLogLevel.error);
        expect(line.accountId, _acc);
        expect(line.message, contains('re-folding the row to repair it'));
      }
      final byId = {for (final l in lines) l.emailId: l};
      final data0 = jsonDecode(byId['$_acc-0']!.dataJson!) as Map;
      expect(data0['fields'], ['is_flagged']);
      expect(data0['effective'], containsPair('flagged', true));
      expect(data0['srv'], containsPair('flagged', false));
      final data1 = jsonDecode(byId['$_acc-1']!.dataJson!) as Map;
      expect(data1['fields'], ['local_is_seen']);
      expect(data1['withoutOps'], isTrue);

      // Repaired: the server's values again, no local intent.
      expect(await writer.consistencyProblems(), isEmpty);
      final repaired = await db.select(db.emails).get();
      expect(repaired.map((e) => (e.isSeen, e.isFlagged, e.localIsSeen)), [
        (false, false, null),
        (false, false, null),
      ]);
    });

    test('logs the first rows one by one, the rest in one line', () async {
      await rows(14);
      for (var i = 0; i < 14; i++) {
        await corrupt('$_acc-$i', 'is_seen = 1');
      }
      final repaired = <String>{};

      final problems = await writer.checkSample(
        _acc,
        sampleSize: 20,
        onRepaired: (ids) async => repaired.addAll(ids),
      );

      expect(problems, hasLength(14));
      final lines = inconsistent();
      expect(lines, hasLength(11));
      expect(lines.take(10).every((l) => l.emailId != null), isTrue);
      final summary = lines.last;
      expect(summary.emailId, isNull);
      expect(summary.message, contains('14 rows'));
      final data = jsonDecode(summary.dataJson!) as Map<String, dynamic>;
      expect(data['total'], 14);
      expect(data['emailIds'], hasLength(4));
      expect(data['fields'], ['is_seen']);
      expect(
        repaired,
        hasLength(14),
        reason: 'every row changed its shown value',
      );
      expect(await writer.consistencyProblems(), isEmpty);
    });

    test('onRepaired gets only rows whose shown value changed', () async {
      await rows(2);
      // Effective right, only a local_ value without an op: the repair
      // clears it, the row shows the same.
      await corrupt('$_acc-0', 'local_is_flagged = 0');
      await corrupt('$_acc-1', 'is_flagged = 1');
      final repaired = <String>{};

      await writer.checkSample(
        _acc,
        sampleSize: 10,
        onRepaired: (ids) async => repaired.addAll(ids),
      );

      expect(repaired, {'$_acc-1'});
    });

    test('a consistent sample logs nothing', () async {
      await rows(5);
      await queue('$_acc-3', {'seen': true});
      await writer.refold('$_acc-3');

      expect(await writer.checkSample(_acc, sampleSize: 10), isEmpty);
      expect(log.rows, isEmpty);
    });

    test('checks a bounded sample: a rowid block plus the rows with ops',
        () async {
      await rows(100);
      await rows(20, account: _other);
      for (var i = 0; i < 100; i++) {
        await corrupt('$_acc-$i', 'is_seen = 1');
      }
      // A row with an op is always in the sample, wherever the block lands.
      await queue('$_acc-50', {'seen': false});

      for (var seed = 0; seed < 20; seed++) {
        final ids = await writer.sampleIds(
          _acc,
          sampleSize: 10,
          random: Random(seed),
        );
        expect(ids.length, inInclusiveRange(10, 11), reason: 'seed $seed');
        expect(ids, contains('$_acc-50'), reason: 'seed $seed');
        expect(
          ids.every((id) => id.startsWith('$_acc-')),
          isTrue,
          reason: 'only the account asked for',
        );
      }

      final checked = await writer.checkSample(
        _acc,
        sampleSize: 10,
        random: Random(1),
      );
      expect(checked.length, inInclusiveRange(10, 11));
      expect(inconsistent(), hasLength(checked.length));
      // The rest is untouched: the next sample finds more.
      expect(
        (await writer.consistencyProblems(accountId: _acc)).length,
        100 - checked.length,
      );
    });

    test('a block that starts near the end wraps around', () async {
      await rows(30);
      for (var i = 0; i < 30; i++) {
        await corrupt('$_acc-$i', 'is_flagged = 1');
      }
      // The largest rowid: the block after it has one row.
      final problems = await writer.checkSample(
        _acc,
        sampleSize: 10,
        random: _Fixed(29),
      );
      expect(problems, hasLength(10));
    });
  });

  group('OverlayConsistencySampler', () {
    test('checks at most once per interval and account', () async {
      await rows(3);
      await rows(3, account: _other);
      var now = DateTime.utc(2026, 11, 17, 12);
      final sampler = OverlayConsistencySampler(
        sampleSize: 10,
        now: () => now,
      );

      await corrupt('$_acc-0', 'is_seen = 1');
      expect(await sampler.afterSyncRun(writer, _acc), hasLength(1));

      await corrupt('$_acc-1', 'is_seen = 1');
      now = now.add(const Duration(minutes: 29));
      expect(
        await sampler.afterSyncRun(writer, _acc),
        isEmpty,
        reason: 'checked 29 minutes ago',
      );
      await corrupt('$_other-0', 'is_seen = 1');
      expect(
        await sampler.afterSyncRun(writer, _other),
        hasLength(1),
        reason: 'another account has its own interval',
      );

      now = now.add(const Duration(minutes: 1));
      expect(
        (await sampler.afterSyncRun(writer, _acc)).single.emailId,
        '$_acc-1',
      );
      expect(inconsistent().map((l) => l.emailId), [
        '$_acc-0',
        '$_other-0',
        '$_acc-1',
      ]);
    });

    test('the last check is kept in the database', () async {
      await rows(1);
      var now = DateTime.utc(2026, 11, 17, 12);
      OverlayConsistencySampler sampler() =>
          OverlayConsistencySampler(sampleSize: 10, now: () => now);

      await sampler().afterSyncRun(writer, _acc);
      await corrupt('$_acc-0', 'is_seen = 1');
      now = now.add(const Duration(minutes: 10));
      expect(
        await sampler().afterSyncRun(writer, _acc),
        isEmpty,
        reason: 'a new sampler (restart, other isolate) keeps the interval',
      );
      now = now.add(const Duration(minutes: 20));
      expect(await sampler().afterSyncRun(writer, _acc), hasLength(1));
    });

    test('a failing check is logged, never thrown', () async {
      final sampler = OverlayConsistencySampler();
      await db.close();

      expect(await sampler.afterSyncRun(writer, _acc), isEmpty);
      expect(log.rows.single.event, 'overlay.check_failed');
      expect(log.rows.single.level, AppLogLevel.warn);
      db = openTestDatabase(); // for tearDown
    });
  });

  test('a sync run of the repository runs the sampled check', () async {
    final appLog = RecordingAppLogRepository();
    rig = await StatefulImapRig.open(
      StatefulFakeImapServer(uidValidityByFolder: {'INBOX': 11})
        ..deliver('INBOX', 'a@test'),
      folders: [('INBOX', 'inbox')],
      appLogger: AppLogger(appLog),
      consistencySampler: OverlayConsistencySampler(
        interval: Duration.zero,
        sampleSize: 10,
      ),
    );
    addTearDown(rig.db.close);
    final id = (await rig.db.select(rig.db.emails).getSingle()).id;
    await rig.db
        .customStatement('UPDATE emails SET is_flagged = 1 WHERE id = ?', [id]);
    // The thread aggregate was computed from the broken row.
    await rig.db.customStatement('UPDATE threads SET is_flagged = 1');

    await rig.emails.syncEmails(statefulRigAccount.id, 'INBOX');

    final line =
        appLog.rows.singleWhere((r) => r.event == 'overlay.inconsistent');
    expect(line.emailId, id);
    expect(
      (jsonDecode(line.dataJson!) as Map<String, dynamic>)['fields'],
      ['is_flagged'],
    );
    expect(
      (await rig.db.select(rig.db.emails).getSingle()).isFlagged,
      isFalse,
      reason: 'repaired',
    );
    expect(
      (await rig.db.select(rig.db.threads).getSingle()).isFlagged,
      isFalse,
      reason: 'the thread aggregate follows the repaired row',
    );
  });
}

/// [Random] whose `nextInt` returns [value] (capped below the bound).
class _Fixed implements Random {
  _Fixed(this.value);

  final int value;

  @override
  int nextInt(int max) => min(value, max - 1);

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
