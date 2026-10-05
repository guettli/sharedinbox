import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

import 'fake_imap.dart';

/// Records the STARTTLS-related calls [upgradeImapToStartTls] makes.
class _StartTlsSpyClient extends FakeImapClient {
  _StartTlsSpyClient({
    List<String> greetingCapabilities = const [],
    this.capabilityResponse = const [],
    this.startTlsError,
  }) {
    serverInfo.capabilities =
        greetingCapabilities.map(imap.Capability.new).toList();
  }

  /// What a `CAPABILITY` command reports.
  final List<String> capabilityResponse;

  /// When non-null, `startTls()` throws this instead of succeeding.
  final Object? startTlsError;

  int capabilityCalls = 0;
  int startTlsCalls = 0;

  @override
  Future<List<imap.Capability>> capability() async {
    capabilityCalls++;
    final caps = capabilityResponse.map(imap.Capability.new).toList();
    serverInfo.capabilities = caps;
    return caps;
  }

  @override
  Future<imap.GenericImapResult> startTls() async {
    startTlsCalls++;
    final err = startTlsError;
    if (err != null) throw err;
    return imap.GenericImapResult();
  }
}

Account _account({required String host, required bool imapSsl}) => Account(
      id: 'acc-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: host,
      imapPort: 143,
      imapSsl: imapSsl,
      smtpHost: host,
    );

void main() {
  group('upgradeImapToStartTls', () {
    test('issues STARTTLS once when the greeting advertises it', () async {
      final client = _StartTlsSpyClient(
        greetingCapabilities: ['IMAP4rev1', 'STARTTLS'],
      );

      await upgradeImapToStartTls(client, 'mail.example.com', 143);

      expect(client.startTlsCalls, 1);
      expect(client.capabilityCalls, 0);
    });

    test('asks for CAPABILITY when the greeting carried none', () async {
      final client = _StartTlsSpyClient(
        capabilityResponse: ['IMAP4rev1', 'STARTTLS'],
      );

      await upgradeImapToStartTls(client, 'mail.example.com', 143);

      expect(client.capabilityCalls, 1);
      expect(client.startTlsCalls, 1);
    });

    test('refuses a server that does not advertise STARTTLS', () async {
      final client = _StartTlsSpyClient(
        greetingCapabilities: ['IMAP4rev1', 'AUTH=PLAIN'],
      );

      await expectLater(
        upgradeImapToStartTls(client, 'mail.example.com', 1143),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('STARTTLS') &&
                e.toString().contains('mail.example.com:1143'),
          ),
        ),
      );
      // No plaintext fallback, and no attempt to upgrade either.
      expect(client.startTlsCalls, 0);
    });

    test('a failed TLS handshake surfaces as the TLS hint', () async {
      final client = _StartTlsSpyClient(
        greetingCapabilities: ['STARTTLS'],
        startTlsError: Exception(
          'HandshakeException: Connection terminated during handshake',
        ),
      );

      await expectLater(
        upgradeImapToStartTls(client, 'mail.example.com', 143),
        throwsA(
          isA<TlsHandshakeAbortedException>()
              .having((e) => e.host, 'host', 'mail.example.com')
              .having((e) => e.port, 'port', 143)
              .having((e) => e.hint, 'hint', 'IMAP STARTTLS upgrade'),
        ),
      );
    });
  });

  group('imapNeedsStartTls', () {
    test('remote host with imapSsl: false requires STARTTLS', () {
      expect(
        imapNeedsStartTls(_account(host: 'mail.example.com', imapSsl: false)),
        isTrue,
      );
    });

    test('implicit TLS never upgrades', () {
      expect(
        imapNeedsStartTls(_account(host: 'mail.example.com', imapSsl: true)),
        isFalse,
      );
      expect(
        imapNeedsStartTls(_account(host: 'localhost', imapSsl: true)),
        isFalse,
      );
    });

    // The backend suite (test/backend/stalwart_harness.dart) talks plaintext
    // to a dev Stalwart with no certificate; an upgrade attempt there would
    // break every backend test.
    test('localhost with imapSsl: false stays plaintext', () {
      for (final host in ['localhost', '127.0.0.1', '::1']) {
        expect(
          imapNeedsStartTls(_account(host: host, imapSsl: false)),
          isFalse,
          reason: host,
        );
      }
    });
  });
}
