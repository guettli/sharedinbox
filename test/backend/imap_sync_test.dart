// Integration tests — requires a running Stalwart instance.
// Run via: stalwart-dev/test.sh
//
// Uses paired pool users from stalwart_harness.dart (aliceN + bobN at the
// same shard) so this file can run in parallel with the rest of the suite.

import 'package:enough_mail/enough_mail.dart';
import 'package:test/test.dart';

import 'stalwart_harness.dart';

void main() {
  late StalwartEnv env;
  late StalwartTestUser alice;
  late StalwartTestUser bob;

  setUpAll(() {
    env = StalwartEnv.fromPlatform();
    alice = pickPoolUser(env: env);
    bob = pickPoolUser(env: env, prefix: 'bob');
  });

  test('login and list mailboxes', () async {
    final client = await connectImap(env: env, user: alice);
    addTearDown(() => client.logout().ignore());

    final mailboxes = await client.listMailboxes();
    expect(mailboxes, isNotEmpty);
    expect(mailboxes.map((m) => m.name), contains('INBOX'));
  });

  test('send via SMTP and receive via IMAP', () async {
    // Empty bob's INBOX so the messagesExists check reflects this send only.
    final bobClient = await connectImap(env: env, user: bob);
    try {
      await clearMailbox(bobClient);
    } finally {
      await bobClient.logout();
    }

    final smtpClient = SmtpClient('sharedinbox-test');
    await smtpClient.connectToServer(
      env.smtpHost,
      env.smtpPort,
      isSecure: false,
    );
    await smtpClient.ehlo();
    await smtpClient.authenticate(alice.email, alice.password);

    final builder = MessageBuilder()
      ..from = [MailAddress(alice.email, alice.email)]
      ..to = [MailAddress(bob.email, bob.email)]
      ..subject = 'Integration test ${DateTime.now().millisecondsSinceEpoch}'
      ..text = 'Hello from SharedInbox integration test.';
    await smtpClient.sendMessage(builder.buildMimeMessage());
    await smtpClient.quit();

    // Give Stalwart a moment to deliver the message.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final imapClient = await connectImap(env: env, user: bob);
    addTearDown(() => imapClient.logout().ignore());

    final inbox = await imapClient.selectMailboxByPath('INBOX');
    expect(inbox.messagesExists, greaterThan(0));
  });
}
