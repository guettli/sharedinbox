import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/filter/filter_sieve_converter.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_serializer.dart';

void main() {
  group('FilterGroup', () {
    test('empty() creates an empty group', () {
      final g = FilterGroup.empty();
      expect(g.isEmpty, isTrue);
      expect(g.children, isEmpty);
      expect(g.operator, FilterOperator.and_);
    });

    test('non-empty group is not isEmpty', () {
      final g = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.contains,
            value: 'test',
          ),
        ],
      );
      expect(g.isEmpty, isFalse);
    });

    test('copyWith changes operator', () {
      final g = FilterGroup.empty().copyWith(operator: FilterOperator.or_);
      expect(g.operator, FilterOperator.or_);
    });

    test('copyWith changes children', () {
      final leaf = FilterLeaf(
        field: FilterField.subject,
        comparison: FilterComparison.contains,
        value: 'hello',
      );
      final g = FilterGroup.empty().copyWith(children: [leaf]);
      expect(g.children, hasLength(1));
    });
  });

  group('FilterLeaf', () {
    test('copyWith changes field', () {
      final leaf = FilterLeaf(
        field: FilterField.from_,
        comparison: FilterComparison.contains,
        value: 'x',
      );
      final updated = leaf.copyWith(field: FilterField.to);
      expect(updated.field, FilterField.to);
      expect(updated.comparison, FilterComparison.contains);
      expect(updated.value, 'x');
    });

    test('copyWith changes value', () {
      final leaf = FilterLeaf(
        field: FilterField.subject,
        comparison: FilterComparison.is_,
        value: 'old',
      );
      final updated = leaf.copyWith(value: 'new');
      expect(updated.value, 'new');
      expect(updated.field, FilterField.subject);
    });

    test('size field allows over/under comparisons', () {
      expect(
        FilterField.size.allowedComparisons,
        containsAll([FilterComparison.over, FilterComparison.under]),
      );
    });

    test('address fields do not allow over/under', () {
      for (final f in [FilterField.from_, FilterField.to, FilterField.cc]) {
        expect(f.allowedComparisons, isNot(contains(FilterComparison.over)));
        expect(f.allowedComparisons, isNot(contains(FilterComparison.under)));
      }
    });
  });

  group('SieveSerializer', () {
    final ser = SieveSerializer();

    test('empty filter with keep action', () {
      final script = ser.serialize(FilterGroup.empty(), [KeepAction()]);
      expect(script, contains('keep;'));
      expect(script, isNot(contains('if ')));
    });

    test('single from-contains condition', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.contains,
            value: 'alice',
          ),
        ],
      );
      final script = ser.serialize(group, [FileIntoAction('Work')]);
      expect(script, contains('require'));
      expect(script, contains('fileinto'));
      expect(script, contains('"Work"'));
      expect(script, contains(':contains'));
      expect(script, contains('"from"'));
      expect(script, contains('"alice"'));
    });

    test('AND group serialises as allof', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'invoice',
          ),
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.contains,
            value: 'supplier',
          ),
        ],
      );
      final script = ser.serialize(group, [KeepAction()]);
      expect(script, contains('allof'));
    });

    test('OR group serialises as anyof', () {
      final group = FilterGroup(
        operator: FilterOperator.or_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'a',
          ),
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'b',
          ),
        ],
      );
      final script = ser.serialize(group, [DiscardAction()]);
      expect(script, contains('anyof'));
      expect(script, contains('discard;'));
    });

    test('size over condition', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.size,
            comparison: FilterComparison.over,
            value: '1000000',
          ),
        ],
      );
      final script = ser.serialize(group, [DiscardAction()]);
      expect(script, contains('size :over 1000000'));
    });

    test('mark-as-seen action emits setflag', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'newsletter',
          ),
        ],
      );
      final script = ser.serialize(group, [MarkAsSeenAction()]);
      expect(script, contains('setflag'));
      expect(script, contains(r'\Seen'));
    });

    test('star-message action emits setflag \\Flagged with imap4flags require',
        () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.contains,
            value: 'boss',
          ),
        ],
      );
      final script = ser.serialize(group, [StarMessageAction()]);
      expect(script, contains('require'));
      expect(script, contains('imap4flags'));
      expect(script, contains('setflag'));
      expect(script, contains(r'\Flagged'));
    });

    test('folder field throws — not representable in Sieve', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.folder,
            comparison: FilterComparison.is_,
            value: 'INBOX',
          ),
        ],
      );
      expect(
        () => ser.serialize(group, [KeepAction()]),
        throwsA(isA<StateError>()),
      );
    });

    test('escapes quotes in values', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'say "hello"',
          ),
        ],
      );
      final script = ser.serialize(group, [KeepAction()]);
      expect(script, contains(r'say \"hello\"'));
    });
  });

  group('FilterSieveConverter', () {
    final conv = FilterSieveConverter();

    test('returns null for empty script', () {
      expect(conv.parse(''), isNull);
    });

    test('parses simple address test', () {
      const script = '''
if address :contains "from" "alice@example.com" {
  keep;
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.group.children, hasLength(1));
      final leaf = result.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.from_);
      expect(leaf.comparison, FilterComparison.contains);
      expect(leaf.value, 'alice@example.com');
      expect(result.actions, hasLength(1));
      expect(result.actions.first, isA<KeepAction>());
    });

    test('parses subject header test', () {
      const script = '''
if header :is "subject" "Hello" {
  fileinto "Inbox";
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      final leaf = result!.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.subject);
      expect(leaf.comparison, FilterComparison.is_);
      expect(leaf.value, 'Hello');
      final action = result.actions.first as FileIntoAction;
      expect(action.folder, 'Inbox');
    });

    test('parses allof group as AND', () {
      const script = '''
if allof(
  address :contains "from" "alice",
  header :contains "subject" "invoice"
) {
  keep;
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.group.operator, FilterOperator.and_);
      expect(result.group.children, hasLength(2));
    });

    test('parses anyof group as OR', () {
      const script = '''
if anyof(
  address :contains "from" "a",
  address :contains "from" "b"
) {
  discard;
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.group.operator, FilterOperator.or_);
      expect(result.actions.first, isA<DiscardAction>());
    });

    test('parses size over test', () {
      const script = '''
if size :over 500000 {
  discard;
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      final leaf = result!.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.size);
      expect(leaf.comparison, FilterComparison.over);
      expect(leaf.value, '500000');
    });

    test('parses setflag \\\\Seen as MarkAsSeenAction', () {
      const script = r'''
if header :contains "subject" "newsletter" {
  setflag "\\Seen";
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.actions.first, isA<MarkAsSeenAction>());
    });

    test('parses setflag \\\\Flagged as StarMessageAction', () {
      const script = r'''
if address :contains "from" "boss@example.com" {
  setflag "\\Flagged";
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.actions.first, isA<StarMessageAction>());
    });

    test('star-message round-trips through serializer', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'invoice',
          ),
        ],
      );
      final script = SieveSerializer().serialize(group, [StarMessageAction()]);
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.actions, hasLength(1));
      expect(result.actions.first, isA<StarMessageAction>());
    });

    test('returns null for unsupported test', () {
      const script = '''
if exists "X-Custom-Header" {
  keep;
}''';
      expect(conv.parse(script), isNull);
    });

    test('round-trips through serializer', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.from_,
            comparison: FilterComparison.contains,
            value: 'alice@example.com',
          ),
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'invoice',
          ),
        ],
      );
      final actions = <SieveAction>[FileIntoAction('Work')];
      final script = SieveSerializer().serialize(group, actions);
      final result = conv.parse(script);
      expect(result, isNotNull);
      expect(result!.group.operator, FilterOperator.and_);
      expect(result.group.children, hasLength(2));
      expect(result.actions, hasLength(1));
      expect((result.actions.first as FileIntoAction).folder, 'Work');
    });

    test('parses require block and ignores it', () {
      const script = '''
require ["fileinto"];
if address :contains "from" "bob" {
  fileinto "Archive";
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      final leaf = result!.group.children.first as FilterLeaf;
      expect(leaf.value, 'bob');
    });

    test('parses arbitrary header test into FilterField.header', () {
      const script = '''
if header :is "List-Id" "<newsletter.example.com>" {
  fileinto "Newsletters";
}''';
      final result = conv.parse(script);
      expect(result, isNotNull);
      final leaf = result!.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.header);
      expect(leaf.headerName, 'List-Id');
      expect(leaf.comparison, FilterComparison.is_);
      expect(leaf.value, '<newsletter.example.com>');
    });

    test('header round-trips through serializer preserving header name', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.header,
            comparison: FilterComparison.is_,
            value: 'Yes',
            headerName: 'X-Spam-Status',
          ),
        ],
      );
      final script = SieveSerializer().serialize(group, [KeepAction()]);
      expect(script, contains('header :is "X-Spam-Status" "Yes"'));
      final parsed = conv.parse(script);
      expect(parsed, isNotNull);
      final leaf = parsed!.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.header);
      expect(leaf.headerName, 'X-Spam-Status');
      expect(leaf.value, 'Yes');
      expect(leaf.comparison, FilterComparison.is_);
    });

    test('subject header still round-trips as FilterField.subject', () {
      final group = FilterGroup(
        operator: FilterOperator.and_,
        children: [
          FilterLeaf(
            field: FilterField.subject,
            comparison: FilterComparison.contains,
            value: 'invoice',
          ),
        ],
      );
      final script = SieveSerializer().serialize(group, [KeepAction()]);
      final parsed = conv.parse(script);
      expect(parsed, isNotNull);
      final leaf = parsed!.group.children.first as FilterLeaf;
      expect(leaf.field, FilterField.subject);
      expect(leaf.headerName, isNull);
    });
  });
}
