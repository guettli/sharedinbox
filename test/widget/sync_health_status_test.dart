// #1386: the account tile kept "Sync check failed: …" for up to an hour after
// syncs worked again, because only the next hourly check cleared the stored
// failure. A successful sync now re-runs a failed check.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sync/reliability_runner.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/widgets/sync_health_status.dart';

import '../unit/db_test_helper.dart';
import '../unit/helpers/fake_account_repository.dart';
import '../unit/helpers/fake_email_repository.dart';
import '../unit/helpers/fake_mailbox_repository.dart';

const _accountId = 'acc';

class _Emails extends FakeEmailRepositoryBase {
  Object? error;

  @override
  Future<ReliabilityResult> verifySyncReliability(String a, String m) async {
    final e = error;
    if (e != null) throw e;
    return ReliabilityResult.healthy;
  }
}

void main() {
  configureSqliteForTests();

  testWidgets('a successful sync clears "Sync check failed" from the tile', (
    tester,
  ) async {
    // No runAsync anywhere: the in-memory database completes on microtasks,
    // and mixing zones deadlocks Drift's lock between the widget's stream
    // query and the runner's writes.
    final db = await openTestDatabaseWithAccounts(const [_accountId]);
    final emails = _Emails()..error = Exception('server unreachable');
    final syncs = StreamController<String>.broadcast();
    final runner = ReliabilityRunner(
      db,
      FakeAccountRepository(
        const [
          Account(
            id: _accountId,
            displayName: 'A',
            email: 'a@example.com',
            imapHost: 'localhost',
          ),
        ],
      ),
      FakeMailboxRepositoryBase(const [
        Mailbox(
          id: '$_accountId:INBOX',
          accountId: _accountId,
          path: 'INBOX',
          name: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
        ),
      ]),
      emails,
      AppLogger(AppLogRepositoryImpl(db)),
    )..start(syncSucceeded: syncs.stream);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dbProvider.overrideWithValue(db),
          syncHealthVerifyingProvider
              .overrideWith((ref) => Stream.value(const <String>{})),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SyncHealthStatus(accountId: _accountId)),
        ),
      ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
    }

    await runner.checkAccountNow(_accountId);
    await settle();
    expect(find.textContaining('Sync check failed at '), findsOneWidget);

    // The server is reachable again and a sync succeeds.
    emails.error = null;
    syncs.add(_accountId);
    await settle();

    expect(find.textContaining('Sync check failed'), findsNothing);
    expect(find.textContaining('Healthy', findRichText: true), findsOneWidget);

    runner.stop();
    await syncs.close();
    // Unmount first so Drift's stream-query cleanup timer runs inside the
    // test instead of being reported as pending.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
    await db.close();
  });
}
