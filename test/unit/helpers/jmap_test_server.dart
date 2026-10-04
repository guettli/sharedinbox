import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import '../account_repository_impl_test.dart' show MapSecureStorage;
import '../db_test_helper.dart';

/// Scaffolding every fake-JMAP-server suite needs: the Session object the
/// client fetches first, and the repository trio it then drives.
///
/// Extracted so each suite contains only the behaviour it is actually
/// testing. Repeating it instead trips the duplication gate
/// (`task duplication`), and rightly so — it was already copied once.

/// The JMAP Session object (RFC 8620 §2) a fake server must answer
/// `GET /.well-known/jmap` with.
///
/// [downloadUrl] / [uploadUrl] are omitted unless a suite exercises blobs; a
/// client that needs one and does not get it throws, which is the behaviour
/// worth keeping visible.
Map<String, dynamic> jmapSessionBody({
  required String accountId,
  String apiUrl = 'https://jmap.example.com/api/',
  String username = 'alice@example.com',
  String state = 'sess1',
  String? downloadUrl,
  String? uploadUrl,
}) {
  return {
    'apiUrl': apiUrl,
    if (downloadUrl != null) 'downloadUrl': downloadUrl,
    if (uploadUrl != null) 'uploadUrl': uploadUrl,
    'accounts': {
      accountId: {'name': username, 'isPersonal': true},
    },
    'primaryAccounts': {
      'urn:ietf:params:jmap:core': accountId,
      'urn:ietf:params:jmap:mail': accountId,
    },
    'capabilities': {
      'urn:ietf:params:jmap:core': <String, dynamic>{},
      'urn:ietf:params:jmap:mail': <String, dynamic>{},
    },
    'username': username,
    'state': state,
  };
}

/// The session fetch's full HTTP response, including the JSON content-type
/// `JmapClient.connect` checks before parsing.
http.Response jmapSessionResponse({
  required String accountId,
  String? downloadUrl,
  String? uploadUrl,
}) {
  return http.Response(
    jsonEncode(
      jmapSessionBody(
        accountId: accountId,
        downloadUrl: downloadUrl,
        uploadUrl: uploadUrl,
      ),
    ),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// The `methodCalls` of one JMAP API request, as `[method, args, callId]`
/// triples a fake server can switch on.
List<List<dynamic>> jmapMethodCalls(http.Request request) {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  return (body['methodCalls'] as List<dynamic>).cast<List<dynamic>>();
}

/// The envelope a JMAP API response has to come back in.
http.Response jmapApiResponse(
  List<List<dynamic>> methodResponses, {
  String sessionState = 'sess1',
}) {
  return http.Response(
    jsonEncode({
      'sessionState': sessionState,
      'methodResponses': methodResponses,
    }),
    200,
  );
}

/// An in-memory database with the account and email repositories wired to
/// [httpClient], and [account] already stored with a password.
class JmapTestRepos {
  JmapTestRepos({
    required this.db,
    required this.accounts,
    required this.emails,
  });

  final AppDatabase db;
  final AccountRepositoryImpl accounts;
  final EmailRepositoryImpl emails;
}

Future<JmapTestRepos> openJmapTestRepos({
  required http.Client httpClient,
  required Account account,
  required Directory cacheDir,
  String password = 'pw',
}) async {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    getCacheDir: () async => cacheDir,
    httpClient: httpClient,
  );
  await accounts.addAccount(account, password);
  return JmapTestRepos(db: db, accounts: accounts, emails: emails);
}

/// One `Email` object as a JMAP server returns it, with a text body and no
/// attachments.
///
/// Enough properties for `_upsertJmapEmails` to store a row and cache a body;
/// suites that need a specific shape (attachments, missing `blobId`, …) should
/// build their own rather than widen this.
Map<String, dynamic> jmapEmailObject({
  required String id,
  required String mailboxId,
  String? subject,
  String receivedAt = '2026-10-04T10:00:00Z',
  String from = 'bob@example.com',
}) {
  return {
    'id': id,
    'threadId': 't-$id',
    'mailboxIds': {mailboxId: true},
    'subject': subject ?? 'subject $id',
    'receivedAt': receivedAt,
    'from': [
      {'email': from},
    ],
    'keywords': <String, dynamic>{},
    'preview': 'hi',
    'textBody': [
      {'partId': '1', 'type': 'text/plain'},
    ],
    'htmlBody': <dynamic>[],
    'bodyValues': {
      '1': {'value': 'body of $id'},
    },
    'attachments': <dynamic>[],
  };
}

/// The `Email/get` method response a fake server answers with.
List<dynamic> jmapEmailGetResponse({
  required String accountId,
  required String state,
  required List<Map<String, dynamic>> list,
  Object callId = '0',
}) {
  return [
    'Email/get',
    {
      'accountId': accountId,
      'state': state,
      'list': list,
      'notFound': <String>[],
    },
    callId,
  ];
}

/// The value stored under [resourceType] for the one account a test database
/// holds, or null when nothing has been checkpointed yet.
Future<String?> jmapStoredSyncState(
  AppDatabase db,
  String resourceType,
) async {
  final row = await (db.select(db.syncStates)
        ..where((t) => t.resourceType.equals(resourceType)))
      .getSingleOrNull();
  return row?.state;
}
