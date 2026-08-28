import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/repositories/notification_rule_repository_impl.dart';

import 'db_test_helper.dart';

FilterGroup _fromIs(String address) => FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.from_,
          comparison: FilterComparison.is_,
          value: address,
        ),
      ],
    );

Future<void> _seedInbox(AppDatabase db, String accountId) async {
  await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          id: '$accountId:INBOX',
          accountId: accountId,
          path: 'INBOX',
          name: 'INBOX',
          role: const Value('inbox'),
        ),
      );
}

Future<void> _seedEmail(
  AppDatabase db,
  String accountId,
  String mailboxPath,
  String id,
  DateTime receivedAt,
) async {
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: 0,
          receivedAt: receivedAt,
        ),
      );
}

void main() {
  configureSqliteForTests();

  group('NotificationRuleRepositoryImpl', () {
    test('add / list / update / delete rules', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = NotificationRuleRepositoryImpl(db);

      final id = await repo.addRule('acc', _fromIs('a@x.com'), name: 'Alice');
      var rules = await repo.listRules('acc');
      expect(rules, hasLength(1));
      expect(rules.first.name, 'Alice');
      final leaf = rules.first.filter.children.first as FilterLeaf;
      expect(leaf.value, 'a@x.com');

      await repo.updateRule(id, _fromIs('b@x.com'), name: 'Bob');
      rules = await repo.listRules('acc');
      expect(rules.first.name, 'Bob');
      expect(
        (rules.first.filter.children.first as FilterLeaf).value,
        'b@x.com',
      );

      await repo.deleteRule(id);
      expect(await repo.listRules('acc'), isEmpty);
    });

    test('rules are scoped per account', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = NotificationRuleRepositoryImpl(db);

      await repo.addRule('acc-1', _fromIs('a@x.com'));
      await repo.addRule('acc-2', _fromIs('b@x.com'));

      expect(await repo.listRules('acc-1'), hasLength(1));
      expect(await repo.listRules('acc-2'), hasLength(1));
    });

    test('unnotifiedInboxEmails excludes non-inbox and notified mail',
        () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = NotificationRuleRepositoryImpl(db);
      await _seedInbox(db, 'acc');
      // A non-inbox mailbox whose mail must never be a candidate.
      await db.into(db.mailboxes).insert(
            MailboxesCompanion.insert(
              id: 'acc:Archive',
              accountId: 'acc',
              path: 'Archive',
              name: 'Archive',
            ),
          );

      final t0 = DateTime.utc(2026, 1, 1, 9);
      await _seedEmail(db, 'acc', 'INBOX', 'acc:INBOX:1', t0);
      await _seedEmail(
        db,
        'acc',
        'INBOX',
        'acc:INBOX:2',
        t0.add(const Duration(minutes: 1)),
      );
      await _seedEmail(db, 'acc', 'Archive', 'acc:Archive:1', t0);

      var pending = await repo.unnotifiedInboxEmails('acc');
      expect(pending.map((e) => e.id), ['acc:INBOX:1', 'acc:INBOX:2']);

      await repo.markNotified('acc', ['acc:INBOX:1']);
      pending = await repo.unnotifiedInboxEmails('acc');
      expect(pending.map((e) => e.id), ['acc:INBOX:2']);
    });

    test('markBaseline silences the whole current inbox', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = NotificationRuleRepositoryImpl(db);
      await _seedInbox(db, 'acc');

      final t0 = DateTime.utc(2026, 1, 1, 9);
      await _seedEmail(db, 'acc', 'INBOX', 'acc:INBOX:1', t0);
      await _seedEmail(db, 'acc', 'INBOX', 'acc:INBOX:2', t0);

      await repo.markBaseline('acc');
      expect(await repo.unnotifiedInboxEmails('acc'), isEmpty);

      // A message arriving after the baseline is still a candidate.
      await _seedEmail(
        db,
        'acc',
        'INBOX',
        'acc:INBOX:3',
        t0.add(const Duration(minutes: 5)),
      );
      final pending = await repo.unnotifiedInboxEmails('acc');
      expect(pending.map((e) => e.id), ['acc:INBOX:3']);
    });

    test('watchRules emits on change', () async {
      final db = openTestDatabase();
      addTearDown(db.close);
      final repo = NotificationRuleRepositoryImpl(db);

      final first = await repo.watchRules('acc').first;
      expect(first, isEmpty);

      await repo.addRule('acc', _fromIs('a@x.com'));
      final next = await repo.watchRules('acc').first;
      expect(next, hasLength(1));
    });
  });
}
