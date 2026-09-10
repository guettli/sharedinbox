import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/similar_filter.dart';
import 'package:sharedinbox/core/models/email.dart';

Email _seed({
  String? subject,
  List<EmailAddress> from = const [],
}) =>
    Email(
      id: 'acc-1:42',
      accountId: 'acc-1',
      mailboxPath: 'INBOX',
      uid: 42,
      subject: subject,
      receivedAt: DateTime(2026),
      from: from,
      to: const [],
      cc: const [],
      isSeen: false,
      isFlagged: false,
      hasAttachment: false,
    );

void main() {
  group('similarFilterFor', () {
    test('returns from-contains + subject-contains for typical seed', () {
      final seed = _seed(
        subject: 'Re: Big sale!! ',
        from: const [EmailAddress(name: 'Spam', email: 'spammer@example.com')],
      );
      final group = similarFilterFor(seed);

      expect(group.operator, FilterOperator.and_);
      expect(group.children, hasLength(2));

      final fromLeaf = group.children[0] as FilterLeaf;
      expect(fromLeaf.field, FilterField.from_);
      expect(fromLeaf.comparison, FilterComparison.contains);
      expect(fromLeaf.value, 'spammer@example.com');

      final subjLeaf = group.children[1] as FilterLeaf;
      expect(subjLeaf.field, FilterField.subject);
      expect(subjLeaf.comparison, FilterComparison.contains);
      expect(subjLeaf.value, 'big sale!!');
    });

    test('omits subject leaf when seed subject normalises to empty', () {
      final seed = _seed(
        subject: '   ',
        from: const [EmailAddress(email: 'a@b.com')],
      );
      final group = similarFilterFor(seed);
      expect(group.children, hasLength(1));
      expect((group.children[0] as FilterLeaf).field, FilterField.from_);
    });

    test('omits from leaf when seed has no from address', () {
      final seed = _seed(subject: 'Re: hello');
      final group = similarFilterFor(seed);
      expect(group.children, hasLength(1));
      final leaf = group.children[0] as FilterLeaf;
      expect(leaf.field, FilterField.subject);
      expect(leaf.value, 'hello');
    });

    test('uses only the first from address when multiple are present', () {
      final seed = _seed(
        subject: 'x',
        from: const [
          EmailAddress(email: 'first@example.com'),
          EmailAddress(email: 'second@example.com'),
        ],
      );
      final group = similarFilterFor(seed);
      final fromLeaf = group.children[0] as FilterLeaf;
      expect(fromLeaf.value, 'first@example.com');
    });

    test('returns empty group for empty seed', () {
      final seed = _seed();
      final group = similarFilterFor(seed);
      expect(group.isEmpty, isTrue);
    });
  });

  group('senderFilterFor', () {
    test('OR-combines from/to/cc contains on the sender address', () {
      final seed = _seed(
        from: const [EmailAddress(name: 'Spam', email: 'spammer@example.com')],
      );
      final group = senderFilterFor(seed);

      expect(group.operator, FilterOperator.or_);
      expect(group.children, hasLength(3));

      final leaves = group.children.cast<FilterLeaf>();
      expect(
        leaves.map((l) => l.field),
        [FilterField.from_, FilterField.to, FilterField.cc],
      );
      for (final leaf in leaves) {
        expect(leaf.comparison, FilterComparison.contains);
        expect(leaf.value, 'spammer@example.com');
      }
    });

    test('uses only the first from address when multiple are present', () {
      final seed = _seed(
        from: const [
          EmailAddress(email: 'first@example.com'),
          EmailAddress(email: 'second@example.com'),
        ],
      );
      final group = senderFilterFor(seed);
      for (final leaf in group.children.cast<FilterLeaf>()) {
        expect(leaf.value, 'first@example.com');
      }
    });

    test('returns empty group when seed has no from address', () {
      final group = senderFilterFor(_seed());
      expect(group.isEmpty, isTrue);
    });
  });
}
