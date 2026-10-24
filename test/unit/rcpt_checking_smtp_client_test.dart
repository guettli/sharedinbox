import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart'
    show SendNowOutcome;
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/rcpt_checking_smtp_client.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

/// A minimal SMTP server on loopback. [rcptReplies] maps a recipient address
/// to its `RCPT TO` reply (default `250 OK`). Records every command and the
/// DATA payload, so a test can tell whether anything was transmitted.
class _FakeSmtpServer {
  _FakeSmtpServer(this._server, this.rcptReplies) {
    _server.listen(_serve);
  }

  static Future<_FakeSmtpServer> start([
    Map<String, String> rcptReplies = const {},
  ]) async =>
      _FakeSmtpServer(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        rcptReplies,
      );

  final ServerSocket _server;
  final Map<String, String> rcptReplies;
  final commands = <String>[];
  String? data;

  int get port => _server.port;

  Future<void> close() => _server.close();

  void _serve(Socket socket) {
    socket.write('220 fake ESMTP\r\n');
    StringBuffer? dataBuffer;
    var pending = '';
    socket.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
      pending += chunk;
      while (true) {
        final end = pending.indexOf('\r\n');
        if (end < 0) break;
        final line = pending.substring(0, end);
        pending = pending.substring(end + 2);
        final inData = dataBuffer;
        if (inData != null) {
          if (line == '.') {
            data = inData.toString();
            dataBuffer = null;
            socket.write('250 2.0.0 Queued\r\n');
          } else {
            inData.write('$line\r\n');
          }
          continue;
        }
        commands.add(line);
        final verb = line.split(RegExp('[ :]')).first.toUpperCase();
        if (verb == 'RCPT') {
          final rcpt = RegExp('<(.*)>').firstMatch(line)!.group(1)!;
          socket.write('${rcptReplies[rcpt] ?? '250 2.1.5 OK'}\r\n');
        } else if (verb == 'DATA') {
          dataBuffer = StringBuffer();
          socket.write('354 go ahead\r\n');
        } else if (verb == 'QUIT') {
          // The client closes the connection itself.
          socket.write('221 bye\r\n');
        } else {
          // enough_mail waits for a multi-line EHLO reply.
          final reply = {
            'EHLO': '250-fake\r\n250 AUTH PLAIN',
            'AUTH': '235 ok',
          };
          socket.write('${reply[verb] ?? '250 OK'}\r\n');
        }
      }
    });
  }
}

const _rejectCarol = {'carol@example.com': '550 5.1.2 Mailbox does not exist.'};

Account _account(int port) => Account(
      id: 'acc-1',
      displayName: 'Bob',
      email: 'bob@example.com',
      smtpHost: '127.0.0.1',
      smtpPort: port,
      smtpSsl: false,
    );

void main() {
  late _FakeSmtpServer server;

  tearDown(() => server.close());

  /// Sends a message To carol, Cc alice through [connectSmtp], the production
  /// connect path.
  Future<void> send({String body = 'hi'}) async {
    final client = await connectSmtp(_account(server.port), 'bob', 'pw');
    try {
      final builder = imap.MessageBuilder()
        ..from = [const imap.MailAddress('Bob', 'bob@example.com')]
        ..subject = 'Test'
        ..text = body;
      await client.sendMessage(
        builder.buildMimeMessage(),
        recipients: const [
          imap.MailAddress('', 'carol@example.com'),
          imap.MailAddress('', 'alice@example.com'),
        ],
      );
    } finally {
      await client.quit();
    }
  }

  test('a rejected first recipient aborts before DATA: nobody gets it',
      () async {
    server = await _FakeSmtpServer.start(_rejectCarol);

    await expectLater(
      send(),
      throwsA(
        isA<SmtpRecipientsRejectedException>()
            .having((e) => e.isPermanent, 'isPermanent', isTrue)
            .having(
              (e) => e.toString(),
              'toString',
              'Rejected recipient carol@example.com: '
                  '5.1.2 Mailbox does not exist.',
            ),
      ),
    );
    expect(server.commands, contains('RCPT TO:<alice@example.com>'));
    expect(server.commands, contains('RSET'));
    expect(server.commands, isNot(contains('DATA')));
    expect(server.data, isNull);
  });

  test('a temporary (4xx) rejection is not permanent', () async {
    server = await _FakeSmtpServer.start({
      'alice@example.com': '450 4.2.1 Try later',
    });

    await expectLater(
      send(),
      throwsA(
        isA<SmtpRecipientsRejectedException>()
            .having((e) => e.isPermanent, 'isPermanent', isFalse)
            .having((e) => e.response.code, 'code', 450),
      ),
    );
    expect(server.data, isNull);
  });

  test('all recipients accepted: DATA is sent, dot-stuffed', () async {
    server = await _FakeSmtpServer.start();

    await send(body: 'line\r\n.hidden\r\nend');

    expect(server.commands, contains('DATA'));
    expect(server.commands, isNot(contains('RSET')));
    expect(server.data, contains('\r\n..hidden\r\n'));
  });

  test('the outbox fails the row naming the rejected address', () async {
    server = await _FakeSmtpServer.start(_rejectCarol);
    final db = openTestDatabase();
    addTearDown(db.close);
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final emails = EmailRepositoryImpl(db, accounts);
    await accounts.addAccount(_account(server.port), 'pw');

    final rowId = await emails.enqueueSend(
      'acc-1',
      const EmailDraft(
        from: EmailAddress(name: 'Bob', email: 'bob@example.com'),
        to: [EmailAddress(email: 'carol@example.com')],
        cc: [EmailAddress(email: 'alice@example.com')],
        subject: 'Test',
        body: 'Body',
      ),
    );
    final result = await emails.sendNow('acc-1', outboxRowId: rowId);

    expect(result.outcome, SendNowOutcome.permanentlyFailed);
    expect(
      result.message,
      'Rejected recipient carol@example.com: 5.1.2 Mailbox does not exist.',
    );
    expect(server.data, isNull);
  });
}
