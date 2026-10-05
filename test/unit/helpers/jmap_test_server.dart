import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
///
/// [notFound] must name every requested id missing from [list] — that is what
/// a real server does (RFC 8620 §5.1), and the client deletes on the strength
/// of it. A fake that omits an id without naming it here is modelling a
/// *non-compliant* server, which is a different test.
List<dynamic> jmapEmailGetResponse({
  required String accountId,
  required String state,
  required List<Map<String, dynamic>> list,
  List<String> notFound = const [],
  Object? callId = '0',
}) {
  return [
    'Email/get',
    {
      'accountId': accountId,
      'state': state,
      'list': list,
      'notFound': notFound,
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

/// One `[method, args, callId]` triple from a JMAP API request.
class JmapCall {
  JmapCall(this.method, this.args, this.callId);

  final String method;
  final Map<String, dynamic> args;
  final Object? callId;

  /// `ids` as a list of strings, empty when absent. An empty list is how a
  /// client asks for nothing (an `Email/get` state probe); `null` would mean
  /// *every* record, so the two must not be conflated.
  List<String> get ids =>
      ((args['ids'] as List<dynamic>?) ?? const []).cast<String>();

  /// Whether the call back-references another call's result (`#ids`) rather
  /// than naming the ids itself.
  bool get isBackReferenced => args.containsKey('#ids');
}

/// Thrown by a handler to answer at the HTTP level instead of with a method
/// response — for the failures (503, a malformed body) a method response
/// cannot express.
class JmapRawResponse implements Exception {
  JmapRawResponse(this.response);

  final http.Response response;
}

/// A fake JMAP server: answers the session fetch, then routes every method
/// call in a request to [handle].
///
/// [handle] returns the method response for a call it recognises, or null to
/// let the server answer `unknownMethod` — so a suite scripts only the methods
/// it cares about and an unexpected call fails loudly rather than being
/// silently absorbed. Throw [JmapRawResponse] from it to answer at the HTTP
/// level. [handleRaw] sees non-API requests (blob download/upload) first.
http.Client jmapFakeServer({
  required String accountId,
  required FutureOr<List<dynamic>?> Function(JmapCall call) handle,
  FutureOr<http.Response?> Function(http.BaseRequest request)? handleRaw,
  String? downloadUrl,
  String? uploadUrl,
}) {
  return MockClient((req) async {
    if (req.url.path.contains('well-known')) {
      return jmapSessionResponse(
        accountId: accountId,
        downloadUrl: downloadUrl,
        uploadUrl: uploadUrl,
      );
    }
    if (handleRaw != null) {
      final raw = await handleRaw(req);
      if (raw != null) return raw;
    }

    final methodResponses = <List<dynamic>>[];
    try {
      for (final call in jmapMethodCalls(req)) {
        final parsed = JmapCall(
          call[0] as String,
          call[1] as Map<String, dynamic>,
          call[2],
        );
        final response = await handle(parsed);
        methodResponses.add(
          response ??
              [
                'error',
                {'type': 'unknownMethod'},
                parsed.callId,
              ],
        );
      }
    } on JmapRawResponse catch (e) {
      return e.response;
    }
    return jmapApiResponse(methodResponses);
  });
}

/// An `Email/get` response rendering each of [ids] with [jmapEmailObject],
/// skipping anything in [omit] so a suite can make the server leave an id out
/// of a response it was asked for. Omitted ids are named in `notFound`, as a
/// compliant server does, unless [omitSilently] is set.
List<dynamic> jmapEmailGetResponseFor({
  required String accountId,
  required String state,
  required Iterable<String> ids,
  required String mailboxId,
  String subjectPrefix = 'subject',
  Set<String> omit = const {},
  bool omitSilently = false,
  Object? callId = '0',
}) {
  return jmapEmailGetResponse(
    accountId: accountId,
    state: state,
    list: [
      for (final id in ids)
        if (!omit.contains(id))
          jmapEmailObject(
            id: id,
            mailboxId: mailboxId,
            subject: '$subjectPrefix $id',
          ),
    ],
    // A compliant server names what it left out. Set [omitSilently] to model
    // one that does not.
    notFound: omitSilently
        ? const []
        : [
            for (final id in ids)
              if (omit.contains(id)) id,
          ],
    callId: callId,
  );
}

/// Per-test setup every JMAP repository suite needs: sqlite configured once,
/// and a temp body-cache directory created and removed around each test.
///
/// Registers `setUpAll`/`setUp`/`tearDown`, so call it from inside `main()`.
/// Returns an accessor rather than the directory, because the directory does
/// not exist until `setUp` runs.
Directory Function() useJmapTestEnv(String cachePrefix) {
  setUpAll(configureSqliteForTests);
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync(cachePrefix));
  tearDown(() => dir.deleteSync(recursive: true));
  return () => dir;
}

/// Inserts a minimal cached email row, for a suite that needs the row to
/// already exist before a sweep runs.
Future<void> insertJmapEmailRow(
  AppDatabase db, {
  required String accountId,
  required String jmapId,
  required String mailboxPath,
  DateTime? receivedAt,
}) async {
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: '$accountId:$jmapId',
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: 0,
          receivedAt: receivedAt ?? DateTime(2026),
        ),
      );
}

/// Puts a mailbox on the incremental sync path from [state].
///
/// Also stamps a fresh `JMAP:Reconcile` marker, so the 15-minutely
/// `Email/query` safety net stays out of the way of whatever the suite is
/// actually testing.
Future<void> seedJmapSyncState(
  AppDatabase db, {
  required String accountId,
  required String mailboxJmapId,
  required String state,
}) async {
  final now = DateTime.now();
  for (final row in {
    'JMAP:Email:$mailboxJmapId': state,
    'JMAP:Reconcile:$mailboxJmapId': now.toIso8601String(),
  }.entries) {
    await db.into(db.syncStates).insert(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: row.key,
            state: row.value,
            syncedAt: now,
          ),
        );
  }
}

/// [openJmapTestRepos] plus [seedJmapSyncState]: repositories wired to
/// [httpClient] with [mailboxJmapId] already on the incremental sync path.
///
/// The combination is what every suite exercising an incremental sweep needs —
/// a sweep with no stored state takes the full-sync path instead.
Future<JmapTestRepos> openJmapTestReposOnIncrementalPath({
  required http.Client httpClient,
  required Account account,
  required Directory cacheDir,
  required String mailboxJmapId,
  required String syncState,
}) async {
  final repos = await openJmapTestRepos(
    httpClient: httpClient,
    account: account,
    cacheDir: cacheDir,
  );
  await seedJmapSyncState(
    repos.db,
    accountId: account.id,
    mailboxJmapId: mailboxJmapId,
    state: syncState,
  );
  return repos;
}
