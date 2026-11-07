// Regression test: a socket that dies between the TCP/TLS connect and the
// server greeting (Android's "Software caused connection abort", errno 103,
// when the network drops) used to leave enough_mail's greeting future pending.
// connectImap then waited the full 45s greeting bound and reported "the mail
// server was reached but did not answer in time" — not retried, because a
// greeting timeout is treated as permanent for the attempt. Two folders of one
// sync cycle failed that way in a real Sync Entry.
//
// The connect must now fail as soon as the connection is lost, as a
// SocketException, which connectWithRetry retries.

import 'dart:convert';
import 'dart:io';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:test/test.dart';

Account _account(int port) => Account(
      id: 'greeting-acc',
      displayName: 'Greeting Test',
      email: 'user@example.com',
      imapHost: '127.0.0.1',
      imapPort: port,
      imapSsl: false,
      smtpHost: 'smtp.example.com',
    );

void main() {
  test('connection closed before the greeting fails fast and is retried',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var accepted = 0;
    server.listen((socket) {
      accepted++;
      socket.destroy();
    });

    final watch = Stopwatch()..start();
    await expectLater(
      connectImap(_account(server.port), 'user', 'secret'),
      throwsA(isA<SocketException>()),
    );
    watch.stop();

    // Initial attempt + two retries, not one 45s greeting timeout.
    expect(accepted, 3);
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('a connection lost once before the greeting recovers on retry',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var accepted = 0;
    server.listen((socket) {
      accepted++;
      if (accepted == 1) {
        socket.destroy();
        return;
      }
      socket.write('* OK IMAP4rev1 ready\r\n');
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final tag = line.split(' ').first;
        if (line.contains('LOGIN')) {
          socket.write('$tag OK LOGIN completed\r\n');
        } else if (line.contains('LOGOUT')) {
          // No server-side close: destroy() may drop the queued reply, and
          // the client closes the connection itself after LOGOUT.
          socket.write('* BYE\r\n$tag OK LOGOUT completed\r\n');
        }
      });
    });

    final client = await connectImap(_account(server.port), 'user', 'secret');
    expect(client.isLoggedIn, isTrue);
    expect(accepted, 2);
    await client.logout();
  });
}
