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

    test('rethrows other errors unchanged', () {
      final original = Exception('Some other error');

      expect(
        () =>
            rethrowAsTlsHint(original, StackTrace.current, 'example.com', 465),
        throwsA(original),
      );
    });
  });
}
