import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/pending_changes_screen.dart';

import 'helpers.dart';

/// A FakeEmailRepository that also serves a fixed list of pending changes and
/// records retry/discard calls so widget tests can assert on them.
class _RecordingPendingRepository extends FakeEmailRepository {
  _RecordingPendingRepository({List<PendingChange>? initial})
      : _changes = List.of(initial ?? const []);

  final List<PendingChange> _changes;
  final List<int> retried = [];
  final List<int> discarded = [];

  @override
  Stream<List<PendingChange>> observePendingChanges(String accountId) =>
      Stream.value(_changes.where((c) => c.accountId == accountId).toList());

  @override
  Stream<List<PendingChange>> observeAllPendingChanges() =>
      Stream.value(List.of(_changes));

  @override
  Future<void> retryMutation(int id) async {
    retried.add(id);
  }

  @override
  Future<void> discardMutation(int id) async {
    discarded.add(id);
  }
}

Widget _wrap({
  required List<Override> overrides,
  List<String>? syncedAccounts,
}) {
  return ProviderScope(
    overrides: [
      // Avoid materialising the real AccountSyncManager (pulls in a Drift DB
      // + a big provider tree) — the tile only needs a plain callback.
      syncNowProvider.overrideWithValue((accountId) {
        syncedAccounts?.add(accountId);
        return true;
      }),
      ...overrides,
    ],
    child: const MaterialApp(home: PendingChangesScreen()),
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

  PendingChange makeChange({
    required int id,
    required String accountId,
    required String kind,
    required String resourceId,
    String payload = '{}',
    int attempts = 0,
    String? lastError,
    DateTime? createdAt,
  }) =>
      PendingChange(
        id: id,
        accountId: accountId,
        kind: kind,
        resourceType: 'Email',
        resourceId: resourceId,
        payload: payload,
        createdAt: createdAt ?? DateTime.utc(2026, 3, 4, 9),
        attempts: attempts,
        lastError: lastError,
      );

  testWidgets('shows an empty state when the queue is empty', (tester) async {
    await tester.pumpWidget(
      _wrap(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([accountA]),
          ),
          emailRepositoryProvider
              .overrideWithValue(_RecordingPendingRepository()),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No pending changes.'), findsOneWidget);
  });

  testWidgets(
    'groups rows by account and renders kind, target, attempts and error',
    (tester) async {
      final repo = _RecordingPendingRepository(
        initial: [
          makeChange(
            id: 1,
            accountId: 'acc-1',
            kind: 'move',
            resourceId: 'acc-1:42',
            payload: '{"dest":"Archive"}',
            attempts: 3,
            lastError: 'MOVE failed: mailbox is read-only',
          ),
          makeChange(
            id: 2,
            accountId: 'acc-2',
            kind: 'delete',
            resourceId: 'acc-2:99',
          ),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA, accountB]),
            ),
            emailRepositoryProvider.overrideWithValue(repo),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Per-account group headers.
      expect(find.text('Alice • IMAP'), findsOneWidget);
      expect(find.text('Bob • JMAP'), findsOneWidget);

      // Row 1 — move with error.
      expect(find.text('Move'), findsOneWidget);
      expect(find.text('Target: email acc-1:42 → Archive'), findsOneWidget);
      expect(find.byIcon(Icons.error), findsOneWidget);
      expect(
        find.textContaining('MOVE failed: mailbox is read-only'),
        findsOneWidget,
      );

      // Row 2 — delete without error.
      expect(find.text('Delete'), findsOneWidget);
      expect(find.text('Target: email acc-2:99'), findsOneWidget);
    },
  );

  testWidgets(
    'retry resets the row, kicks sync, and shows a SnackBar',
    (tester) async {
      final repo = _RecordingPendingRepository(
        initial: [
          makeChange(
            id: 42,
            accountId: 'acc-1',
            kind: 'flag_seen',
            resourceId: 'acc-1:42',
          ),
        ],
      );

      final synced = <String>[];
      await tester.pumpWidget(
        _wrap(
          syncedAccounts: synced,
          overrides: [
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA]),
            ),
            emailRepositoryProvider.overrideWithValue(repo),
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
      expect(find.text('Retrying change…'), findsOneWidget);
    },
  );

  testWidgets('discard removes the row from the queue', (tester) async {
    final repo = _RecordingPendingRepository(
      initial: [
        makeChange(
          id: 7,
          accountId: 'acc-1',
          kind: 'delete',
          resourceId: 'acc-1:42',
        ),
      ],
    );

    await tester.pumpWidget(
      _wrap(
        overrides: [
          accountRepositoryProvider.overrideWithValue(
            FakeAccountRepository([accountA]),
          ),
          emailRepositoryProvider.overrideWithValue(repo),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(repo.discarded, [7]);
  });

  testWidgets(
    'retry surfaces an actionable message when the sync loop is not running',
    (tester) async {
      final repo = _RecordingPendingRepository(
        initial: [
          makeChange(
            id: 7,
            accountId: 'acc-1',
            kind: 'flag_seen',
            resourceId: 'acc-1:42',
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            syncNowProvider.overrideWithValue((_) => false),
            accountRepositoryProvider.overrideWithValue(
              FakeAccountRepository([accountA]),
            ),
            emailRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: PendingChangesScreen()),
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
}
