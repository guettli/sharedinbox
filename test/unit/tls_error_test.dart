import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

void main() {
  group('rethrowAsTlsHint', () {
    test('wraps WRONG_VERSION_NUMBER into TlsModeMismatchException', () {
      final original = Exception('Handshake error: WRONG_VERSION_NUMBER');

      expect(
        () =>
            rethrowAsTlsHint(original, StackTrace.current, 'example.com', 465),
        throwsA(
          isA<TlsModeMismatchException>().having(
            (e) => e.original,
            'original',
            original,
          ),
        ),
      );
    });

    test('wraps CERTIFICATE_VERIFY_FAILED into TlsCertificateException', () {
      final original = Exception(
        'HandshakeException: Handshake error in client '
        '(CERTIFICATE_VERIFY_FAILED: self signed certificate)',
      );

      expect(
        () =>
            rethrowAsTlsHint(original, StackTrace.current, 'example.com', 993),
        throwsA(isA<TlsCertificateException>()),
      );
    });

    test(
      'wraps "Connection terminated during handshake" into '
      'TlsHandshakeAbortedException (regression for #124)',
      () {
        final original = Exception(
          'HandshakeException: Connection terminated during handshake',
        );

        expect(
          () => rethrowAsTlsHint(
            original,
            StackTrace.current,
            'mail.thomas-guettler.de',
            4190,
          ),
          throwsA(
            isA<TlsHandshakeAbortedException>()
                .having((e) => e.host, 'host', 'mail.thomas-guettler.de')
                .having((e) => e.port, 'port', 4190)
                .having((e) => e.original, 'original', original),
          ),
        );
      },
    );

    test(
      'wraps "Connection reset by peer" during handshake into '
      'TlsHandshakeAbortedException',
      () {
        final original = Exception(
          'HandshakeException: Connection reset by peer',
        );

        expect(
          () => rethrowAsTlsHint(
            original,
            StackTrace.current,
            'example.com',
            4190,
          ),
          throwsA(isA<TlsHandshakeAbortedException>()),
        );
      },
    );

    test('forwards the optional hint into TlsHandshakeAbortedException', () {
      final original = Exception(
        'HandshakeException: Connection terminated during handshake',
      );

      expect(
        () => rethrowAsTlsHint(
          original,
          StackTrace.current,
          'mail.thomas-guettler.de',
          4190,
          hint: 'STARTTLS reply: OK "Begin TLS"',
        ),
        throwsA(
          isA<TlsHandshakeAbortedException>().having(
            (e) => e.hint,
            'hint',
            'STARTTLS reply: OK "Begin TLS"',
          ),
        ),
      );
    });

    test('rethrows other errors unchanged', () {
      final original = Exception('Some other error');

      expect(
        () =>
            rethrowAsTlsHint(original, StackTrace.current, 'example.com', 465),
        throwsA(original),
      );
    });
  });

  group('isTlsConfigError', () {
    test('returns true for TlsModeMismatchException', () {
      final e = TlsModeMismatchException('h', 1, Exception('x'));
      expect(isTlsConfigError(e), isTrue);
    });

    test('returns true for TlsCertificateException', () {
      final e = TlsCertificateException('h', 1, Exception('x'));
      expect(isTlsConfigError(e), isTrue);
    });

    test(
      'returns false for TlsHandshakeAbortedException — handshake aborts '
      'can be transient, so sync should keep retrying',
      () {
        final e = TlsHandshakeAbortedException('h', 1, Exception('x'));
        expect(isTlsConfigError(e), isFalse);
      },
    );

    test('returns false for unrelated errors', () {
      expect(isTlsConfigError(Exception('boom')), isFalse);
    });
  });
}
