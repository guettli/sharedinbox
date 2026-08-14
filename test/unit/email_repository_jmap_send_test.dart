// Offline regression coverage for the JMAP send path (issue #537).
//
// Issue #535 shipped because the only send coverage ran against a *lenient*
// Stalwart server that answers method calls even when the request's `using`
// array fails to declare the capability the method belongs to. The missing
// `urn:ietf:params:jmap:submission` on the `Identity/get` call therefore went
// unnoticed until a spec-strict server rejected it with `unknownMethod`.
//
// This test drives `sendEmail` through a *strict* fake JMAP server that
// enforces RFC 8621's rule: a method call whose capability is not declared in
// `using` is answered with an `unknownMethod` error triple — exactly what the
// strict server did in #535. Any future send-path call that forgets to declare
// the submission capability now fails here, offline and without Stalwart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

const _submissionCapability = 'urn:ietf:params:jmap:submission';
const _accountId = 'acct1';

const _jmapAccount = Account(
  id: 'jmap-send',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// A method belongs to the submission capability (RFC 8621 §6/§7) and so must
/// be covered by `urn:ietf:params:jmap:submission` in the request's `using`.
bool _requiresSubmission(String method) =>
    method.startsWith('Identity/') || method.startsWith('EmailSubmission/');

/// Builds a strict fake JMAP server that records every API request body and
/// enforces the `using` ↔ capability contract. Returns the mock client and a
/// getter for the captured request bodies (decoded), in call order.
({http.Client client, List<Map<String, dynamic>> Function() requests})
_strictJmapServer() {
  final requests = <Map<String, dynamic>>[];

  final client = MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'accounts': {
            _accountId: {'name': 'alice@example.com', 'isPersonal': true},
          },
          'primaryAccounts': {
            'urn:ietf:params:jmap:core': _accountId,
            'urn:ietf:params:jmap:mail': _accountId,
            _submissionCapability: _accountId,
          },
          // Advertise submission so the client does not fail fast; the point of
          // the test is the per-request `using` declaration, not the session.
          'capabilities': {
            'urn:ietf:params:jmap:core': <String, dynamic>{},
            'urn:ietf:params:jmap:mail': <String, dynamic>{},
            _submissionCapability: <String, dynamic>{},
          },
          'username': 'alice@example.com',
          'state': 'sess1',
        }),
        200,
      );
    }

    final body = jsonDecode(req.body) as Map<String, dynamic>;
    requests.add(body);
    final using = ((body['using'] as List<dynamic>?) ?? const [])
        .cast<String>()
        .toSet();
    final methodCalls = (body['methodCalls'] as List<dynamic>).cast<List>();

    final methodResponses = <List<dynamic>>[];
    for (final call in methodCalls) {
      final method = call[0] as String;
      final args = call[1] as Map<String, dynamic>;
      final callId = call[2];

      // Strict-server behaviour: reject a method whose capability the request
      // never declared. This is the failure #535 tripped on.
      if (_requiresSubmission(method) &&
          !using.contains(_submissionCapability)) {
        methodResponses.add([
          'error',
          {'type': 'unknownMethod'},
          callId,
        ]);
        continue;
      }

      switch (method) {
        case 'Identity/get':
          methodResponses.add([
            'Identity/get',
            {
              'accountId': _accountId,
              'state': 'id1',
              'list': [
                {
                  'id': 'identity-1',
                  'name': 'Alice',
                  'email': 'alice@example.com',
                },
              ],
              'notFound': <String>[],
            },
            callId,
          ]);
        case 'Email/set':
          if (args.containsKey('destroy')) {
            methodResponses.add([
              'Email/set',
              {'accountId': _accountId, 'destroyed': args['destroy']},
              callId,
            ]);
          } else {
            methodResponses.add([
              'Email/set',
              {
                'accountId': _accountId,
                'created': {
                  'em1': {
                    'id': 'email-1',
                    'blobId': 'blob-1',
                    'threadId': 'thread-1',
                    'size': 1,
                  },
                },
              },
              callId,
            ]);
          }
        case 'EmailSubmission/set':
          methodResponses.add([
            'EmailSubmission/set',
            {
              'accountId': _accountId,
              'created': {
                'sub1': {'id': 'submission-1'},
              },
            },
            callId,
          ]);
        default:
          methodResponses.add([
            'error',
            {'type': 'unknownMethod'},
            callId,
          ]);
      }
    }

    return http.Response(
      jsonEncode({'sessionState': 'sess1', 'methodResponses': methodResponses}),
      200,
    );
  });

  return (client: client, requests: () => requests);
}

