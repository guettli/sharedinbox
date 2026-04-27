import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/core/models/discovery_result.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';
import 'package:test/test.dart';

const _autoconfigXml = '''<?xml version="1.0"?>
<clientConfig>
  <emailProvider>
    <incomingServer type="imap">
      <hostname>imap.example.com</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>smtp.example.com</hostname>
      <port>587</port>
      <socketType>STARTTLS</socketType>
    </outgoingServer>
  </emailProvider>
</clientConfig>''';

http.Client _clientFor(Map<String, http.Response> responses) {
  return MockClient((request) async {
    final key = request.url.toString();
    return responses[key] ?? http.Response('Not found', 404);
  });
}

AccountDiscoveryService _service(Map<String, http.Response> responses) =>
    AccountDiscoveryServiceImpl(_clientFor(responses));

void main() {
  group('AccountDiscoveryService', () {
    test('returns UnknownDiscovery for email without @', () async {
      final svc = _service({});
      final result = await svc.discover('notanemail');
      expect(result, isA<UnknownDiscovery>());
    });

    test(
        'returns JmapDiscovery with session URL when well-known/jmap returns 200',
        () async {
      final svc = _service({
        'https://example.com/.well-known/jmap': http.Response('{}', 200),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<JmapDiscovery>());
      expect(
        (result as JmapDiscovery).sessionUrl,
        'https://example.com/.well-known/jmap',
      );
    });

    test(
        'returns JmapDiscovery with redirect target when well-known/jmap returns 307',
        () async {
      final svc = _service({
        'https://example.com/.well-known/jmap': http.Response(
          '',
          307,
          headers: {'location': '/jmap/session'},
        ),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<JmapDiscovery>());
      expect(
        (result as JmapDiscovery).sessionUrl,
        'https://example.com/jmap/session',
      );
    });

    test('returns UnknownDiscovery when well-known/jmap returns 404', () async {
      final svc = _service({
        'https://example.com/.well-known/jmap': http.Response('', 404),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<UnknownDiscovery>());
    });

    test('returns ImapSmtpDiscovery from primary autoconfig URL', () async {
      final svc = _service({
        'https://autoconfig.example.com/mail/config-v1.1.xml':
            http.Response(_autoconfigXml, 200),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<ImapSmtpDiscovery>());
      final imap = result as ImapSmtpDiscovery;
      expect(imap.imapHost, 'imap.example.com');
      expect(imap.imapPort, 993);
      expect(imap.imapSsl, isTrue);
      expect(imap.smtpHost, 'smtp.example.com');
      expect(imap.smtpPort, 587);
      expect(imap.smtpSsl, isFalse);
    });

    test('returns ImapSmtpDiscovery from fallback well-known autoconfig URL',
        () async {
      final svc = _service({
        'https://example.com/.well-known/autoconfig/mail/config-v1.1.xml':
            http.Response(_autoconfigXml, 200),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<ImapSmtpDiscovery>());
    });

    test('prefers JMAP over IMAP when both respond', () async {
      final svc = _service({
        'https://example.com/.well-known/jmap': http.Response('{}', 200),
        'https://autoconfig.example.com/mail/config-v1.1.xml':
            http.Response(_autoconfigXml, 200),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<JmapDiscovery>());
    });

    test('returns UnknownDiscovery when nothing is found', () async {
      final svc = _service({});
      final result = await svc.discover('user@example.com');
      expect(result, isA<UnknownDiscovery>());
    });

    test('returns ImapSmtpDiscovery from MX record when autoconfig not found',
        () async {
      final svc = _service({
        'https://dns.google/resolve?name=example.com&type=MX': http.Response(
          '{"Status":0,"Answer":[{"type":15,"data":"10 mail.example.com."}]}',
          200,
        ),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<ImapSmtpDiscovery>());
      final imap = result as ImapSmtpDiscovery;
      expect(imap.imapHost, 'mail.example.com');
      expect(imap.imapPort, 993);
      expect(imap.imapSsl, isTrue);
      expect(imap.smtpHost, 'mail.example.com');
      expect(imap.smtpPort, 587);
      expect(imap.smtpSsl, isFalse);
    });

    test('MX fallback picks lowest priority record', () async {
      final svc = _service({
        'https://dns.google/resolve?name=example.com&type=MX': http.Response(
          '{"Status":0,"Answer":['
          '{"type":15,"data":"20 backup.example.com."},'
          '{"type":15,"data":"10 mail.example.com."}'
          ']}',
          200,
        ),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<ImapSmtpDiscovery>());
      expect((result as ImapSmtpDiscovery).imapHost, 'mail.example.com');
    });

    test('returns UnknownDiscovery when MX lookup also fails', () async {
      final svc = _service({
        'https://dns.google/resolve?name=example.com&type=MX': http.Response(
          '{"Status":3}',
          200,
        ),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<UnknownDiscovery>());
    });
  });
}
