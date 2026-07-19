import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
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
  List<String>? syncedAccounts,
}) {
  return ProviderScope(
    overrides: [
      // Avoid materialising a real AccountSyncManager (which pulls in a Drift
      // database + a stack of other providers) — the tile only needs a plain
      // callback to record kicks against.
      syncNowProvider.overrideWithValue((accountId) {
        syncedAccounts?.add(accountId);
        return true;
      }),
      ...overrides,
    ],
    child: const MaterialApp(home: SentQueueScreen()),
  );
}

void main() {
  const accountA = Account(
    id: 'acc-1',
    displayName: 'Alice',
    email: 'alice@example.com',
    imapHost: 'imap.example.com',
    smtpHost: 'smtp.example.com',
  );
  const accountB = Account(
    id: 'acc-2',
    displayName: 'Bob',
    email: 'bob@example.com',
    type: AccountType.jmap,
    jmapUrl: 'https://jmap.example.com/',
  );

  testWidgets('shows an empty state when nothing is queued', (tester) async {
    await tester.pumpWidget(
      _wrap(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([accountA]),
          ),
          outboxRepositoryProvider
              .overrideWithValue(_RecordingOutboxRepository()),
        ],
      ),
    );
    await tester.pumpAndSettle();

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

    await tester.pumpWidget(
      _wrap(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([accountA, accountB]),
          ),
          outboxRepositoryProvider.overrideWithValue(repo),
        ],
      ),
    );
    await tester.pumpAndSettle();

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
    'retry resets the queue row, kicks sync, and shows a SnackBar',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.add(
        OutboxMessage(
          id: 42,
          accountId: 'acc-1',
          subject: 'Ping',
          to: const ['carol@example.com'],
          cc: const [],
          createdAt: DateTime.utc(2026, 3, 4, 9),
          attempts: 0,
          status: 'pending',
        ),
      );

      final synced = <String>[];
      await tester.pumpWidget(
        _wrap(
          syncedAccounts: synced,
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA]),
            ),
            outboxRepositoryProvider.overrideWithValue(repo),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump();
      expect(repo.retried, [42]);
      expect(
        synced,
        ['acc-1'],
        reason: 'Retry must kick the sync loop, not just reset the DB row',
      );
      expect(find.text('Retrying send…'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      expect(repo.discarded, [42]);
    },
  );

  testWidgets(
    'retry shows an actionable message when the sync loop is not running',
    (tester) async {
      final repo = _RecordingOutboxRepository();
      repo.messages.add(
        OutboxMessage(
          id: 7,
          accountId: 'acc-1',
          subject: 'Ping',
          to: const ['carol@example.com'],
          cc: const [],
          createdAt: DateTime.utc(2026, 3, 4, 9),
          attempts: 0,
          status: 'pending',
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncNowProvider.overrideWithValue((accountId) => false),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA]),
            ),
            outboxRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: SentQueueScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump();
      expect(
        find.textContaining('Sync is not running for this account'),
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

      await tester.pumpWidget(
        _wrap(
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA]),
            ),
            outboxRepositoryProvider.overrideWithValue(repo),
          ],
        ),
      );
      await tester.pumpAndSettle();

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

    await tester.pumpWidget(
      _wrap(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([accountA]),
          ),
          outboxRepositoryProvider.overrideWithValue(repo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('${'X' * 60}…'),
      findsOneWidget,
      reason: 'preview should be truncated to 60 chars + ellipsis',
    );
    expect(find.text(longSubject), findsNothing);
  });
}
