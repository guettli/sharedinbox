// Regression test: when the connection dropped mid-command (Android's
// "Software caused connection abort", errno 103, during the draft sync's
// SELECT), the `finally { await client.logout(); }` that ended the session
// threw enough_mail's "Bad state: Cannot add event after closing". An
// exception thrown from `finally` replaces the one in flight, so the Sync
// Entry reported the LOGOUT failure instead of the lost connection.
//
// closeImapClient must never throw, and must not send LOGOUT on a dead
// connection.

import 'dart:async';
import 'dart:io';

import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:test/test.dart';

import 'fake_imap.dart';

class _ClosingSpyImapClient extends FakeImapClient {
  _ClosingSpyImapClient({
    required this.connected,
    this.logoutError,
    this.logoutHangs = false,
    this.disconnectError,
  });

  final bool connected;
  final Object? logoutError;
  final bool logoutHangs;
  final Object? disconnectError;
  int logouts = 0;
  int disconnects = 0;

  @override
  bool get isConnected => connected;

  @override
  Future<dynamic> logout() async {
    logouts++;
    if (logoutHangs) return Completer<void>().future;
    final error = logoutError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    final error = disconnectError;
    if (error != null) throw error;
  }
}

void main() {
  test('a live connection is logged out', () async {
    final client = _ClosingSpyImapClient(connected: true);

    await closeImapClient(client);

    expect(client.logouts, 1);
    expect(client.disconnects, 0);
  });

  test('a lost connection is dropped without LOGOUT', () async {
    final client = _ClosingSpyImapClient(connected: false);

    await closeImapClient(client);

    expect(client.logouts, 0);
    expect(client.disconnects, 1);
  });

  test('a failing LOGOUT is swallowed and the socket dropped', () async {
    final client = _ClosingSpyImapClient(
      connected: true,
      logoutError: StateError('Cannot add event after closing'),
    );

    await closeImapClient(client);

    expect(client.logouts, 1);
    expect(client.disconnects, 1);
  });

  test('an unanswered LOGOUT is bounded and the socket dropped', () async {
    final client = _ClosingSpyImapClient(connected: true, logoutHangs: true);

    await closeImapClient(client, timeout: const Duration(milliseconds: 10));

    expect(client.logouts, 1);
    expect(client.disconnects, 1);
  });

  test('logout: false drops even a live connection', () async {
    final client = _ClosingSpyImapClient(connected: true);

    await closeImapClient(client, logout: false);

    expect(client.logouts, 0);
    expect(client.disconnects, 1);
  });

  test('a failing disconnect is swallowed', () async {
    final client = _ClosingSpyImapClient(
      connected: false,
      disconnectError: const SocketException('already closed'),
    );

    await closeImapClient(client);

    expect(client.disconnects, 1);
  });

  test('the error that ended the session is the one reported', () async {
    final client = _ClosingSpyImapClient(
      connected: true,
      logoutError: StateError('Cannot add event after closing'),
    );

    Future<void> session() async {
      try {
        throw const SocketException('Software caused connection abort');
      } finally {
        await closeImapClient(client);
      }
    }

    await expectLater(session(), throwsA(isA<SocketException>()));
  });
}
