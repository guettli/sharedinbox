import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/recipient_check.dart';

void main() {
  test('accepts bare addresses and the Name <address> form', () {
    expect(
      invalidRecipients(
        'alice@example.com, Bob <bob@example.org>; carol@localhost,',
      ),
      isEmpty,
    );
  });

  test('ignores empty entries', () {
    expect(invalidRecipients(' , ; '), isEmpty);
  });

  test('reports every entry that is not an address', () {
    expect(
      invalidRecipients(
        'alice@example.com, not-an-address, bob@, Carol <carol>, a b@c.de',
      ),
      ['not-an-address', 'bob@', 'Carol <carol>', 'a b@c.de'],
    );
  });
}
