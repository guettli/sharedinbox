import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/utils/reply_recipients.dart';

void main() {
  group('replyRecipients', () {
    const own = 'alice@example.com';

    test('note-to-self falls back to the sender instead of an empty list', () {
      final r = replyRecipients(
        ownEmail: own,
        from: const [EmailAddress(email: 'alice@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
      );
      expect(r, hasLength(1));
      expect(r.single.address.email, 'alice@example.com');
      expect(r.single.isCc, isFalse);
    });

    test('the self fallback is case-insensitive', () {
      final r = replyRecipients(
        ownEmail: 'Alice@Example.COM',
        from: const [EmailAddress(email: 'alice@example.com')],
        to: const [EmailAddress(email: 'ALICE@example.com')],
        cc: const [],
      );
      expect(r, hasLength(1));
      expect(r.single.address.email, 'alice@example.com');
    });

    test('the self fallback does not fire when a real recipient remains', () {
      // From is the account's own address, but To has someone else — the
      // sender must stay excluded and the fallback must not re-add it.
      final r = replyRecipients(
        ownEmail: own,
        from: const [EmailAddress(email: 'alice@example.com')],
        to: const [EmailAddress(email: 'bob@example.com')],
        cc: const [],
      );
      expect(r.map((e) => e.address.email), ['bob@example.com']);
    });

    test('a normal reply targets the sender, excluding own address', () {
      final r = replyRecipients(
        ownEmail: own,
        from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [],
      );
      expect(r.map((e) => e.address.email), ['bob@example.com']);
      expect(r.single.isCc, isFalse);
    });

    test('original Cc recipients stay in Cc', () {
      final r = replyRecipients(
        ownEmail: own,
        from: const [EmailAddress(email: 'bob@example.com')],
        to: const [EmailAddress(email: 'alice@example.com')],
        cc: const [EmailAddress(email: 'carol@example.com')],
      );
      expect(r, hasLength(2));
      final bob = r.firstWhere((e) => e.address.email == 'bob@example.com');
      final carol = r.firstWhere((e) => e.address.email == 'carol@example.com');
      expect(bob.isCc, isFalse);
      expect(carol.isCc, isTrue);
    });

    test('duplicate addresses are de-duplicated', () {
      final r = replyRecipients(
        ownEmail: own,
        from: const [EmailAddress(email: 'bob@example.com')],
        to: const [EmailAddress(email: 'BOB@example.com')],
        cc: const [],
      );
      expect(r, hasLength(1));
      expect(r.single.address.email, 'bob@example.com');
    });

    test('empty headers yield no recipients (nothing to fall back to)', () {
      final r = replyRecipients(
        ownEmail: own,
        from: const [],
        to: const [],
        cc: const [],
      );
      expect(r, isEmpty);
    });
  });
}
