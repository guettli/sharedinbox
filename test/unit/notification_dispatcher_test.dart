import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/services/notification_dispatcher.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/notification_rule_repository_impl.dart';

import 'db_test_helper.dart';

class _MapSecureStorage implements SecureStorage {
  final _map = <String, String>{};
  @override
  Future<void> write({required String key, required String? value}) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }

  @override
  Future<String?> read({required String key}) async => _map[key];
  @override
  Future<void> delete({required String key}) async => _map.remove(key);
}

FilterGroup _subjectContains(String text) => FilterGroup(
      operator: FilterOperator.and_,
      children: [
        FilterLeaf(
          field: FilterField.subject,
          comparison: FilterComparison.contains,
          value: text,
        ),
      ],
    );

Future<void> _seedAccount(
  AccountRepositoryImpl repo, {
  required bool enabled,
}) async {
  await repo.addAccount(
    Account(
      id: 'acc',
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: 'imap.x',
      smtpHost: 'smtp.x',
      notificationsEnabled: enabled,
    ),
    'pw',
  );
}

Future<void> _seedInboxAndMail(AppDatabase db) async {
  await db.into(db.mailboxes).insert(
        MailboxesCompanion.insert(
          id: 'acc:INBOX',
          accountId: 'acc',
          path: 'INBOX',
          name: 'INBOX',
          role: const Value('inbox'),
        ),
      );
  final t0 = DateTime.utc(2026, 1, 1, 9);
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: 'acc:INBOX:1',
          accountId: 'acc',
          mailboxPath: 'INBOX',
          uid: 1,
          subject: const Value('Deploy is broken'),
          receivedAt: t0,
          fromJson: Value(
            jsonEncode([
              {'name': 'CI Bot', 'email': 'ci@example.com'},
            ]),
          ),
        ),
      );
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: 'acc:INBOX:2',
          accountId: 'acc',
          mailboxPath: 'INBOX',
          uid: 2,
          subject: const Value('Lunch?'),
          receivedAt: t0.add(const Duration(minutes: 1)),
          fromJson: Value(
            jsonEncode([
              {'name': 'Bob', 'email': 'bob@example.com'},
            ]),
          ),
        ),
      );
}

void main() {
  configureSqliteForTests();

  group('NotificationDispatcher', () {
    late AppDatabase db;
    late AccountRepositoryImpl accounts;
    late NotificationRuleRepositoryImpl rules;
    late List<Map<String, String>> fired;
    late NotificationDispatcher dispatcher;

    Future<void> setup({required bool enabled}) async {
      db = openTestDatabase();
      addTearDown(db.close);
      accounts = AccountRepositoryImpl(db, _MapSecureStorage());
      rules = NotificationRuleRepositoryImpl(db);
      fired = [];
      dispatcher = NotificationDispatcher(
        rules: rules,
        accounts: accounts,
        show: ({
          required String accountId,
          required String emailId,
          required String title,
          required String body,
        }) async {
          fired.add({
            'accountId': accountId,
            'emailId': emailId,
            'title': title,
            'body': body,
          });
        },
      );
      await _seedAccount(accounts, enabled: enabled);
      await _seedInboxAndMail(db);
    }

    test('silent when the master switch is off', () async {
      await setup(enabled: false);
      await rules.addRule('acc', _subjectContains('deploy'));

      await dispatcher.dispatchForAccount('acc');

      expect(fired, isEmpty);
    });

    test('silent when enabled but no rules exist', () async {
      await setup(enabled: true);
      await dispatcher.dispatchForAccount('acc');
      expect(fired, isEmpty);
    });

    test('fires one notification per matching message only', () async {
      await setup(enabled: true);
      await rules.addRule('acc', _subjectContains('deploy'));

      await dispatcher.dispatchForAccount('acc');

      expect(fired, hasLength(1));
      expect(fired.first['emailId'], 'acc:INBOX:1');
      expect(fired.first['title'], 'CI Bot');
      expect(fired.first['body'], 'Deploy is broken');
    });

    test('never notifies the same message twice', () async {
      await setup(enabled: true);
      await rules.addRule('acc', _subjectContains('deploy'));

      await dispatcher.dispatchForAccount('acc');
      await dispatcher.dispatchForAccount('acc');

      expect(fired, hasLength(1));
    });
  });

  group('matchableFromEmail / notification content', () {
    Email email({String? name, String email = 'x@y.com', String? subject}) =>
        Email(
          id: 'id',
          accountId: 'acc',
          mailboxPath: 'INBOX',
          uid: 1,
          subject: subject,
          receivedAt: DateTime.utc(2026),
          from: [EmailAddress(name: name, email: email)],
          to: const [],
          cc: const [],
          isSeen: false,
          isFlagged: false,
          hasAttachment: false,
        );

    test('title prefers the sender name, falls back to the address', () {
      expect(notificationTitle(email(name: 'Alice')), 'Alice');
      expect(notificationTitle(email(name: '  ', email: 'a@b.com')), 'a@b.com');
    });

    test('body is the subject, or a placeholder when empty', () {
      expect(notificationBody(email(subject: 'Hi')), 'Hi');
      expect(notificationBody(email()), '(no subject)');
      expect(notificationBody(email(subject: '   ')), '(no subject)');
    });

    test('matchableFromEmail carries envelope fields and list-unsubscribe', () {
      final e = Email(
        id: 'id',
        accountId: 'acc',
        mailboxPath: 'INBOX',
        uid: 1,
        subject: 'Sub',
        receivedAt: DateTime.utc(2026),
        from: [const EmailAddress(name: 'A', email: 'a@b.com')],
        to: const [],
        cc: const [],
        isSeen: false,
        isFlagged: false,
        hasAttachment: false,
        listUnsubscribeHeader: '<mailto:x@y>',
      );
      final m = matchableFromEmail(e);
      expect(m.subject, 'Sub');
      expect(m.folder, 'INBOX');
      expect(m.from.single.email, 'a@b.com');
      expect(m.headers['list-unsubscribe'], '<mailto:x@y>');
    });
  });
}
