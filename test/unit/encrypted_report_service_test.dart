import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/core/services/encrypted_report_service.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:test/test.dart';

const _baseUrl = 'https://example.test/api/v1';

http.Client _clientFor(Map<String, http.Response> responses) {
  return MockClient((request) async {
    return responses[request.url.toString()] ?? http.Response('nope', 404);
  });
}

void main() {
  group('EncryptedReportService', () {
    test('submitUrl is derived from the base URL', () {
      final svc = EncryptedReportService(_clientFor({}), baseUrl: _baseUrl);
      expect(svc.submitUrl, '$_baseUrl/encrypted-reports');
    });

    test('fetchPublicKey parses keyId and publicKey', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      final body = jsonEncode({
        'keyId': base64.encode(m.keyId),
        'publicKey': base64.encode(m.publicKeyBytes),
        'alg': 'x25519-ecies-aesgcm',
      });
      final svc = EncryptedReportService(
        _clientFor({'$_baseUrl/report-key': http.Response(body, 200)}),
        baseUrl: _baseUrl,
      );

      final key = await svc.fetchPublicKey();
      expect(key.keyId, equals(m.keyId));
      expect(key.publicKeyBytes, equals(m.publicKeyBytes));
    });

    test('fetchPublicKey throws on a non-200 response', () async {
      final svc = EncryptedReportService(
        _clientFor({'$_baseUrl/report-key': http.Response('down', 503)}),
        baseUrl: _baseUrl,
      );
      expect(svc.fetchPublicKey, throwsA(isA<Exception>()));
    });

    test('fetchPublicKey rejects wrong key sizes', () async {
      final body = jsonEncode({
        'keyId': base64.encode(Uint8List(8)),
        'publicKey': base64.encode(Uint8List(16)),
      });
      final svc = EncryptedReportService(
        _clientFor({'$_baseUrl/report-key': http.Response(body, 200)}),
        baseUrl: _baseUrl,
      );
      expect(svc.fetchPublicKey, throwsA(isA<FormatException>()));
    });

    test('encryptMail produces bytes the maintainer key can decrypt', () async {
      final m = await ShareEncryptionService.generateKeyPair();
      final svc = EncryptedReportService(_clientFor({}), baseUrl: _baseUrl);
      final rawMail = utf8.encode('Subject: bug\r\n\r\nsomething broke');

      final cipher = await svc.encryptMail(
        ReportKey(keyId: m.keyId, publicKeyBytes: m.publicKeyBytes),
        rawMail,
      );

      final decrypted = await ShareEncryptionService.decryptBytes(
        data: cipher,
        privateKeyBytes: m.privateKeyBytes,
        publicKeyBytes: m.publicKeyBytes,
        keyId: m.keyId,
        info: EncryptedReportService.encryptionInfo,
      );
      expect(decrypted, equals(rawMail));
    });
  });
}
