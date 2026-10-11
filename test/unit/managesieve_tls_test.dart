import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/utils/host_utils.dart';
import 'package:sharedinbox/data/imap/managesieve_client.dart';

void main() {
  // Shared seam is a process-wide static; clear after each test.
  tearDown(debugAllowedPlaintextHosts.clear);

  group('isPlaintextAllowedHost', () {
    test('localhost forms are always allowed', () {
      for (final h in ['localhost', '127.0.0.1', '::1', 'LOCALHOST']) {
        expect(isPlaintextAllowedHost(h), isTrue, reason: h);
      }
    });

    test('a remote host is not allowed by default', () {
      expect(isPlaintextAllowedHost('sieve.example.com'), isFalse);
    });

    test('a registered dev host is allowed, and only that host', () {
      debugAllowedPlaintextHosts.add('stalwart');
      expect(isPlaintextAllowedHost('stalwart'), isTrue);
      expect(isPlaintextAllowedHost('other.example.com'), isFalse);
    });
  });

  group('ManageSieveClient.connect plaintext guard', () {
    test('refuses plaintext to a remote host before opening a socket',
        () async {
      // The guard is the first statement in connect, before Socket.connect, so
      // this throws without any network — a remote plaintext ManageSieve
      // connection would otherwise AUTHENTICATE PLAIN in the clear (#1019).
      await expectLater(
        ManageSieveClient.connect(
          host: 'sieve.example.com',
          port: 4190,
          useTls: false,
        ),
        throwsA(
          isA<ManageSieveException>().having(
            (e) => e.message,
            'message',
            contains('Refusing a plaintext'),
          ),
        ),
      );
    });
  });
}
