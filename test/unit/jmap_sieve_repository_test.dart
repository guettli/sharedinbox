import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';

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

http.Client _mockClient({required List<dynamic> methodResponses}) {
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(jsonEncode(_sessionBody()), 200);
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

SieveRepository _repo(List<dynamic> methodResponses) => SieveRepository(
      _FakeAccountRepository(_jmapAccount),
      _mockClient(methodResponses: methodResponses),
    );

void main() {
  group('SieveRepository.activateScript (JMAP)', () {
    test('throws JmapException when server reports notActivated', () async {
      final repo = _repo([
        [
          'SieveScript/activate',
          {
            'notActivated': {
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
          'SieveScript/activate',
          <String, dynamic>{},
          '0',
        ],
      ]);

      await repo.activateScript('acc-1', 's1');
    });
  });

  group('SieveRepository.deactivateScript (JMAP)', () {
    test('returns normally when the deactivate call succeeds', () async {
      final repo = _repo([
        [
          'SieveScript/activate',
          <String, dynamic>{},
          '0',
        ],
      ]);

      await repo.deactivateScript('acc-1');
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
