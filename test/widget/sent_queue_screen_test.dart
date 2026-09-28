import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/sent_queue_screen.dart';

import 'helpers.dart';

class _RecordingOutboxRepository extends FakeOutboxRepository {
  final List<int> retried = [];
  final List<int> discarded = [];

  @override
  Future<void> retry(int id) async {
    retried.add(id);
  }

  @override
  Future<void> discard(int id) async {
    discarded.add(id);
  }
}

Widget _wrap({
  required List<Override> overrides,
  FakeEmailRepository? emails,
}) {
  return ProviderScope(
    overrides: [
      // The Retry button sends via EmailRepository.sendNow; a fake stands in so
      // the tile never touches a real repository (or the network).
      emailRepositoryProvider
          .overrideWithValue(emails ?? FakeEmailRepository()),
      ...overrides,
    ],
    child: const MaterialApp(home: SentQueueScreen()),
  );
}

const _accountA = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);
const _accountB = Account(
  id: 'acc-2',
  displayName: 'Bob',
  email: 'bob@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/',
);

/// A single pending row on [_accountA] used by the retry tests.
OutboxMessage _pendingPing(int id) => OutboxMessage(
      id: id,
      accountId: 'acc-1',
      subject: 'Ping',
      to: const ['carol@example.com'],
      cc: const [],
      createdAt: DateTime.utc(2026, 3, 4, 9),
      attempts: 0,
      status: 'pending',
    );

/// Pumps [SentQueueScreen] backed by [repo] (and optional [emails]/[accounts])
/// and settles — the shared setup every test in this file starts from.
Future<void> _pumpQueue(
  WidgetTester tester, {
  required _RecordingOutboxRepository repo,
  List<Account> accounts = const [_accountA],
  FakeEmailRepository? emails,
}) async {
  await tester.pumpWidget(
    _wrap(
      emails: emails,
      overrides: [
        accountRepositoryProvider.overrideWithValue(
          FakeAccountRepository(accounts),
        ),
        outboxRepositoryProvider.overrideWithValue(repo),
      ],
    ),
  );
  await tester.pumpAndSettle();
}

/// Pumps the queue with [repo]/[emails] and taps the Retry button on the row.
Future<void> _pumpAndTapRetry(
  WidgetTester tester, {
  required _RecordingOutboxRepository repo,
  required FakeEmailRepository emails,
}) async {
  await _pumpQueue(tester, repo: repo, emails: emails);
  await tester.tap(find.byIcon(Icons.refresh));
  await tester.pumpAndSettle();
}

