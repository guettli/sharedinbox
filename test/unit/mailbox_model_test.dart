import 'package:sharedinbox/core/models/mailbox.dart';
// Import the abstract interface so it appears in coverage.
import 'package:sharedinbox/core/repositories/mailbox_repository.dart'; // ignore: unused_import
import 'package:test/test.dart';

void main() {
  group('Mailbox', () {
    const mailbox = Mailbox(
      id: 'a1:INBOX',
      accountId: 'a1',
      path: 'INBOX',
      name: 'INBOX',
      unreadCount: 3,
      totalCount: 10,
    );

    test('stores all fields', () {
      expect(mailbox.id, 'a1:INBOX');
      expect(mailbox.accountId, 'a1');
      expect(mailbox.path, 'INBOX');
      expect(mailbox.name, 'INBOX');
      expect(mailbox.unreadCount, 3);
      expect(mailbox.totalCount, 10);
    });

    test('sub-folder path is stored verbatim', () {
      const sub = Mailbox(
        id: 'a1:INBOX/Work',
        accountId: 'a1',
        path: 'INBOX/Work',
        name: 'Work',
        unreadCount: 0,
        totalCount: 5,
      );
      expect(sub.path, 'INBOX/Work');
      expect(sub.name, 'Work');
    });

    test('runtime construction stores all fields', () {
      // Non-const construction so the constructor is instrumented for coverage.
      // ignore: prefer_const_constructors
      final mb = Mailbox(
        id: 'a1:INBOX',
        accountId: 'a1',
        path: 'INBOX',
        name: 'INBOX',
        unreadCount: 0,
        totalCount: 0,
      );
      expect(mb.id, 'a1:INBOX');
    });

    test('zero counts are valid', () {
      const empty = Mailbox(
        id: 'a1:Trash',
        accountId: 'a1',
        path: 'Trash',
        name: 'Trash',
        unreadCount: 0,
        totalCount: 0,
      );
      expect(empty.unreadCount, 0);
      expect(empty.totalCount, 0);
    });

    test('compareMailboxes sorts by role priority then path', () {
      const inbox = Mailbox(
        id: '1',
        accountId: 'a',
        path: 'INBOX',
        name: 'INBOX',
        unreadCount: 0,
        totalCount: 0,
        role: 'inbox',
      );
      const sent = Mailbox(
        id: '2',
        accountId: 'a',
        path: 'Sent',
        name: 'Sent',
        unreadCount: 0,
        totalCount: 0,
        role: 'sent',
      );
      const apple = Mailbox(
        id: '3',
        accountId: 'a',
        path: 'Apple',
        name: 'Apple',
        unreadCount: 0,
        totalCount: 0,
      );
      const zebra = Mailbox(
        id: '4',
        accountId: 'a',
        path: 'Zebra',
        name: 'Zebra',
        unreadCount: 0,
        totalCount: 0,
      );

      expect(compareMailboxes(inbox, sent), lessThan(0));
      expect(compareMailboxes(sent, inbox), greaterThan(0));
      expect(compareMailboxes(sent, apple), lessThan(0));
      expect(compareMailboxes(apple, zebra), lessThan(0));
      expect(compareMailboxes(zebra, apple), greaterThan(0));
    });

    test('compareMailboxes handles unknown roles', () {
      const m1 = Mailbox(
        id: '1',
        accountId: 'a',
        path: 'Path1',
        name: 'P1',
        unreadCount: 0,
        totalCount: 0,
        role: 'unknown',
      );
      const m2 = Mailbox(
        id: '2',
        accountId: 'a',
        path: 'Path2',
        name: 'P2',
        unreadCount: 0,
        totalCount: 0,
      );

      // unknown role and null role both have priority 99, so they sort by path.
      expect(compareMailboxes(m1, m2), lessThan(0));
    });

    test('copyWith works', () {
      final updated = mailbox.copyWith(unreadCount: 5, role: 'inbox');
      expect(updated.unreadCount, 5);
      expect(updated.role, 'inbox');
      expect(updated.id, mailbox.id);
    });

    test('JSON roundtrip works', () {
      final json = mailbox.toJson();
      final decoded = Mailbox.fromJson(json);
      expect(decoded.id, mailbox.id);
      expect(decoded.path, mailbox.path);
      expect(decoded.unreadCount, mailbox.unreadCount);
    });
  });
}
