// #1224: when the socket dies mid-session (Android's "Software caused
// connection abort", errno 103), enough_mail left the pending command to its
// 20s response timeout and failed later ones with "Bad state: Cannot add event
// after closing", so the Sync Entry said "the server did not answer in time".
// The client from connectImap now fails them at once, as a
// ConnectionLostException.

import 'dart:convert';
import 'dart:io';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/net/connection_lost_exception.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:test/test.dart';

Account _account(int port) => Account(
      id: 'lost-acc',
      displayName: 'Lost Test',
      email: 'user@example.com',
      imapHost: '127.0.0.1',
      imapPort: port,
      imapSsl: false,
      smtpHost: 'smtp.example.com',
    );

/// A server that greets, accepts LOGIN and drops the connection, without a
/// reply, on the next command (`selectMailboxByPath` starts with a LIST).
Future<ServerSocket> _droppingServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    socket.write('* OK IMAP4rev1 ready\r\n');
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final tag = line.split(' ').first;
      if (line.contains('LOGIN')) {
        socket.write('$tag OK LOGIN completed\r\n');
        return;
      }
      socket.destroy();
    });
  });
  return server;
}

void main() {
  test('a pending command fails at once when the connection drops', () async {
    final server = await _droppingServer();
    addTearDown(server.close);
    final client = await connectImap(_account(server.port), 'user', 'secret');

    final watch = Stopwatch()..start();
    await expectLater(
      client.selectMailboxByPath('INBOX'),
      throwsA(isA<ConnectionLostException>()),
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 10)),
      reason: 'not after the 20s response timeout',
    );
    expect(client.isConnected, isFalse);

    // Every later command fails the same way, right away.
    watch.reset();
    await expectLater(
      client.selectMailboxByPath('Trash'),
      throwsA(isA<ConnectionLostException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
