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

const _jmapSessionJson =
    '{'
    '"capabilities":{"urn:ietf:params:jmap:core":{},"urn:ietf:params:jmap:mail":{}},'
    '"accounts":{},"primaryAccounts":{},"username":"alice@example.com",'
    '"apiUrl":"https://example.com/jmap/","downloadUrl":"","uploadUrl":"","state":"0"'
    '}';

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
      expect(result, 'myuser');
    });

    test('returns email when no username and email succeeds', () async {
      final svc = _makeService(httpStatus: 200);
      final result = await svc.testConnection(_imapAccount, 'pw');
      expect(result, 'alice@example.com');
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
      expect(result, 'alice');
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
        manageSieveConnect:
            ({
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
        manageSieveConnect:
            ({
              required String host,
              required int port,
              required bool useTls,
            }) async => throw Exception('sieve boom'),
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
      expect(result, 'alice@example.com');
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
      expect(result, 'alice');
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
      expect(result, 'mylogin');
      expect(requestCount, 1);
    });
  });
}
