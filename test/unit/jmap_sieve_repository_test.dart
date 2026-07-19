import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';

typedef _CapturedRequest = ({String method, Map<String, dynamic> args});

const _sessionUrl = 'https://jmap.example.com/.well-known/jmap';
const _apiUrl = 'https://jmap.example.com/api/';
const _accountId = 'u1';

const _jmapAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: _sessionUrl,
);

Map<String, dynamic> _sessionBody() => {
      'apiUrl': _apiUrl,
      'accounts': {
        _accountId: {
          'name': 'alice@example.com',
          'isPersonal': true,
          'isReadOnly': false,
          'accountCapabilities': {},
        },
      },
      'primaryAccounts': {
        'urn:ietf:params:jmap:core': _accountId,
        'urn:ietf:params:jmap:mail': _accountId,
        'urn:ietf:params:jmap:sieve': _accountId,
      },
      'capabilities': {
        'urn:ietf:params:jmap:sieve': <String, dynamic>{},
      },
      'username': 'alice@example.com',
      'state': 'st1',
    };

class _FakeAccountRepository implements AccountRepository {
  _FakeAccountRepository(this._account);

  final Account _account;

  @override
  Future<Account?> getAccount(String id) async =>
      id == _account.id ? _account : null;

  @override
  Future<String> getPassword(String accountId) async => 'pw';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

http.Client _mockClient({
  required List<dynamic> methodResponses,
  List<_CapturedRequest>? captured,
}) {
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(jsonEncode(_sessionBody()), 200);
    }
    if (captured != null) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final calls = body['methodCalls'] as List<dynamic>;
      for (final call in calls) {
        final triple = call as List<dynamic>;
        captured.add(
          (
            method: triple[0] as String,
            args: triple[1] as Map<String, dynamic>,
          ),
        );
      }
    }
    return http.Response(
      jsonEncode({
        'sessionState': 'st1',
        'methodResponses': methodResponses,
      }),
      200,
    );
  });
}

SieveRepository _repo(
  List<dynamic> methodResponses, {
  List<_CapturedRequest>? captured,
}) =>
    SieveRepository(
      _FakeAccountRepository(_jmapAccount),
      _mockClient(methodResponses: methodResponses, captured: captured),
    );

void main() {
  group('SieveRepository.activateScript (JMAP)', () {
    // Regression test for #321: Stalwart (and RFC 9661) has no
    // `SieveScript/activate` method — activation is a side-effect argument
    // on `SieveScript/set`. Sending the wrong method returns `unknownMethod`
    // and the UI surfaces it as a JmapException.
    test('uses SieveScript/set with onSuccessActivateScript', () async {
      final captured = <_CapturedRequest>[];
      final repo = _repo(
        [
          [
            'SieveScript/set',
            <String, dynamic>{},
            '0',
          ],
        ],
        captured: captured,
      );

      await repo.activateScript('acc-1', 's1');

      expect(captured, hasLength(1));
      expect(captured.first.method, 'SieveScript/set');
      expect(captured.first.args['onSuccessActivateScript'], 's1');
      expect(captured.first.args.containsKey('update'), isFalse);
    });

    test('throws JmapException when server reports notUpdated', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          {
            'notUpdated': {
              's1': {'type': 'invalidScript', 'description': 'bad'},
            },
          },
          '0',
        ],
      ]);

      await expectLater(
        repo.activateScript('acc-1', 's1'),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException when server reports notActivated', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          {
            'notActivated': {
              's1': {'type': 'notFound', 'description': 'gone'},
            },
          },
          '0',
        ],
      ]);

      await expectLater(
        repo.activateScript('acc-1', 's1'),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException on activationFailure envelope', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          {
            'activationFailure': {
              'type': 'invalidScript',
              'description': 'compile error',
            },
          },
          '0',
        ],
      ]);

      await expectLater(
        repo.activateScript('acc-1', 's1'),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException on method-level error response', () async {
      final repo = _repo([
        [
          'error',
          {'type': 'unknownMethod'},
          '0',
        ],
      ]);

      await expectLater(
        repo.activateScript('acc-1', 's1'),
        throwsA(isA<JmapException>()),
      );
    });

    test('returns normally when the activate call succeeds', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          <String, dynamic>{},
          '0',
        ],
      ]);

      await repo.activateScript('acc-1', 's1');
    });
  });

  group('SieveRepository.deactivateScript (JMAP)', () {
    test('uses SieveScript/set with onSuccessActivateScript: null', () async {
      final captured = <_CapturedRequest>[];
      final repo = _repo(
        [
          [
            'SieveScript/set',
            <String, dynamic>{},
            '0',
          ],
        ],
        captured: captured,
      );

      await repo.deactivateScript('acc-1');

      expect(captured, hasLength(1));
      expect(captured.first.method, 'SieveScript/set');
      expect(captured.first.args.containsKey('onSuccessActivateScript'), isTrue);
      expect(captured.first.args['onSuccessActivateScript'], isNull);
    });

    test('returns normally when the deactivate call succeeds', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          <String, dynamic>{},
          '0',
        ],
      ]);

      await repo.deactivateScript('acc-1');
    });

    test('throws JmapException on activationFailure envelope', () async {
      final repo = _repo([
        [
          'SieveScript/set',
          {
            'activationFailure': {
              'type': 'invalidArguments',
              'description': 'no active script',
            },
          },
          '0',
        ],
      ]);

      await expectLater(
        repo.deactivateScript('acc-1'),
        throwsA(isA<JmapException>()),
      );
    });

    test('throws JmapException on method-level error response', () async {
      final repo = _repo([
        [
          'error',
          {'type': 'unknownMethod'},
          '0',
        ],
      ]);

      await expectLater(
        repo.deactivateScript('acc-1'),
        throwsA(isA<JmapException>()),
      );
    });
  });
}
