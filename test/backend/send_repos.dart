import 'dart:io';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';

import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';
import 'localhost_mapping_client.dart';
import 'stalwart_harness.dart';

/// A fresh database with [account] (signed in with [password]) whose folder
/// list is synced — a send files its Sent copy into the folder that sync found
/// — and an [EmailRepositoryImpl] wired to the dev Stalwart.
Future<({AppDatabase db, EmailRepositoryImpl emails})> openSendRepos(
  Account account,
  String password,
  Directory cacheDir,
) async {
  final db = openTestDatabase();
  final accounts = AccountRepositoryImpl(db, MapSecureStorage());
  final http = LocalhostMappingClient();
  final emails = EmailRepositoryImpl(
    db,
    accounts,
    imapConnect: testImapConnect,
    smtpConnect: testSmtpConnect,
    httpClient: http,
    getCacheDir: () async => cacheDir,
  );
  await accounts.addAccount(account, password);
  await MailboxRepositoryImpl(
    db,
    accounts,
    imapConnect: testImapConnect,
    httpClient: http,
  ).syncMailboxes(account.id);
  return (db: db, emails: emails);
}
