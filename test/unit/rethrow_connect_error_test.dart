// A refused connection read "SocketException: Connection refused …,
// address = localhost, port = 38920" in the Outbox: dart:io reports this
// device's own source port, so the user was pointed at a port they never
// configured instead of the SMTP port they had typed wrong.

import 'dart:io';

import 'package:sharedinbox/data/imap/imap_client_factory.dart'
    show rethrowConnectError;
import 'package:sharedinbox/data/imap/tls_error.dart';
import 'package:test/test.dart';

void main() {
  Object caught(Object error) {
    try {
      rethrowConnectError(error, StackTrace.current, 'localhost', 1026);
    } catch (e) {
      return e;
    }
  }

  test('a socket error names the server and its port', () {
    final e = caught(
      const SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
        port: 38920,
      ),
    );

    // Still a SocketException, so retries and offline handling see it.
    expect(e, isA<SocketException>());
    final s = e as SocketException;
    expect(s.port, 1026);
    expect(s.osError?.errorCode, 111);
    expect(
      s.toString(),
      allOf(
        contains('Could not connect to localhost:1026: Connection refused'),
        isNot(contains('38920')),
      ),
    );
  });

  test('TLS failures still get their hint', () {
    final e = caught(const HandshakeException('WRONG_VERSION_NUMBER'));
    expect(e, isA<TlsModeMismatchException>());
  });

  test('anything else is rethrown unchanged', () {
    final original = StateError('boom');
    expect(caught(original), same(original));
  });
}
