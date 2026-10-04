import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
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

    // Connects a client that records the `using` array of the last API POST.
    Future<(JmapClient, List<dynamic> Function())> connectedCapturingUsing({
      Map<String, dynamic>? sessionBody,
    }) async {
      List<dynamic>? captured;
      final httpClient = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(jsonEncode(sessionBody ?? _sessionBody()), 200);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        captured = body['using'] as List<dynamic>;
        return http.Response(
          jsonEncode({'sessionState': 'st1', 'methodResponses': []}),
          200,
        );
      });
      final client = await JmapClient.connect(
        httpClient: httpClient,
        jmapUrl: Uri.parse(_sessionUrl),
        username: 'alice',
        password: 'secret',
      );
      return (client, () => captured ?? []);
    }

    test('declares the submission capability when withSubmission is set',
        () async {
      final (client, using) = await connectedCapturingUsing();
      await client.call(
        [
          [
            'Identity/get',
            {'accountId': _accountId, 'ids': null},
            'i',
          ],
        ],
        withSubmission: true,
      );
      expect(using(), contains('urn:ietf:params:jmap:submission'));
    });

    test('omits the submission capability by default', () async {
      final (client, using) = await connectedCapturingUsing();
      await client.call([
        [
          'Mailbox/get',
          {'accountId': _accountId, 'ids': null},
          '0',
        ],
      ]);
      expect(using(), isNot(contains('urn:ietf:params:jmap:submission')));
    });
  });

  // Regression coverage for issue #967: every API call was capped at a flat
  // 10 s, including `Email/get` requests that make the server read and
  // serialize full message bodies before it can answer. A routine catch-up
  // against a healthy server therefore timed out, and because the failure
  // surfaced as a TimeoutException the user was told the mail server was
  // unreachable.
  group('JmapClient request budget', () {
    Map<String, dynamic> emailGet({bool bodies = true}) => {
          'accountId': _accountId,
          'ids': ['e1'],
          if (bodies) 'fetchTextBodyValues': true,
          if (bodies) 'fetchHTMLBodyValues': true,
        };

    test('a metadata-only request gets the short budget', () {
      expect(
        JmapClient.defaultTimeoutFor([
          [
            'Email/changes',
            {'accountId': _accountId, 'sinceState': 's0', 'maxChanges': 200},
            '0',
          ],
        ]),
        JmapClient.metadataTimeout,
      );
    });

    test('a request the server must do real work for gets the long budget', () {
      expect(
        JmapClient.defaultTimeoutFor([
          ['Email/get', emailGet(), '0'],
        ]),
        JmapClient.slowRequestTimeout,
      );
      expect(
        JmapClient.slowRequestTimeout,
        greaterThan(JmapClient.metadataTimeout),
      );
    });

    test('one body fetch in a batch lifts the whole request', () {
      expect(
        JmapClient.defaultTimeoutFor([
          [
            'Email/query',
            {'accountId': _accountId, 'limit': 500},
            '0',
          ],
          ['Email/get', emailGet(), '1'],
        ]),
        JmapClient.slowRequestTimeout,
      );
    });

    test('fetchAllBodyValues also counts as a body fetch', () {
      expect(
        JmapClient.defaultTimeoutFor([
          [
            'Email/get',
            {
              'accountId': _accountId,
              'ids': ['e1'],
              'fetchAllBodyValues': true,
            },
            '0',
          ],
        ]),
        JmapClient.slowRequestTimeout,
      );
    });

    test('an Email/get without body options stays on the short budget', () {
      expect(
        JmapClient.defaultTimeoutFor([
          ['Email/get', emailGet(bodies: false), '0'],
        ]),
        JmapClient.metadataTimeout,
      );
    });

    test('a malformed method call does not throw', () {
      expect(
        JmapClient.defaultTimeoutFor([
          ['Email/get'],
          ['Email/get', 'not-a-map', '0'],
        ]),
        JmapClient.metadataTimeout,
      );
    });

    test('Email/query with calculateTotal gets the long budget', () {
      expect(
        JmapClient.defaultTimeoutFor([
          [
            'Email/query',
            {
              'accountId': _accountId,
              'filter': {'inMailbox': 'a'},
              'limit': 500,
              'calculateTotal': true,
            },
            '0',
          ],
        ]),
        JmapClient.slowRequestTimeout,
        reason: 'a server-side count of the whole mailbox is not a cheap '
            'metadata lookup',
      );
    });

    // Pins the wiring, not just the derivation: reverting `call` to one flat
    // budget would leave every assertion above green.
    test('call applies the derived budget to the request', () {
      fakeAsync((async) {
        // A server that always takes 30s — longer than the metadata budget,
        // shorter than the slow-request budget.
        final httpClient = MockClient((req) async {
          if (req.url.path.contains('well-known')) {
            return http.Response(jsonEncode(_sessionBody()), 200);
          }
          await Future<void>.delayed(const Duration(seconds: 30));
          return http.Response(
            jsonEncode({'sessionState': 'st1', 'methodResponses': <dynamic>[]}),
            200,
          );
        });

        JmapClient? client;
        unawaited(
          JmapClient.connect(
            httpClient: httpClient,
            jmapUrl: Uri.parse(_sessionUrl),
            username: 'alice',
            password: 'secret',
          ).then((c) => client = c),
        );
        async.elapse(const Duration(milliseconds: 1));
        expect(client, isNotNull, reason: 'the session fetch is immediate');

        Object? metadataError;
        unawaited(
          client!.call([
            [
              'Email/changes',
              {'accountId': _accountId, 'sinceState': 's0'},
              '0',
            ],
          ]).then<void>(
            (_) {},
            onError: (Object e) {
              metadataError = e;
            },
          ),
        );

        Object? bodyError;
        var bodyDone = false;
        unawaited(
          client!.call([
            ['Email/get', emailGet(), '0'],
          ]).then<void>(
            (_) {
              bodyDone = true;
            },
            onError: (Object e) {
              bodyError = e;
            },
          ),
        );

        // Past the metadata budget: the metadata call has given up, the body
        // fetch has not.
        async.elapse(JmapClient.metadataTimeout + const Duration(seconds: 1));
        expect(metadataError, isA<TimeoutException>());
        expect(bodyError, isNull);
        expect(bodyDone, isFalse);

        // The server answers at 30s, inside the slow-request budget.
        async.elapse(const Duration(seconds: 30));
        expect(bodyError, isNull);
        expect(
          bodyDone,
          isTrue,
          reason: 'a body fetch must survive past the metadata budget',
        );
      });
    });

    test('an explicit timeout overrides the derived one', () async {
      final httpClient = MockClient((req) async {
        if (req.url.path.contains('well-known')) {
          return http.Response(jsonEncode(_sessionBody()), 200);
        }
        // Slower than the explicit budget, faster than the derived one.
        await Future<void>.delayed(const Duration(seconds: 2));
        return http.Response('{}', 200);
      });
      final client = await JmapClient.connect(
        httpClient: httpClient,
        jmapUrl: Uri.parse(_sessionUrl),
        username: 'alice',
        password: 'secret',
      );
      await expectLater(
        client.call(
          [
            ['Email/get', emailGet(), '0'],
          ],
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
