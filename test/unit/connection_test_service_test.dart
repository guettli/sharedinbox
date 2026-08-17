import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/connection_test_service.dart';

import 'fake_imap.dart';

const _imapAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const _jmapAccount = Account(
  id: 'acc-2',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://example.com/jmap/session',
);

const _jmapSessionJson = '{'
    '"capabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{}},'
    '"accounts":{},"primaryAccounts":{},"username":"alice@example.com",'
    '"apiUrl":"https://example.com/jmap/","downloadUrl":"","uploadUrl":"","state":"0"'
    '}';

// Session that advertises the submission capability plus a primary mail
// account, so the identity probe runs.
const _jmapSubmissionSessionJson = '{'
    '"capabilities":{"urn:ietf:params:jmap:core":{},'
    '"urn:ietf:params:jmap:mail":{},"urn:ietf:params:jmap:submission":{}},'
    '"accounts":{"acc":{}},"primaryAccounts":{"urn:ietf:params:jmap:mail":"acc"},'
    '"username":"alice@example.com","apiUrl":"https://example.com/jmap/",'
    '"downloadUrl":"","uploadUrl":"","state":"0"'
    '}';

String _identityResponse(List<String> emails) {
  final list = emails.map((e) => '{"id":"i-$e","email":"$e"}').join(',');
  return '{"methodResponses":[["Identity/get",{"list":[$list]},"0"]]}';
}

/// Builds a service whose HTTP client returns the session on GET and the given
/// [identityBody] on the POST that fetches identities.
ConnectionTestServiceImpl _makeJmapIdentityService({
  required String sessionJson,
  String? identityBody,
  int identityStatus = 200,
}) {
  final mockHttp = MockClient((request) async {
    if (request.method == 'POST') {
      return http.Response(identityBody ?? '', identityStatus);
    }
    return http.Response(sessionJson, 200);
  });
  return ConnectionTestServiceImpl(mockHttp);
}

ConnectionTestServiceImpl _makeService({
  required int httpStatus,
  FakeImapClient? fakeImap,
  Exception? imapError,
}) {
  final mockHttp = MockClient(
    (_) async =>
        http.Response(httpStatus == 200 ? _jmapSessionJson : '', httpStatus),
  );
  return ConnectionTestServiceImpl(
    mockHttp,
    imapConnect: (account, username, password) async {
      if (imapError != null) throw imapError;
      return fakeImap ?? FakeImapClient();
    },
    smtpConnect: (account, username, password) async => FakeSmtpClient(),
  );
}

