import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/recipient_check.dart';

void main() {
  test('accepts bare addresses and the Name <address> form', () {
    expect(
      invalidRecipients(
        'alice@example.com, Bob <bob@example.org>; carol@localhost,'
        ' jürgen@müller.de, dave+news@example.com',
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

  test(
      'two bracketed addresses in one entry are not taken as name and '
      'address', () {
    expect(invalidRecipients('<a@b.c> <d@e.f>'), ['<a@b.c> <d@e.f>']);
    // An address-looking name is common in pasted headers and stays valid.
    expect(invalidRecipients('x@y.z <a@b.c>'), isEmpty);
  });

  test('a quoted name may contain commas and semicolons', () {
    final addresses = recipientAddresses(
      '"Doe, John" <john@example.com>; "A; \\"B\\"" <ab@example.com>',
    );
    expect(addresses.map((a) => a.email), [
      'john@example.com',
      'ab@example.com',
    ]);
    expect(addresses.map((a) => a.name), ['Doe, John', 'A; "B"']);
  });

  test('splits name and address, so sending gets a bare address', () {
    final a = recipientAddresses('Bob <bob@example.org>').single;
    expect(a.name, 'Bob');
    expect(a.email, 'bob@example.org');
    expect(recipientAddresses('bob@example.org').single.name, isNull);
  });
}
