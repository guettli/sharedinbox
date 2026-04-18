import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:sharedinbox/core/models/discovery_result.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';

const _jmapJson = '{"apiUrl":"https://mail.example.com/jmap/api/"}';

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
    return responses[key] ??
        http.Response('Not found', 404);
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

    test('returns JmapDiscovery when well-known/jmap responds with apiUrl',
        () async {
      final svc = _service({
        'https://example.com/.well-known/jmap':
            http.Response(_jmapJson, 200),
      });
      final result = await svc.discover('user@example.com');
      expect(result, isA<JmapDiscovery>());
      expect((result as JmapDiscovery).apiUrl,
          'https://mail.example.com/jmap/api/');
    });

    test('returns UnknownDiscovery when JMAP response has no apiUrl', () async {
      final svc = _service({
        'https://example.com/.well-known/jmap': http.Response('{}', 200),
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
        'https://example.com/.well-known/jmap':
            http.Response(_jmapJson, 200),
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
  });
}
