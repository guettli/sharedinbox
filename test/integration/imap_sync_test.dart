// Integration tests — requires a running Stalwart instance.
// Run via: stalwart-dev/test.sh  (sets the env vars below)
//
// STALWART_IMAP_HOST, STALWART_IMAP_PORT, STALWART_SMTP_HOST, STALWART_SMTP_PORT
// STALWART_USER_B / STALWART_PASS_B  (alice@localhost)
// STALWART_USER_C / STALWART_PASS_C  (bob@localhost)

import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:test/test.dart';

String _env(String key) {
  final v = Platform.environment[key];
  if (v == null || v.isEmpty) throw StateError('$key is not set');
  return v;
}

Future<ImapClient> _connect(
  String user,
  String pass, {
  required String host,
  required int port,
}) async {
  final client = ImapClient();
  await client.connectToServer(host, port, isSecure: false);
  await client.login(user, pass);
  return client;
}

void main() {
  late String imapHost;
  late int imapPort;
  late int smtpPort;
  late String userA, passA, userB, passB;

  setUpAll(() {
    imapHost = Platform.environment['STALWART_IMAP_HOST'] ?? '127.0.0.1';
    imapPort = int.parse(_env('STALWART_IMAP_PORT'));
    smtpPort = int.parse(_env('STALWART_SMTP_PORT'));
    userA = _env('STALWART_USER_B'); // alice
    passA = _env('STALWART_PASS_B');
    userB = _env('STALWART_USER_C'); // bob
    passB = _env('STALWART_PASS_C');
  });

  test('login and list mailboxes', () async {
    final client = await _connect(
      userA,
      passA,
      host: imapHost,
      port: imapPort,
    );
    addTearDown(() => client.logout().ignore());

    // listMailboxes() returns List<Mailbox> directly
    final mailboxes = await client.listMailboxes();
    expect(mailboxes, isNotEmpty);
    expect(mailboxes.map((m) => m.name), contains('INBOX'));
  });

  test('send via SMTP and receive via IMAP', () async {
    final smtpClient = SmtpClient('test');
    await smtpClient.connectToServer(imapHost, smtpPort, isSecure: false);
    await smtpClient.ehlo();
    await smtpClient.authenticate(userA, passA);

    final builder = MessageBuilder()
      ..from = [MailAddress('Alice', '$userA@localhost')]
      ..to = [MailAddress('Bob', '$userB@localhost')]
      ..subject = 'Integration test ${DateTime.now().millisecondsSinceEpoch}'
      ..text = 'Hello from SharedInbox integration test.';
    await smtpClient.sendMessage(builder.buildMimeMessage());
    await smtpClient.quit();

    // Give Stalwart a moment to deliver the message.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final imapClient = await _connect(
      userB,
      passB,
      host: imapHost,
      port: imapPort,
    );
    addTearDown(() => imapClient.logout().ignore());

    final inbox = await imapClient.selectMailboxByPath('INBOX');
    expect(inbox.messagesExists, greaterThan(0));
  });
}
