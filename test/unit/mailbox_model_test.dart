import 'package:test/test.dart';

import 'package:sharedinbox/core/models/mailbox.dart';
// Import the abstract interface so it appears in coverage.
import 'package:sharedinbox/core/repositories/mailbox_repository.dart'; // ignore: unused_import

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
  });
}
