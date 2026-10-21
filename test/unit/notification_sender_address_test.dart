import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/ui/screens/notifications_screen.dart';

void main() {
  test('takes a bare address as is', () {
    expect(senderAddress('alice@example.com'), 'alice@example.com');
  });

  test('takes the address out of a pasted "Name <address>"', () {
    // Stored whole, it was compared with the bare sender address and never
    // matched any mail.
    expect(senderAddress('Alice <alice@example.com>'), 'alice@example.com');
    expect(
      senderAddress('"Doe, John" <john@example.com> '),
      'john@example.com',
    );
    expect(senderAddress('mailto:alice@example.com'), 'alice@example.com');
  });

  test('refuses what is not an address', () {
    expect(senderAddress('alice'), isNull);
    expect(senderAddress('Alice <alice>'), isNull);
    expect(senderAddress('a b@example.com'), isNull);
  });
}
