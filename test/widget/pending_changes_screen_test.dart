import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/pending_changes_screen.dart';

import 'helpers.dart';

/// FakeEmailRepository extension that seeds a fixed list of pending changes
/// and records which rows are retried/discarded so tests can assert on it.
class _StubbedQueue extends FakeEmailRepository {
  _StubbedQueue([List<PendingChange> initial = const [], List<Email>? emails])
      : _changes = List.of(initial),
        super(emails: emails);

  final List<PendingChange> _changes;
  final List<int> retriedIds = [];
  final List<int> discardedIds = [];

  @override
  Stream<List<PendingChange>> observePendingChanges(String a) =>
      Stream.value(_changes.where((c) => c.accountId == a).toList());

  @override
  Stream<List<PendingChange>> observeAllPendingChanges() =>
      Stream.value(List.of(_changes));

  @override
  Future<void> retryMutation(int id) async => retriedIds.add(id);

  @override
  Future<void> discardMutation(int id) async => discardedIds.add(id);
}

PendingChange _pc({
  int id = 1,
  String account = 'acc-1',
  String kind = 'flag_seen',
  String resourceId = 'acc-1:42',
  String payload = '{}',
  int attempts = 0,
  String? lastError,
}) =>
    PendingChange(
      id: id,
      accountId: account,
      kind: kind,
      resourceType: 'Email',
      resourceId: resourceId,
      payload: payload,
      createdAt: DateTime.utc(2026, 3, 4, 9),
      attempts: attempts,
      lastError: lastError,
    );

Email _email({
  String id = 'acc-1:42',
  String account = 'acc-1',
  String? subject = 'Quarterly report',
  String senderName = 'Carol',
  String senderEmail = 'carol@example.com',
}) =>
    Email(
      id: id,
      accountId: account,
      mailboxPath: 'INBOX',
      uid: 42,
      subject: subject,
      receivedAt: DateTime.utc(2026, 3, 4, 8),
      from: [EmailAddress(name: senderName, email: senderEmail)],
      to: const [],
      cc: const [],
      isSeen: false,
      isFlagged: false,
      hasAttachment: false,
    );

