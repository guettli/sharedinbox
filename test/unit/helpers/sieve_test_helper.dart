import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

import '../account_repository_impl_test.dart' show MapSecureStorage;
import '../db_test_helper.dart';

/// Shared fixtures for the Sieve repository suites
/// (apply_sieve_rules_test.dart and apply_sieve_script_to_inbox_test.dart).

const spamFileintoScript = '''
require ["fileinto"];
if header :contains "subject" ["SPAM"] {
  fileinto "Archive";
}
''';

const spamDiscardScript = '''
if header :contains "from" ["spam@evil.com"] {
  discard;
}
''';

/// Opens an in-memory database with [account] registered and returns it
/// together with an [EmailRepositoryImpl] on top of it.
Future<(AppDatabase, EmailRepositoryImpl)> makeSieveTestSetup(
  Account account,
) async {
  final db = openTestDatabase();
  final storage = MapSecureStorage();
  final accounts = AccountRepositoryImpl(db, storage);
  await accounts.addAccount(account, 'password');

  final repo = EmailRepositoryImpl(db, accounts);
  return (db, repo);
}

/// Inserts a minimal email row (plus its thread row) for [accountId].
/// Pass `messageId: null` for mail without a Message-ID header.
/// Returns the row id.
Future<String> insertSieveTestEmail(
  AppDatabase db, {
  required String accountId,
  required String id,
  required String? messageId,
  String subject = 'Test',
  String from = 'sender@example.com',
  String mailboxPath = 'INBOX',
}) async {
  await db.into(db.emails).insert(
        EmailsCompanion.insert(
          id: id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          uid: int.parse(id.split(':').last),
          subject: Value(subject),
          receivedAt: DateTime.now(),
          fromJson: Value(
            jsonEncode([
              {'name': '', 'email': from},
            ]),
          ),
          messageId: Value(messageId),
        ),
      );
  // Insert a thread row so _updateThread does not throw.
  await db.into(db.threads).insertOnConflictUpdate(
        ThreadsCompanion.insert(
          id: id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          latestDate: DateTime.now(),
          latestEmailId: id,
        ),
      );
  return id;
}

/// Asserts exactly one pending change of [changeType] was queued and returns
/// its decoded payload.
Future<Map<String, dynamic>> expectSinglePendingChange(
  AppDatabase db,
  String changeType,
) async {
  final pending = await db.select(db.pendingChanges).get();
  expect(pending, hasLength(1));
  expect(pending.first.changeType, changeType);
  return jsonDecode(pending.first.payload) as Map<String, dynamic>;
}