void main() {
  const accountA = _accountA;
  const accountB = _accountB;

  testWidgets('shows an empty state when nothing is queued', (tester) async {
    await _pumpQueue(tester, repo: _RecordingOutboxRepository());

    expect(find.text('No messages waiting to be sent.'), findsOneWidget);
  });

  testWidgets('renders account, type, receiver, date and subject start', (
    tester,
  ) async {
    final repo = _RecordingOutboxRepository();
    repo.messages.addAll([
      OutboxMessage(
        id: 1,
        accountId: 'acc-1',
        subject: 'Weekly status update from the team',
        to: const ['carol@example.com'],
        cc: const [],
        createdAt: DateTime.utc(2026, 3, 4, 9, 15),
        attempts: 0,
        status: 'pending',
      ),
      OutboxMessage(
        id: 2,
        accountId: 'acc-2',
        subject: '',
        to: const ['dave@example.com', 'erin@example.com'],
        cc: const [],
        createdAt: DateTime.utc(2026, 3, 5, 10, 20),
        attempts: 2,
        status: 'failed',
        lastError: 'boom',
      ),
    ]);

    await _pumpQueue(tester, repo: repo, accounts: const [accountA, accountB]);

    // Row 1 — IMAP account, pending.
    expect(
      find.text('Weekly status update from the team'),
      findsOneWidget,
    );
    expect(find.text('Alice • IMAP'), findsOneWidget);
    expect(find.text('To: carol@example.com'), findsOneWidget);

    // Row 2 — JMAP account, failed, no subject.
    expect(find.text('(no subject)'), findsOneWidget);
    expect(find.text('Bob • JMAP'), findsOneWidget);
    expect(
      find.text('To: dave@example.com, erin@example.com'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(
      find.textContaining('Failed (attempts: 2): boom'),
      findsOneWidget,
    );
  });

  testWidgets(
    'retry resets the row, sends it now, and shows the sent SnackBar',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.add(_pendingPing(42));
      final emails = FakeEmailRepository()
        ..sendNowResult = const SendNowResult(SendNowOutcome.sent);

      await _pumpAndTapRetry(tester, repo: repo, emails: emails);
      expect(repo.retried, [42]);
      expect(
        emails.sendNowRowIds,
        [42],
        reason: 'Retry must actually send the row now, not just reset it',
      );
      expect(find.text('Message sent'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      expect(repo.discarded, [42]);
    },
  );

  testWidgets(
    'retry surfaces the concrete failure reason in the SnackBar',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.add(_pendingPing(7));
      final emails = FakeEmailRepository()
        ..sendNowResult = const SendNowResult(
          SendNowOutcome.transientFailed,
          message: 'Connection refused',
        );

      await _pumpAndTapRetry(tester, repo: repo, emails: emails);
      expect(
        find.text('Send failed, will retry: Connection refused'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'retry shows an error SnackBar when the send itself throws (#755)',
    (tester) async {
      // sendNow reads the password itself and can throw before the network
      // (e.g. no stored password). Retry must still report the failure rather
      // than fail silently — the "nothing happens" the issue complains about.
      final repo = _RecordingOutboxRepository();
      repo.messages.add(_pendingPing(11));
      final emails = FakeEmailRepository()
        ..sendNowError = StateError('No password stored for account acc-1');

      await _pumpAndTapRetry(tester, repo: repo, emails: emails);
      expect(repo.retried, [11]);
      expect(find.textContaining('Send failed:'), findsOneWidget);
    },
  );

  testWidgets(
    'a pending row with no error explains why it is still queued',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.addAll([
        // Fresh row, no backoff yet.
        OutboxMessage(
          id: 1,
          accountId: 'acc-1',
          subject: 'Waiting one',
          to: const ['carol@example.com'],
          cc: const [],
          createdAt: DateTime.utc(2026, 3, 4, 9),
          attempts: 0,
          status: 'pending',
        ),
        // Row that failed once and is backing off until a future time.
        OutboxMessage(
          id: 2,
          accountId: 'acc-1',
          subject: 'Waiting two',
          to: const ['dave@example.com'],
          cc: const [],
          createdAt: DateTime.utc(2026, 3, 4, 9),
          attempts: 1,
          status: 'pending',
          nextAttemptAt: DateTime.now().add(const Duration(minutes: 5)),
        ),
      ]);

      await _pumpQueue(tester, repo: repo);

      expect(
        find.text('Queued — will send on the next sync'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Waiting to retry — next attempt'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping the last-error line opens the details dialog',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.add(
        OutboxMessage(
          id: 9,
          accountId: 'acc-1',
          subject: 'Whoops',
          to: const ['carol@example.com'],
          cc: const [],
          createdAt: DateTime.utc(2026, 3, 4, 9),
          attempts: 3,
          status: 'failed',
          lastError:
              'SMTP connect/auth timed out after 50s (host: smtp.example.com:587)',
        ),
      );

      await _pumpQueue(tester, repo: repo);

      await tester.tap(find.textContaining('tap for details'));
      await tester.pumpAndSettle();

      expect(find.text('Send failed'), findsOneWidget);
      expect(find.text('Attempts: 3'), findsOneWidget);
      expect(
        find.textContaining('SMTP connect/auth timed out after 50s'),
        findsWidgets,
        reason: 'full error text should be visible in the details dialog',
      );
    },
  );

  testWidgets('long subjects are truncated to the preview length', (
    tester,
  ) async {
    final repo = _RecordingOutboxRepository();
    final longSubject = 'X' * 200;
    repo.messages.add(
      OutboxMessage(
        id: 1,
        accountId: 'acc-1',
        subject: longSubject,
        to: const ['carol@example.com'],
        cc: const [],
        createdAt: DateTime.utc(2026, 3, 4, 9),
        attempts: 0,
        status: 'pending',
      ),
    );

    await _pumpQueue(tester, repo: repo);

    expect(
      find.text('${'X' * 60}…'),
      findsOneWidget,
      reason: 'preview should be truncated to 60 chars + ellipsis',
    );
    expect(find.text(longSubject), findsNothing);
  });
}
