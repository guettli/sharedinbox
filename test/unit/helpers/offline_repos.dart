import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';

/// Alice's account [id] on mail.example.com over IMAP. With [aliceJmap] of
/// another id it is the counterpart of that account (one server added
/// twice, [AccountComparison]).
Account aliceImap(String id) => Account(
      id: id,
      displayName: 'Alice',
      email: 'alice@example.com',
      imapHost: 'mail.example.com',
      smtpHost: 'smtp.example.com',
    );

/// Alice's account [id] on mail.example.com over JMAP.
Account aliceJmap(String id) => Account(
      id: id,
      displayName: 'Alice',
      email: 'alice@example.com',
      type: AccountType.jmap,
      jmapUrl: 'https://mail.example.com/.well-known/jmap',
    );

/// An [EmailRepositoryImpl] on [db] that cannot reach an IMAP or SMTP
/// server (a connect fails), for tests of what happens locally; JMAP calls
/// go to [httpClient].
EmailRepositoryImpl offlineEmailRepository(
  AppDatabase db,
  AccountRepositoryImpl accounts, {
  http.Client? httpClient,
  DateTime Function() now = DateTime.now,
}) =>
    EmailRepositoryImpl(
      db,
      accounts,
      imapConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no IMAP in this test')),
      smtpConnect: (_, __, ___) =>
          Future.error(UnsupportedError('no SMTP in this test')),
      httpClient: httpClient,
      now: now,
    );
