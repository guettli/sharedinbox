import 'package:enough_mail/enough_mail.dart' as smtp;
import 'package:flutter_test/flutter_test.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/tls_error.dart';

/// Records the STARTTLS-related calls [upgradeSmtpToStartTls] makes, and lets a
/// test drive the server's reply.
class _StartTlsSpyClient extends smtp.SmtpClient {
  _StartTlsSpyClient({
    List<String> capabilities = const [],
    this.startTlsResponse,
    this.startTlsError,
  }) : super('test.local') {
    serverInfo = smtp.SmtpServerInfo('fake.host', 587, isSecure: false)
      ..capabilities = List.of(capabilities);
  }

  /// The response `startTls()` returns (defaults to a 2xx success). enough_mail
  /// RETURNS this rather than throwing on a non-success status, which is the
  /// whole reason the result must be checked.
  final smtp.SmtpResponse? startTlsResponse;

  /// When non-null, `startTls()` throws this instead of returning.
  final Object? startTlsError;

  int startTlsCalls = 0;

  @override
  Future<smtp.SmtpResponse> startTls() async {
    startTlsCalls++;
    final err = startTlsError;
    if (err != null) throw err;
    return startTlsResponse ?? smtp.SmtpResponse(['220 ready to start TLS']);
  }
}

Account _account({required String host, required bool smtpSsl}) => Account(
      id: 'acc-1',
      displayName: 'Alice',
      email: 'alice@example.com',
      smtpHost: host,
      smtpSsl: smtpSsl,
    );

void main() {
  group('upgradeSmtpToStartTls', () {
    test('issues STARTTLS once when the server advertises it and it succeeds',
        () async {
      final client = _StartTlsSpyClient(capabilities: ['STARTTLS', 'SIZE']);

      await upgradeSmtpToStartTls(client, 'smtp.example.com', 587);

      expect(client.startTlsCalls, 1);
    });

    test('refuses a server that does not advertise STARTTLS', () async {
      // The MITM strips STARTTLS from the EHLO response to force a downgrade.
      final client = _StartTlsSpyClient(capabilities: ['SIZE', 'AUTH LOGIN']);

      await expectLater(
        upgradeSmtpToStartTls(client, 'smtp.example.com', 1587),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('STARTTLS') &&
                e.toString().contains('smtp.example.com:1587'),
          ),
        ),
      );
      // No plaintext fallback, and no attempt to upgrade either — so no
      // credential can follow.
      expect(client.startTlsCalls, 0);
    });

    test('refuses a 1xx reply that leaves the socket un-upgraded', () async {
      // The crux: SmtpClient.startTls() upgrades only on a 2xx status and
      // returns the response otherwise. A 1xx is "accepted", so it is neither
      // OK nor a failure — without the result check the socket stays cleartext
      // and the AUTH that follows leaks the password. A stripped-STARTTLS MITM
      // that answers 150 is exactly this.
      final client = _StartTlsSpyClient(
        capabilities: ['STARTTLS'],
        startTlsResponse: smtp.SmtpResponse(['150 go ahead']),
      );

      await expectLater(
        upgradeSmtpToStartTls(client, 'smtp.example.com', 587),
        throwsA(
          predicate(
            (e) =>
                e.toString().contains('refusing to send credentials') &&
                e.toString().contains('smtp.example.com:587'),
          ),
        ),
      );
      expect(client.startTlsCalls, 1);
    });

    test('refuses a 4xx/5xx STARTTLS rejection', () async {
      final client = _StartTlsSpyClient(
        capabilities: ['STARTTLS'],
        startTlsResponse: smtp.SmtpResponse(['454 TLS not available']),
      );

      await expectLater(
        upgradeSmtpToStartTls(client, 'smtp.example.com', 587),
        throwsA(
          predicate(
            (e) => e.toString().contains('refusing to send credentials'),
          ),
        ),
      );
    });

    test('a failed TLS handshake surfaces as the TLS hint', () async {
      final client = _StartTlsSpyClient(
        capabilities: ['STARTTLS'],
        startTlsError: Exception(
          'HandshakeException: Connection terminated during handshake',
        ),
      );

      await expectLater(
        upgradeSmtpToStartTls(client, 'smtp.example.com', 587),
        throwsA(
          isA<TlsHandshakeAbortedException>()
              .having((e) => e.host, 'host', 'smtp.example.com')
              .having((e) => e.port, 'port', 587)
              .having((e) => e.hint, 'hint', 'SMTP STARTTLS upgrade'),
        ),
      );
    });
  });

  group('smtpNeedsStartTls', () {
    test('remote host with smtpSsl: false requires STARTTLS', () {
      expect(
        smtpNeedsStartTls(_account(host: 'smtp.example.com', smtpSsl: false)),
        isTrue,
      );
    });

    test('implicit TLS never upgrades', () {
      expect(
        smtpNeedsStartTls(_account(host: 'smtp.example.com', smtpSsl: true)),
        isFalse,
      );
      expect(
        smtpNeedsStartTls(_account(host: 'localhost', smtpSsl: true)),
        isFalse,
      );
    });

    // The backend suite talks plaintext to a dev server on localhost:25 with no
    // certificate; requiring STARTTLS there would break every backend test.
    test('localhost with smtpSsl: false stays plaintext', () {
      for (final host in ['localhost', '127.0.0.1', '::1']) {
        expect(
          smtpNeedsStartTls(_account(host: host, smtpSsl: false)),
          isFalse,
          reason: host,
        );
      }
    });
  });
}