void main() {
  const alice = Account(
    id: 'acc-1',
    displayName: 'Alice',
    email: 'alice@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );
  const bob = Account(
    id: 'acc-2',
    displayName: 'Bob',
    email: 'bob@example.com',
    type: AccountType.jmap,
    jmapUrl: 'https://jmap.example.com/',
  );

  /// Pumps the screen with [repo] as the email repository, [accounts] as the
  /// backing account list, and a stub sync-loop that returns [syncRunning].
  /// When it's `true`, [kicks] receives the accountId of every retry.
  Future<void> pump(
    WidgetTester tester, {
    required _StubbedQueue repo,
    List<Account> accounts = const [alice],
    bool syncRunning = true,
    List<String>? kicks,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncNowProvider.overrideWithValue((id) {
            kicks?.add(id);
            return syncRunning;
          }),
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository(accounts)),
          emailRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: PendingChangesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows an empty state when the queue is empty', (tester) async {
    await pump(tester, repo: _StubbedQueue());
    expect(find.text('No pending changes.'), findsOneWidget);
  });

  testWidgets('groups rows by account and renders kind, detail, error',
      (tester) async {
    final repo = _StubbedQueue([
      _pc(
        kind: 'move',
        payload: '{"src":"INBOX","dest":"Archive"}',
        attempts: 3,
        lastError: 'MOVE failed: mailbox is read-only',
      ),
      _pc(id: 2, account: 'acc-2', kind: 'delete', resourceId: 'acc-2:99'),
    ], [
      _email(),
      _email(id: 'acc-2:99', account: 'acc-2', subject: 'Old newsletter'),
    ]);
    await pump(tester, repo: repo, accounts: const [alice, bob]);

    expect(find.text('Alice • IMAP'), findsOneWidget);
    expect(find.text('Bob • JMAP'), findsOneWidget);
    expect(find.text('Move: INBOX → Archive'), findsOneWidget);
    expect(find.text('Quarterly report · Carol'), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(
      find.textContaining('MOVE failed: mailbox is read-only'),
      findsOneWidget,
    );
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Old newsletter · Carol'), findsOneWidget);
  });

  testWidgets('renders the concrete mutation for each change kind',
      (tester) async {
    final repo = _StubbedQueue([
      _pc(payload: '{"seen":true}'),
      _pc(id: 2, payload: '{"seen":false}'),
      _pc(id: 3, kind: 'flag_flagged', payload: '{"flagged":true}'),
      _pc(id: 4, kind: 'flag_flagged', payload: '{"flagged":false}'),
      _pc(
        id: 5,
        kind: 'delete',
        payload: '{"uid":42,"mailboxPath":"INBOX"}',
      ),
    ]);
    await pump(tester, repo: repo);

    expect(find.text('Mark as read'), findsOneWidget);
    expect(find.text('Mark as unread'), findsOneWidget);
    expect(find.text('Add flag'), findsOneWidget);
    expect(find.text('Remove flag'), findsOneWidget);
    expect(find.text('Delete from INBOX'), findsOneWidget);
  });

  testWidgets('falls back to the raw id when the email is not stored locally',
      (tester) async {
    final repo = _StubbedQueue([_pc()]);
    await pump(tester, repo: repo);

    expect(find.text('email acc-1:42'), findsOneWidget);
    expect(find.text('Mark read/unread'), findsOneWidget);
  });

  testWidgets('retry resets the row, kicks sync, and shows a SnackBar',
      (tester) async {
    final repo = _StubbedQueue([_pc(id: 42)]);
    final kicks = <String>[];
    await pump(tester, repo: repo, kicks: kicks);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    await tester.pump();

    expect(repo.retriedIds, [42]);
    expect(
      kicks,
      ['acc-1'],
      reason: 'Retry must kick the sync loop, not just reset the DB row',
    );
    expect(find.text('Retrying change…'), findsOneWidget);
  });

  testWidgets('discard removes the row from the queue', (tester) async {
    final repo = _StubbedQueue([_pc(id: 7, kind: 'delete')]);
    await pump(tester, repo: repo);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(repo.discardedIds, [7]);
  });

  testWidgets(
    'retry surfaces an actionable message when the sync loop is not running',
    (tester) async {
      final repo = _StubbedQueue([_pc(id: 7)]);
      await pump(tester, repo: repo, syncRunning: false);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Sync is not running for this account'),
        findsOneWidget,
      );
    },
  );

  testWidgets('tapping the affected email opens that message', (tester) async {
    final repo = _StubbedQueue([_pc()], [_email()]);
    String? openedRoute;
    final router = GoRouter(
      initialLocation: '/pending-changes',
      routes: [
        GoRoute(
          path: '/pending-changes',
          builder: (ctx, state) => const PendingChangesScreen(),
        ),
        GoRoute(
          path: '/accounts/:accountId/mailboxes/:mailboxPath/emails/:emailId',
          builder: (ctx, state) {
            openedRoute = state.uri.toString();
            return const Scaffold(body: Text('email-detail-route'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncNowProvider.overrideWithValue((_) => true),
          accountRepositoryProvider
              .overrideWithValue(FakeAccountRepository(const [alice])),
          emailRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Quarterly report · Carol'));
    await tester.pumpAndSettle();

    expect(find.text('email-detail-route'), findsOneWidget);
    expect(openedRoute, '/accounts/acc-1/mailboxes/INBOX/emails/acc-1%3A42');
  });

  testWidgets('tapping the error shows the whole message in a dialog',
      (tester) async {
    const longError = 'MOVE failed: the server rejected the request because '
        'the destination mailbox is read-only and cannot accept appended '
        'messages under the current ACL. Contact your administrator.';
    final repo = _StubbedQueue([_pc(lastError: longError)]);
    await pump(tester, repo: repo);

    expect(find.text('Tap to view full error'), findsOneWidget);

    await tester.tap(find.text('Tap to view full error'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AlertDialog, 'Last error'), findsOneWidget);
    expect(find.text(longError), findsOneWidget);
  });
}
