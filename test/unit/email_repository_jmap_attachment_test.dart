// Offline regression coverage for JMAP attachment downloads (issue #762).
//
// Users hit "Cannot download <file>: missing part ID. Open the email again to
// refresh." when trying to save an attachment from a JMAP account. The body
// fetch in `_getEmailBodyJmap` asked for `attachments` with an explicit
// `bodyProperties` list that left out `blobId`. A spec-compliant JMAP server
// (RFC 8621 §4.1.4) returns *only* the requested body properties, so every
// attachment came back without a `blobId`; `_parseJmapBody` then stored an
// empty `fetchPartId`, and `downloadAttachment` refused to fetch a blob it had
// no id for.
//
// This drives the exact user flow — open the email, then download the
// attachment — against a fake JMAP server that honours `bodyProperties` the way
// a real server does. Before the fix it fails with the StateError from the bug
// report; after it, the blob downloads.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import 'account_repository_impl_test.dart' show MapSecureStorage;
import 'db_test_helper.dart';

const _accountId = 'acct1';
const _pdfBytes = <int>[0x25, 0x50, 0x44, 0x46]; // "%PDF"

const _jmapAccount = Account(
  id: 'jmap-att',
  displayName: 'Alice',
  email: 'alice@example.com',
  type: AccountType.jmap,
  jmapUrl: 'https://jmap.example.com/.well-known/jmap',
);

/// Fake JMAP server that returns one email with a single PDF attachment.
///
/// Crucially it honours the request's `bodyProperties`: each EmailBodyPart in
/// `attachments` contains *only* the properties the client asked for, mirroring
/// a spec-compliant server (RFC 8621 §4.1.4). A body fetch that forgets to
/// request `blobId` therefore gets an attachment with no id to download.
http.Client _jmapServer() {
  return MockClient((req) async {
    // Session object.
    if (req.url.path.contains('well-known')) {
      return http.Response(
        jsonEncode({
          'apiUrl': 'https://jmap.example.com/api/',
          'downloadUrl': 'https://jmap.example.com/download/'
              '{accountId}/{blobId}/{name}?type={type}',
          'uploadUrl': 'https://jmap.example.com/upload/{accountId}',
          'accounts': {
            _accountId: {'name': 'alice@example.com', 'isPersonal': true},
          },
          'primaryAccounts': {
            'urn:ietf:params:jmap:core': _accountId,
            'urn:ietf:params:jmap:mail': _accountId,
          },
          'capabilities': {
            'urn:ietf:params:jmap:core': <String, dynamic>{},
            'urn:ietf:params:jmap:mail': <String, dynamic>{},
          },
          'username': 'alice@example.com',
          'state': 'sess1',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }

    // Blob download.
    if (req.method == 'GET' && req.url.path.contains('/download/')) {
      return http.Response.bytes(_pdfBytes, 200);
    }

    // API request (Email/get).
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final methodCalls = (body['methodCalls'] as List<dynamic>).cast<List>();
    final methodResponses = <List<dynamic>>[];

    for (final call in methodCalls) {
      final method = call[0] as String;
      final args = call[1] as Map<String, dynamic>;
      final callId = call[2];

      if (method != 'Email/get') {
        methodResponses.add([
          'error',
          {'type': 'unknownMethod'},
          callId
        ]);
        continue;
      }

      // Return only the body properties the client requested — a real server
      // never volunteers `blobId` unless it is asked for.
      final bodyProperties =
          ((args['bodyProperties'] as List<dynamic>?) ?? const [])
              .cast<String>();
      const fullAttachment = {
        'partId': '2',
        'blobId': 'blob-pdf-1',
        'type': 'application/pdf',
        'name': '3031055133.pdf',
        'size': 4,
        'disposition': 'attachment',
      };
      final attachment = <String, dynamic>{
        for (final prop in bodyProperties)
          if (fullAttachment.containsKey(prop)) prop: fullAttachment[prop],
      };

      methodResponses.add([
        'Email/get',
        {
          'accountId': _accountId,
          'state': 'st1',
          'list': [
            {
              'id': 'email-1',
              'headers': <dynamic>[],
              'textBody': [
                {'partId': '1', 'type': 'text/plain'},
              ],
              'htmlBody': <dynamic>[],
              'bodyValues': {
                '1': {'value': 'see attached'},
              },
              'attachments': [attachment],
              'bodyStructure': <String, dynamic>{},
            },
          ],
          'notFound': <String>[],
        },
        callId,
      ]);
    }

    return http.Response(
      jsonEncode({'sessionState': 'sess1', 'methodResponses': methodResponses}),
      200,
    );
  });
}

void main() {
  setUpAll(configureSqliteForTests);

  late Directory cacheDir;
  setUp(() => cacheDir = Directory.systemTemp.createTempSync('jmap_att_test_'));
  tearDown(() => cacheDir.deleteSync(recursive: true));

  ({AppDatabase db, AccountRepositoryImpl accounts, EmailRepositoryImpl emails})
      makeRepo(http.Client client) {
    final db = openTestDatabase();
    final accounts = AccountRepositoryImpl(db, MapSecureStorage());
    final emails = EmailRepositoryImpl(
      db,
      accounts,
      getCacheDir: () async => cacheDir,
      httpClient: client,
    );
    return (db: db, accounts: accounts, emails: emails);
  }

  test('JMAP attachments can be downloaded after opening the email', () async {
    final r = makeRepo(_jmapServer());
    await r.accounts.addAccount(_jmapAccount, 'pw');

    const emailId = 'jmap-att:email-1';
    await r.db.into(r.db.emails).insert(
          EmailsCompanion.insert(
            id: emailId,
            accountId: _jmapAccount.id,
            mailboxPath: 'INBOX',
            uid: 1,
            receivedAt: DateTime.now(),
          ),
        );

    // Open the email — this is the fetch that must carry `blobId` through.
    final body = await r.emails.getEmailBody(emailId, forceRefresh: true);
    expect(body.attachments, hasLength(1));
    final attachment = body.attachments.single;
    expect(
      attachment.fetchPartId,
      isNotEmpty,
      reason: 'attachment must keep its JMAP blobId so it can be downloaded',
    );

    // Download it — before the fix this threw the StateError from the bug
    // report: "Cannot download 3031055133.pdf: missing part ID".
    final path = await r.emails.downloadAttachment(emailId, attachment);
    expect(
        await File(path).readAsBytes(), equals(Uint8List.fromList(_pdfBytes)));
  });
}
