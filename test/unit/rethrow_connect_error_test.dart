// A refused connection read "SocketException: Connection refused …,
// address = localhost, port = 38920" in the Outbox: dart:io reports this
// device's own source port, so the user was pointed at a port they never
// configured instead of the SMTP port they had typed wrong.

import 'dart:io';

import 'package:sharedinbox/data/imap/tls_error.dart';
import 'package:test/test.dart';

void main() {
  final stack = StackTrace.current;

  (Object, StackTrace) caughtWithStack(Object error) {
    try {
      rethrowConnectError(error, stack, 'localhost', 1026);
    } catch (e, st) {
      return (e, st);
    }
  }

  Object caught(Object error) => caughtWithStack(error).$1;

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
    expect(s.osError?.errorCode, 111);
    expect(
      s.toString(),
      'SocketException: Could not connect to localhost:1026 '
      '(OS Error: Connection refused, errno = 111)',
    );
  });

  test('a DNS failure keeps its own message', () {
    final e = caught(
      const SocketException(
        "Failed host lookup: 'mail.example.org'",
        osError: OSError('No address associated with hostname', 7),
      ),
    );
    expect(
      e.toString(),
      contains(
        'Could not connect to localhost:1026: Failed host lookup: '
        "'mail.example.org'",
      ),
    );
  });

  test('keeps the original stack trace', () {
    final (_, st) =
        caughtWithStack(const SocketException('Connection refused'));
    expect(st, same(stack));
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
