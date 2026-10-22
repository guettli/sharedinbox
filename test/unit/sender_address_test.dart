import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/sender_address.dart';

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

  group('trustedImageSenderPattern', () {
    test('stores the bare address out of a pasted "Name <address>"', () {
      // Stored whole, it was globbed against the bare sender address and
      // never matched, so the images stayed blocked.
      expect(
        trustedImageSenderPattern('Bob Smith <bob@example.org>'),
        'bob@example.org',
      );
      expect(
        trustedImageSenderPattern('  Alice@Example.COM  '),
        'alice@example.com',
      );
    });

    test('keeps glob patterns the matcher supports', () {
      expect(trustedImageSenderPattern('*@Example.com'), '*@example.com');
      expect(trustedImageSenderPattern('bob@*'), 'bob@*');
      expect(trustedImageSenderPattern('*@*.example.com'), '*@*.example.com');
      expect(trustedImageSenderPattern('*example.com'), '*example.com');
      expect(trustedImageSenderPattern('b?b@example.org'), 'b?b@example.org');
    });

    test('refuses entries that could never match a sender', () {
      expect(trustedImageSenderPattern('foo'), isNull);
      expect(trustedImageSenderPattern('example.com'), isNull);
      expect(trustedImageSenderPattern('bob@'), isNull);
      expect(trustedImageSenderPattern('a@b@c'), isNull);
      expect(trustedImageSenderPattern('bob smith@example.org'), isNull);
      expect(trustedImageSenderPattern('Bob <bob>'), isNull);
      expect(trustedImageSenderPattern('   '), isNull);
    });
  });
}
