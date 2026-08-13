import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/di.dart';

import 'helpers.dart';

/// A [FakeEmailRepository] that reports orphaned thread rows from
/// [diagnoseMailbox] and records calls to [sweepOrphanThreads], so the #523
/// "Remove phantom rows" repair flow can be exercised.
class _OrphanDiagnosticsEmailRepository extends FakeEmailRepository {
  int sweepCalls = 0;

  @override
  Future<MailboxDiagnostics> diagnoseMailbox(String a, String m) async =>
      MailboxDiagnostics(
        accountId: a,
        mailboxPath: m,
        protocol: 'IMAP',
        cachedTotal: 1,
        cachedUnread: 0,
        localEmailRows: 1,
        localThreadRows: 18,
        orphanThreadRows: 17,
        serverTotal: 1,
        serverUnread: 0,
        serverMessageCount: 1,
      );

  @override
  Future<int> sweepOrphanThreads(String a, String m) async {
    sweepCalls++;
    return 17;
  }
}

void main() {
  const doneMailbox = Mailbox(
    id: 'acc-1:Done',
    accountId: 'acc-1',
    path: 'Done',
    name: 'Done',
    unreadCount: 0,
    totalCount: 1,
  );

  Future<_OrphanDiagnosticsEmailRepository> pump(WidgetTester tester) async {
    final repo = _OrphanDiagnosticsEmailRepository();
    await tester.pumpWidget(
      buildApp(
        initialLocation: '/accounts/acc-1/mailboxes/Done/diagnostics',
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([kTestAccount]),
          ),
          mailboxRepositoryProvider.overrideWithValue(
            FakeMailboxRepository([doneMailbox]),
          ),
          emailRepositoryProvider.overrideWithValue(repo),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  group('FolderDiagnosticsScreen (#523)', () {
    testWidgets('explains phantom rows and offers a repair button', (
      tester,
    ) async {
      await pump(tester);

      expect(find.textContaining('phantom'), findsWidgets);
      expect(find.text('Remove 17 phantom row(s)'), findsOneWidget);
    });

    testWidgets('tapping the button sweeps orphan threads', (tester) async {
      final repo = await pump(tester);

      await tester.tap(find.text('Remove 17 phantom row(s)'));
      await tester.pumpAndSettle();

      expect(repo.sweepCalls, 1);
      expect(find.text('Removed 17 phantom row(s)'), findsOneWidget);
    });
  });
}
