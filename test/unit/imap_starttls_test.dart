import 'dart:io' show HandshakeException;

import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

import 'fake_imap.dart';

/// Records the STARTTLS-related calls [upgradeImapToStartTls] makes.
class _StartTlsSpyImapClient extends FakeImapClient {
  _StartTlsSpyImapClient({
    List<String> greetingCapabilities = const [],
    this.capabilityResponse = const [],
    this.startTlsError,
  }) {
    serverInfo.capabilities =
        greetingCapabilities.map(imap.Capability.new).toList();
  }

  /// What a `CAPABILITY` command reports.
  final List<String> capabilityResponse;

  /// Thrown from [startTls] when non-null.
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
    final error = startTlsError;
    if (error != null) throw error;
    return imap.GenericImapResult();
  }
}

void main() {
  group('upgradeImapToStartTls', () {
    test('issues STARTTLS once when the greeting advertises it', () async {
      final client = _StartTlsSpyImapClient(
        greetingCapabilities: ['IMAP4rev1', 'STARTTLS'],
      );

      await upgradeImapToStartTls(client, 'mail.example.com', 143);

      expect(client.startTlsCalls, 1);
      expect(client.capabilityCalls, 0);
    });

    test('asks for CAPABILITY only when the greeting carried none', () async {
      final client = _StartTlsSpyImapClient(
        capabilityResponse: ['IMAP4rev1', 'STARTTLS'],
      );

      await upgradeImapToStartTls(client, 'mail.example.com', 143);

      expect(client.capabilityCalls, 1);
      expect(client.startTlsCalls, 1);
    });

    test('refuses a server that does not advertise STARTTLS', () async {
      final client = _StartTlsSpyImapClient(
        greetingCapabilities: ['IMAP4rev1'],
      );

      await expectLater(
        upgradeImapToStartTls(client, 'mail.example.com', 1430),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('STARTTLS'), contains('mail.example.com:1430')),
          ),
        ),
      );
      expect(client.startTlsCalls, 0);
    });

    test('a failed TLS handshake surfaces as a TLS hint', () async {
      final client = _StartTlsSpyImapClient(
        greetingCapabilities: ['IMAP4rev1', 'STARTTLS'],
        startTlsError:
            const HandshakeException('Connection terminated during handshake'),
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
    test('remote host with imapSsl off requires STARTTLS', () {
      expect(
        imapNeedsStartTls(imapSsl: false, host: 'mail.example.com'),
        isTrue,
      );
    });

    test('implicit TLS never upgrades', () {
      expect(
        imapNeedsStartTls(imapSsl: true, host: 'mail.example.com'),
        isFalse,
      );
      expect(imapNeedsStartTls(imapSsl: true, host: 'localhost'), isFalse);
    });

    // The backend suite connects to the dev Stalwart on localhost in
    // plaintext (no certificate configured); an upgrade attempt there would
    // break every backend test.
    test('localhost with imapSsl off stays plaintext', () {
      expect(imapNeedsStartTls(imapSsl: false, host: 'localhost'), isFalse);
      expect(imapNeedsStartTls(imapSsl: false, host: '127.0.0.1'), isFalse);
    });
  });
}
