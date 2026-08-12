import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/sieve/sieve_actions.dart';
import 'package:sharedinbox/core/sieve/sieve_serializer.dart';

// Regression tests for #499: a leading (or trailing) space inside a match
// value was serialised verbatim, so the delivered rule never matched.

void main() {
  final ser = SieveSerializer();

  String serializeLeaf(FilterLeaf leaf, List<SieveAction> actions) =>
      ser.serialize(_and(leaf), actions);

  test('header name and value are trimmed', () {
    final leaf = _leaf(
      FilterField.header,
      ' postmaster@thomas-guettler.de ',
      header: ' Delivered-To ',
    );
    final script = serializeLeaf(leaf, [FileIntoAction('  postmaster  ')]);
    expect(
      script,
      contains('header :is "Delivered-To" "postmaster@thomas-guettler.de"'),
    );
    expect(script, contains('fileinto "postmaster";'));
    expect(script, isNot(contains('" postmaster')));
  });

  test('address match value is trimmed', () {
    final leaf = _leaf(FilterField.from_, '  alice@example.com  ');
    final script = serializeLeaf(leaf, [KeepAction()]);
    expect(script, contains('"from" "alice@example.com"'));
    expect(script, isNot(contains('" alice')));
  });
}

FilterLeaf _leaf(FilterField field, String value, {String? header}) =>
    FilterLeaf(
      field: field,
      comparison: FilterComparison.is_,
      value: value,
      headerName: header,
    );

FilterGroup _and(FilterLeaf leaf) =>
    FilterGroup(operator: FilterOperator.and_, children: [leaf]);
