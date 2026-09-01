import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_matcher.dart';

MatchableMessage _msg({
  List<MatchAddress> from = const [],
  List<MatchAddress> to = const [],
  List<MatchAddress> cc = const [],
  String subject = '',
  int size = 0,
  String folder = '',
  Map<String, String> headers = const {},
}) =>
    MatchableMessage(
      from: from,
      to: to,
      cc: cc,
      subject: subject,
      size: size,
      folder: folder,
      headers: headers,
    );

FilterGroup _rule({
  required FilterField field,
  required FilterComparison comparison,
  required String value,
  String? headerName,
}) =>
    FilterGroup(
      operator: FilterOperator.or_,
      children: [
        FilterLeaf(
          field: field,
          comparison: comparison,
          value: value,
          headerName: headerName,
        ),
      ],
    );

void main() {
  group('matchesFilter', () {
    test('From is matches the sender address case-insensitively', () {
      final rule = _rule(
        field: FilterField.from_,
        comparison: FilterComparison.is_,
        value: 'Alice@Example.com',
      );
      final match =
          _msg(from: const [MatchAddress(email: 'alice@example.com')]);
      final noMatch =
          _msg(from: const [MatchAddress(email: 'bob@example.com')]);

      expect(matchesFilter(rule, match), isTrue);
      expect(matchesFilter(rule, noMatch), isFalse);
    });

    test('From contains matches on name or email substring', () {
      final rule = _rule(
        field: FilterField.from_,
        comparison: FilterComparison.contains,
        value: 'wonder',
      );
      final msg = _msg(
        from: const [MatchAddress(name: 'Alice Wonderland', email: 'a@x')],
      );

      expect(matchesFilter(rule, msg), isTrue);
    });

    test('Subject contains / is / matches', () {
      final contains = _rule(
        field: FilterField.subject,
        comparison: FilterComparison.contains,
        value: 'urgent',
      );
      final exact = _rule(
        field: FilterField.subject,
        comparison: FilterComparison.is_,
        value: 'hello',
      );
      final regex = _rule(
        field: FilterField.subject,
        comparison: FilterComparison.matches,
        value: r'^re:\s',
      );

      final urgent = _msg(subject: 'This is URGENT news');
      expect(matchesFilter(contains, urgent), isTrue);
      expect(matchesFilter(exact, _msg(subject: 'Hello')), isTrue);
      expect(matchesFilter(regex, _msg(subject: 'Re: your ticket')), isTrue);
    });

    test('header leaf matches only when the header is present', () {
      final rule = _rule(
        field: FilterField.header,
        comparison: FilterComparison.contains,
        value: 'list.example',
        headerName: 'List-Id',
      );
      final withHeader = _msg(headers: {'list-id': '<dev.list.example.com>'});

      expect(matchesFilter(rule, withHeader), isTrue);
      expect(matchesFilter(rule, _msg()), isFalse);
    });

    test('size over / under', () {
      final over = _rule(
        field: FilterField.size,
        comparison: FilterComparison.over,
        value: '100',
      );
      final under = _rule(
        field: FilterField.size,
        comparison: FilterComparison.under,
        value: '100',
      );

      expect(matchesFilter(over, _msg(size: 200)), isTrue);
      expect(matchesFilter(under, _msg(size: 50)), isTrue);
    });

    test('folder is', () {
      final rule = _rule(
        field: FilterField.folder,
        comparison: FilterComparison.is_,
        value: 'INBOX',
      );

      expect(matchesFilter(rule, _msg(folder: 'INBOX')), isTrue);
    });

    test('AND requires all children, OR requires any', () {
      final subjectLeaf = FilterLeaf(
        field: FilterField.subject,
        comparison: FilterComparison.contains,
        value: 'sale',
      );
      final fromLeaf = FilterLeaf(
        field: FilterField.from_,
        comparison: FilterComparison.is_,
        value: 'shop@example.com',
      );
      final msg = _msg(
        subject: 'Big sale',
        from: const [MatchAddress(email: 'other@example.com')],
      );
      final andGroup = FilterGroup(
        operator: FilterOperator.and_,
        children: [subjectLeaf, fromLeaf],
      );
      final orGroup = FilterGroup(
        operator: FilterOperator.or_,
        children: [subjectLeaf, fromLeaf],
      );

      expect(matchesFilter(andGroup, msg), isFalse);
      expect(matchesFilter(orGroup, msg), isTrue);
    });

    test('empty group never matches', () {
      final emptyAnd = FilterGroup.empty();
      final emptyOr = FilterGroup(operator: FilterOperator.or_, children: []);

      expect(matchesFilter(emptyAnd, _msg(subject: 'x')), isFalse);
      expect(matchesFilter(emptyOr, _msg(subject: 'x')), isFalse);
    });

    test('an invalid regex does not throw and simply does not match', () {
      final rule = _rule(
        field: FilterField.subject,
        comparison: FilterComparison.matches,
        value: '(',
      );

      expect(matchesFilter(rule, _msg(subject: 'anything')), isFalse);
    });
  });
}
