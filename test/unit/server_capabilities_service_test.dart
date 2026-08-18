import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/services/server_capabilities_service.dart';

import 'fake_imap.dart';

const _imapAccount = Account(
  id: 'cap-imap',
  displayName: 'Cap Tester',
  email: 'cap@sample.test',
  imapHost: 'mail.sample.test',
  smtpHost: 'submission.sample.test',
);

const _jmapAccount = Account(
  id: 'cap-jmap',
  displayName: 'Cap Tester',
  email: 'cap@sample.test',
  type: AccountType.jmap,
  jmapUrl: 'https://sample.test/.well-known/jmap',
);

const _jmapSessionJson = '{'
    '"capabilities":{"urn:ietf:params:jmap:core":{},'
    '"urn:ietf:params:jmap:mail":{},"urn:ietf:params:jmap:submission":{}},'
    '"accounts":{"a0":{}},"primaryAccounts":{"urn:ietf:params:jmap:mail":"a0"},'
    '"username":"cap@sample.test","apiUrl":"https://sample.test/jmap/api",'
    '"downloadUrl":"","uploadUrl":"","state":"0"'
    '}';

/// Fake IMAP client whose `CAPABILITY` returns [tokens] and which records
/// whether it was logged out.
class _CapabilityImapClient extends FakeImapClient {
  _CapabilityImapClient(this.tokens);

  final List<String> tokens;
  bool loggedOut = false;

  @override
  Future<List<imap.Capability>> capability() async =>
      tokens.map(imap.Capability.new).toList();

  @override
  Future<dynamic> logout() async {
    loggedOut = true;
  }
}

void main() {
  group('ServerCapabilitiesServiceImpl IMAP', () {
    test('returns the sorted, de-duplicated CAPABILITY tokens', () async {
      final fake = _CapabilityImapClient(['MOVE', 'IDLE', 'IDLE', 'UIDPLUS']);
      final svc = ServerCapabilitiesServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => fake,
      );

      final caps = await svc.fetch(_imapAccount, 'pw');

      expect(caps.type, AccountType.imap);
      expect(caps.capabilities, ['IDLE', 'MOVE', 'UIDPLUS']);
      expect(fake.loggedOut, isTrue);
    });

    test('logs out even when reading capabilities throws', () async {
      final fake = _ThrowingCapabilityImapClient();
      final svc = ServerCapabilitiesServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => fake,
      );

      await expectLater(
        svc.fetch(_imapAccount, 'pw'),
        throwsA(isA<Exception>()),
      );
      expect(fake.loggedOut, isTrue);
    });

    test('propagates a connection failure', () async {
      final svc = ServerCapabilitiesServiceImpl(
        MockClient((_) async => http.Response('', 200)),
        imapConnect: (_, __, ___) async => throw Exception('auth failed'),
      );

      expect(() => svc.fetch(_imapAccount, 'pw'), throwsException);
    });
  });

  group('ServerCapabilitiesServiceImpl JMAP', () {
    test('returns the sorted Session capability URNs', () async {
      final svc = ServerCapabilitiesServiceImpl(
        MockClient((_) async => http.Response(_jmapSessionJson, 200)),
      );

      final caps = await svc.fetch(_jmapAccount, 'pw');

      expect(caps.type, AccountType.jmap);
      expect(caps.capabilities, [
        'urn:ietf:params:jmap:core',
        'urn:ietf:params:jmap:mail',
        'urn:ietf:params:jmap:submission',
      ]);
    });

    test('throws when no JMAP URL is configured', () async {
      const noUrl = Account(
        id: 'acc-3',
        displayName: 'Alice',
        email: 'alice@example.com',
        type: AccountType.jmap,
      );
      final svc = ServerCapabilitiesServiceImpl(
        MockClient((_) async => http.Response('', 200)),
      );

      expect(() => svc.fetch(noUrl, 'pw'), throwsException);
    });
  });

  group('capabilityDescription', () {
    test('describes well-known IMAP tokens', () {
      expect(capabilityDescription('IDLE'), isNotNull);
      expect(capabilityDescription('urn:ietf:params:jmap:core'), isNotNull);
    });

    test('handles AUTH= mechanisms by prefix', () {
      expect(capabilityDescription('AUTH=PLAIN'), contains('PLAIN'));
    });

    test('returns null for unknown tokens', () {
      expect(capabilityDescription('X-CUSTOM-THING'), isNull);
    });
  });
}

class _ThrowingCapabilityImapClient extends FakeImapClient {
  bool loggedOut = false;

  @override
  Future<List<imap.Capability>> capability() async => throw Exception('boom');

  @override
  Future<dynamic> logout() async {
    loggedOut = true;
  }
}