EmailDraft _draft() => const EmailDraft(
  from: EmailAddress(name: 'Alice', email: 'alice@example.com'),
  to: [EmailAddress(name: 'Bob', email: 'bob@example.com')],
  cc: [],
  subject: 'strict-server test',
  body: 'hello from the offline regression test',
);

void main() {
  setUpAll(configureSqliteForTests);

  ({AccountRepositoryImpl accounts, EmailRepositoryImpl emails}) makeRepo(
    http.Client httpClient,
  ) {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final emails = EmailRepositoryImpl(db, accounts, httpClient: httpClient);
    return (accounts: accounts, emails: emails);
  }

  test('sendEmail declares the submission capability on Identity/get', () async {
    final server = _strictJmapServer();
    final r = makeRepo(server.client);
    await r.accounts.addAccount(_jmapAccount, 'pw');

    // Against a strict server this only completes if every submission method —
    // Identity/get included — declared the capability. A regression that drops
    // `withSubmission: true` surfaces here as the exact #535 failure:
    // "JmapException: Identity/get error: unknownMethod".
    await r.emails.sendEmail(_jmapAccount.id, _draft());

    // Belt and suspenders: assert the request shape directly, so the guard
    // reads clearly even if the strict-server logic is later relaxed.
    final identityRequests = server
        .requests()
        .where(
          (body) => (body['methodCalls'] as List<dynamic>).cast<List>().any(
            (call) => call[0] == 'Identity/get',
          ),
        )
        .toList();
    expect(
      identityRequests,
      isNotEmpty,
      reason: 'send path must issue Identity/get',
    );
    for (final body in identityRequests) {
      expect(
        (body['using'] as List<dynamic>).cast<String>(),
        contains(_submissionCapability),
        reason: 'Identity/get must declare the submission capability',
      );
    }
  });

  test(
    'sendEmail declares the submission capability on EmailSubmission/set',
    () async {
      final server = _strictJmapServer();
      final r = makeRepo(server.client);
      await r.accounts.addAccount(_jmapAccount, 'pw');

      await r.emails.sendEmail(_jmapAccount.id, _draft());

      final submissionRequests = server
          .requests()
          .where(
            (body) => (body['methodCalls'] as List<dynamic>).cast<List>().any(
              (call) => call[0] == 'EmailSubmission/set',
            ),
          )
          .toList();
      expect(
        submissionRequests,
        isNotEmpty,
        reason: 'send path must issue EmailSubmission/set',
      );
      for (final body in submissionRequests) {
        expect(
          (body['using'] as List<dynamic>).cast<String>(),
          contains(_submissionCapability),
          reason: 'EmailSubmission/set must declare the submission capability',
        );
      }
    },
  );

  test('strict server rejects an under-declared submission call (guards the '
      'guard)', () async {
    // Proves the harness would actually catch #535: issuing Identity/get
    // without declaring the submission capability comes back as unknownMethod,
    // just as the strict Stalwart server did in the original bug report.
    final server = _strictJmapServer();
    final client = await JmapClient.connect(
      httpClient: server.client,
      jmapUrl: Uri.parse(_jmapAccount.jmapUrl!),
      username: 'alice@example.com',
      password: 'pw',
    );

    final responses = await client.call([
      [
        'Identity/get',
        {'accountId': client.accountId, 'ids': null},
        'i',
      ],
    ]);

    final triple = responses.single as List<dynamic>;
    expect(triple[0], 'error');
    expect((triple[1] as Map<String, dynamic>)['type'], 'unknownMethod');
  });
}