void main() {
  group('ConnectionTestServiceImpl IMAP', () {
    test('returns username when explicit username succeeds', () async {
      const account = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        username: 'myuser',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
      );
      final svc = _makeService(httpStatus: 200);
      final result = await svc.testConnection(account, 'pw');
      expect(result.username, 'myuser');
    });

    test('returns email when no username and email succeeds', () async {
      final svc = _makeService(httpStatus: 200);
      final result = await svc.testConnection(_imapAccount, 'pw');
      expect(result.username, 'alice@example.com');
    });

    test('falls back to localPart when email login fails', () async {
      var callCount = 0;
      final mockHttp = MockClient((_) async => http.Response('', 200));
      final svc = ConnectionTestServiceImpl(
        mockHttp,
        imapConnect: (account, username, password) async {
          callCount++;
          if (username == 'alice@example.com') {
            throw Exception('auth failed');
          }
          return FakeImapClient();
        },
        smtpConnect: (_, __, ___) async => FakeSmtpClient(),
      );
      final result = await svc.testConnection(_imapAccount, 'pw');
      expect(result.username, 'alice');
      expect(callCount, 2);
    });

    test('throws when all IMAP candidates fail', () async {
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => throw Exception('auth failed'),
        smtpConnect: (_, __, ___) async => FakeSmtpClient(),
      );
      expect(() => svc.testConnection(_imapAccount, 'pw'), throwsException);
    });

    test('reports SMTP failure after IMAP success', () async {
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => FakeImapClient(),
        smtpConnect: (_, __, ___) async => throw Exception('smtp boom'),
      );
      expect(
        () => svc.testConnection(_imapAccount, 'pw'),
        throwsA(predicate((e) => e.toString().contains('SMTP: '))),
      );
    });

    test('skips ManageSieve when manageSieveHost is empty', () async {
      var sieveCalled = false;
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => FakeImapClient(),
        smtpConnect: (_, __, ___) async => FakeSmtpClient(),
        manageSieveConnect: ({
          required String host,
          required int port,
          required bool useTls,
        }) async {
          sieveCalled = true;
          throw Exception('should not be called');
        },
      );
      await svc.testConnection(_imapAccount, 'pw');
      expect(sieveCalled, false);
    });

    test('reports ManageSieve failure when host is set', () async {
      const accountWithSieve = Account(
        id: 'acc-1',
        displayName: 'Alice',
        email: 'alice@example.com',
        imapHost: 'imap.example.com',
        smtpHost: 'smtp.example.com',
        manageSieveHost: 'sieve.example.com',
      );
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => FakeImapClient(),
        smtpConnect: (_, __, ___) async => FakeSmtpClient(),
        manageSieveConnect: ({
          required String host,
          required int port,
          required bool useTls,
        }) async =>
            throw Exception('sieve boom'),
      );
      expect(
        () => svc.testConnection(accountWithSieve, 'pw'),
        throwsA(predicate((e) => e.toString().contains('ManageSieve: '))),
      );
    });
  });

  group('ConnectionTestServiceImpl JMAP', () {
    test('returns email username on HTTP 200', () async {
      final svc = _makeService(httpStatus: 200);
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.username, 'alice@example.com');
    });

    test('throws on 401 authentication failed', () async {
      final svc = _makeService(httpStatus: 401);
      expect(
        () => svc.testConnection(_jmapAccount, 'pw'),
        throwsA(
          predicate((e) => e.toString().contains('Authentication failed')),
        ),
      );
    });

    test('throws on 403 authentication failed', () async {
      final svc = _makeService(httpStatus: 403);
      expect(
        () => svc.testConnection(_jmapAccount, 'pw'),
        throwsA(
          predicate((e) => e.toString().contains('Authentication failed')),
        ),
      );
    });

    test('throws on non-200/401/403 status', () async {
      final svc = _makeService(httpStatus: 500);
      expect(
        () => svc.testConnection(_jmapAccount, 'pw'),
        throwsA(predicate((e) => e.toString().contains('Connection failed'))),
      );
    });

    test('falls back to localPart on 401 then succeeds', () async {
      var callCount = 0;
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async {
          callCount++;
          return http.Response(
            callCount == 1 ? '' : _jmapSessionJson,
            callCount == 1 ? 401 : 200,
          );
        }),
      );
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.username, 'alice');
      expect(callCount, 2);
    });

    test('throws when response is not JSON', () async {
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async => http.Response('<html>admin</html>', 200)),
      );
      expect(
        () => svc.testConnection(_jmapAccount, 'pw'),
        throwsA(predicate((e) => e.toString().contains('Not a JMAP server'))),
      );
    });

    test('throws when response lacks JMAP core capability', () async {
      final svc = ConnectionTestServiceImpl(
        MockClient(
          (_) async =>
              http.Response('{"capabilities":{"something:else":{}}}', 200),
        ),
      );
      expect(
        () => svc.testConnection(_jmapAccount, 'pw'),
        throwsA(predicate((e) => e.toString().contains('Not a JMAP server'))),
      );
    });

    test('_usernamesFor returns explicit username only when set', () async {
      const account = Account(
        id: 'a',
        displayName: 'A',
        email: 'a@b.com',
        username: 'mylogin',
        type: AccountType.jmap,
        jmapUrl: 'https://b.com/jmap/session',
      );
      var requestCount = 0;
      final svc = ConnectionTestServiceImpl(
        MockClient((_) async {
          requestCount++;
          return http.Response(_jmapSessionJson, 200);
        }),
      );
      final result = await svc.testConnection(account, 'pw');
      expect(result.username, 'mylogin');
      expect(requestCount, 1);
    });
  });

  group('ConnectionTestServiceImpl JMAP identity', () {
    test('no warning when an identity matches the account email', () async {
      final svc = _makeJmapIdentityService(
        sessionJson: _jmapSubmissionSessionJson,
        identityBody: _identityResponse(['other@example.com', 'alice@example.com']),
      );
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.username, 'alice@example.com');
      expect(result.identityWarning, isNull);
    });

    test('warns when no identity matches the account address', () async {
      final svc = _makeJmapIdentityService(
        sessionJson: _jmapSubmissionSessionJson,
        identityBody: _identityResponse(['bob@example.com', 'carol@example.com']),
      );
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.identityWarning, isNotNull);
      expect(result.identityWarning, contains('alice@example.com'));
      expect(result.identityWarning, contains('bob@example.com'));
      expect(result.identityWarning, contains('carol@example.com'));
    });

    test('match is case-insensitive', () async {
      const mixedCaseAccount = Account(
        id: 'acc-2',
        displayName: 'Alice',
        email: 'Alice@Example.com',
        type: AccountType.jmap,
        jmapUrl: 'https://example.com/jmap/session',
      );
      final svc = _makeJmapIdentityService(
        sessionJson: _jmapSubmissionSessionJson,
        identityBody: _identityResponse(['alice@example.com']),
      );
      final result = await svc.testConnection(mixedCaseAccount, 'pw');
      expect(result.identityWarning, isNull);
    });

    test('matches against the configured username too', () async {
      const usernameAccount = Account(
        id: 'acc-2',
        displayName: 'Alice',
        email: 'alias@example.com',
        username: 'alice@example.com',
        type: AccountType.jmap,
        jmapUrl: 'https://example.com/jmap/session',
      );
      final svc = _makeJmapIdentityService(
        sessionJson: _jmapSubmissionSessionJson,
        identityBody: _identityResponse(['alice@example.com']),
      );
      final result = await svc.testConnection(usernameAccount, 'pw');
      expect(result.identityWarning, isNull);
    });

    test('warns when the server lacks the submission capability', () async {
      // _jmapSessionJson has core+mail but no submission capability.
      final svc = _makeJmapIdentityService(sessionJson: _jmapSessionJson);
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.identityWarning, isNotNull);
      expect(result.identityWarning, contains('does not support sending'));
    });

    test('no warning when the Identity/get probe fails', () async {
      final svc = _makeJmapIdentityService(
        sessionJson: _jmapSubmissionSessionJson,
        identityStatus: 500,
      );
      final result = await svc.testConnection(_jmapAccount, 'pw');
      expect(result.identityWarning, isNull);
    });
  });
}
