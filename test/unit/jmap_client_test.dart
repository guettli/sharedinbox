import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/data/jmap/jmap_client.dart';

const _sessionUrl = 'https://jmap.example.com/.well-known/jmap';
const _apiUrl = 'https://jmap.example.com/api/';
const _accountId = 'u1';

Map<String, dynamic> _sessionBody({String? apiUrl, String? accountId}) => {
      'apiUrl': apiUrl ?? _apiUrl,
      'accounts': {
        accountId ?? _accountId: {
          'name': 'alice@example.com',
          'isPersonal': true,
          'isReadOnly': false,
          'accountCapabilities': {},
        },
      },
      'primaryAccounts': {
        'urn:ietf:params:jmap:core': accountId ?? _accountId,
        'urn:ietf:params:jmap:mail': accountId ?? _accountId,
      },
      'capabilities': {},
      'username': 'alice@example.com',
      'state': 'st1',
    };

http.Client _sessionClient({
  int sessionStatus = 200,
  Map<String, dynamic>? sessionBody,
  int apiStatus = 200,
  dynamic apiBody,
}) {
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode(sessionBody ?? _sessionBody()),
        sessionStatus,
      );
    }
    return http.Response(
      jsonEncode(apiBody ?? {'sessionState': 'st1', 'methodResponses': []}),
      apiStatus,
    );
  });
}

void main() {
  group('JmapClient.connect', () {
    test('parses apiUrl and accountId from session', () async {
      final client = await JmapClient.connect(
        httpClient: _sessionClient(),
        jmapUrl: Uri.parse(_sessionUrl),
        username: 'alice',
        password: 'secret',
      );
      expect(client.accountId, _accountId);
    });

    test('falls back to first account when primaryAccounts missing', () async {
      final body = _sessionBody()..remove('primaryAccounts');
      final client = await JmapClient.connect(
        httpClient: _sessionClient(sessionBody: body),
        jmapUrl: Uri.parse(_sessionUrl),
        username: 'alice',
        password: 'secret',
      );
      expect(client.accountId, _accountId);
    });

    test('throws JmapException on 401', () async {
      expect(
        () => JmapClient.connect(
          httpClient: _sessionClient(sessionStatus: 401),
          jmapUrl: Uri.parse(_sessionUrl),
          username: 'alice',
          password: 'wrong',
        ),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException on non-200 non-auth error', () async {
      expect(
        () => JmapClient.connect(
          httpClient: _sessionClient(sessionStatus: 503),
          jmapUrl: Uri.parse(_sessionUrl),
          username: 'alice',
          password: 'secret',
        ),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException when apiUrl is missing', () async {
      final body = _sessionBody()..remove('apiUrl');
      expect(
        () => JmapClient.connect(
          httpClient: _sessionClient(sessionBody: body),
          jmapUrl: Uri.parse(_sessionUrl),
          username: 'alice',
          password: 'secret',
        ),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException when no accounts exist', () async {
      final body = {
        'apiUrl': _apiUrl,
        'accounts': <String, dynamic>{},
        'primaryAccounts': <String, dynamic>{},
        'capabilities': {},
        'username': 'alice@example.com',
        'state': 'st1',
      };
      expect(
        () => JmapClient.connect(
          httpClient: _sessionClient(sessionBody: body),
          jmapUrl: Uri.parse(_sessionUrl),
          username: 'alice',
          password: 'secret',
        ),
        throwsA(isA<JmapException>()),
      );
    });
  });

  group('JmapClient.call', () {
    Future<JmapClient> connected({int apiStatus = 200, dynamic apiBody}) =>
        JmapClient.connect(
          httpClient: _sessionClient(apiStatus: apiStatus, apiBody: apiBody),
          jmapUrl: Uri.parse(_sessionUrl),
          username: 'alice',
          password: 'secret',
        );

    test('returns methodResponses on success', () async {
      final responses = [
        [
          'Mailbox/get',
          <String, dynamic>{'state': 'st2', 'list': []},
          '0',
        ],
      ];
      final client = await connected(
        apiBody: {'sessionState': 'st1', 'methodResponses': responses},
      );
      final result = await client.call([
        [
          'Mailbox/get',
          {'accountId': _accountId, 'ids': null},
          '0',
        ],
      ]);
      expect(result, hasLength(1));
      expect((result[0] as List<dynamic>)[0], 'Mailbox/get');
    });

    test('throws JmapException on non-200 API response', () async {
      final client = await connected(apiStatus: 500);
      expect(
        () => client.call([
          [
            'Mailbox/get',
            {'accountId': _accountId},
            '0',
          ],
        ]),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException on top-level JMAP error', () async {
      final client = await connected(
        apiBody: {'type': 'unknownCapability', 'description': 'oops'},
      );
      expect(
        () => client.call([
          [
            'Mailbox/get',
            {'accountId': _accountId},
            '0',
          ],
        ]),
        throwsA(isA<JmapException>()),
      );
    });
  });
}
