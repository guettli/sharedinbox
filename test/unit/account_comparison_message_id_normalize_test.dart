import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;

import 'db_test_helper.dart';

/// Regression coverage for #406.
///
/// Legacy IMAP rows written before commit 6db1f31 (#143) held Message-IDs in
/// their raw RFC 5322 form (`<foo@bar>`), while JMAP rows have always stored
/// them bracket-less per RFC 8621 §4.1.2.3. The compare join must normalise
/// so those rows still match — otherwise the same message shows up as two
/// separate diffs, one on each side.
void main() {
  setUpAll(configureSqliteForTests);

  test('bracketed IMAP row matches bracket-less JMAP row (#406)', () async {
    final db = openTestDatabase();
    addTearDown(db.close);

    // Compare talks to mailboxes and emails directly — no accounts row
    // needed. Two mailboxes matched by role="inbox".
    const inbox = Value('inbox');
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'i:INBOX',
            accountId: 'imap-1',
            path: 'INBOX',
            name: 'INBOX',
            role: inbox,
          ),
        );
    await db.into(db.mailboxes).insert(
          MailboxesCompanion.insert(
            id: 'j:a',
            accountId: 'jmap-1',
            path: 'a',
            name: 'a',
            role: inbox,
          ),
        );

    // The IMAP row still has RFC 5322 angle brackets; the JMAP row
    // reflects RFC 8621's array-of-strings shape.
    final sentAt = DateTime.utc(2026, 1, 1, 12);
    for (final row in const [
      ('imap-1', 'INBOX', 'imap-1:1', '<msg-001@example.com>'),
      ('jmap-1', 'a', 'jmap-1:X', 'msg-001@example.com'),
    ]) {
      await db.into(db.emails).insert(
            EmailsCompanion.insert(
              id: row.$3,
              accountId: row.$1,
              mailboxPath: row.$2,
              uid: 0,
              sentAt: Value(sentAt),
              receivedAt: sentAt,
              messageId: Value(row.$4),
            ),
          );
    }

    final result = await AccountComparison(db).compare('imap-1', 'jmap-1');
    expect(result.isIdentical, isTrue);
  });
}
