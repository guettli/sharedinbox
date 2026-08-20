// Read-only Gmail inbox decode probe.
//
// Drives the *real* SharedInbox pipeline (sync -> DB -> body decode) against a
// live Gmail account, one message at a time, newest first, and STOPS at the
// first message that fails to decode -- printing exactly one error block
// (folder, uid, message-id, subject, error, stack). On an all-clean run it
// prints nothing. Messages that decode cleanly are recorded in a cache file so
// a second run skips them and advances to the next unseen message.
//
// This is the headless "CLI" from the plan. It cannot be a plain `dart run`
// binary because lib/core and lib/data import package:flutter, so it runs under
// the Flutter test binding instead. Invoke via `task gmail-probe` (which loads
// ~/.env and picks a quiet reporter) or directly:
//
//   GMAIL_MAIL=you@gmail.com GMAIL_PASSWORD='<app password>' \
//     flutter test test/backend/gmail_inbox_probe_test.dart
//
// READ-ONLY GUARANTEE
//   * Only syncEmails() + getEmailBody() are called. Every IMAP body fetch in
//     the codebase uses BODY.PEEK, so opening a message never sets \Seen.
//   * No flag/move/delete/append/send code path is invoked -- those live in the
//     draft/note/outbox repositories and UI handlers, none of which run here.
//   The account is never mutated. (A server-enforced EXAMINE mode is a possible
//   later hardening; today read-only is guaranteed by construction as above.)

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/data/db/database.dart' hide Account, Email;
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:test/test.dart';

// Reuse the shared in-memory SecureStorage (an OS keyring is never touched)
// rather than redefining it — the duplication check flags a second copy.
import '../unit/account_repository_impl_test.dart' show MapSecureStorage;
import '../unit/db_test_helper.dart';

void main() {
  configureSqliteForTests();

  final gmail = Platform.environment['GMAIL_MAIL'];
  final password = Platform.environment['GMAIL_PASSWORD'];
  final creds = (gmail != null && gmail.isNotEmpty) &&
      (password != null && password.isNotEmpty);

  test(
    'gmail inbox decodes cleanly (read-only)',
    () async {
      const accountId = 'gmail-probe';
      // Gmail's IMAP/SMTP host+port+TLS defaults (imap.gmail.com:993 etc.) are
      // the Account defaults, so only the hosts need spelling out.
      final account = Account(
        id: accountId,
        displayName: gmail!,
        email: gmail,
        username: gmail, // Gmail authenticates with the full address.
        imapHost: 'imap.gmail.com',
        smtpHost: 'smtp.gmail.com',
      );

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = MapSecureStorage();
      final accounts = AccountRepositoryImpl(db, storage);
      await accounts.addAccount(account, password!);

      final cacheDir = Directory.systemTemp.createTempSync(
        'gmail_probe_cache_',
      );
      addTearDown(() => cacheDir.deleteSync(recursive: true));
      // imapConnect defaults to the production TLS connect (connectImap).
      final emails = EmailRepositoryImpl(
        db,
        accounts,
        getCacheDir: () async => cacheDir,
      );

      final appLog = AppLogRepositoryImpl(db);
      const errorFilter = AppLogFilter(levels: {AppLogLevel.error});

      // Persistent skip-cache of message-ids proven to decode cleanly.
      final cacheFile = File(
        Platform.environment['GMAIL_PROBE_CACHE'] ??
            '${Platform.environment['HOME']}/.cache/gmail_probe_clean.json',
      );
      final clean = _loadClean(cacheFile);

      // Populate the local DB from INBOX (read-only sync).
      await emails.syncEmails(accountId, 'INBOX');

      // observeEmails defaults to limit:50 — pass a high cap so the probe sees
      // every INBOX row synced into the DB, not just the newest page. Coverage
      // is whatever syncEmails() pulled (the most-recent window it fetches).
      final inbox = [
        ...await emails.observeEmails(accountId, 'INBOX', limit: 1000000).first,
      ];
      // Newest first, tiebreak on uid.
      inbox.sort((a, b) {
        final byDate = b.receivedAt.compareTo(a.receivedAt);
        if (byDate != 0) return byDate;
        return b.uid.compareTo(a.uid);
      });

      for (final e in inbox) {
        final key = e.messageId ?? e.id;
        if (clean.contains(key)) continue;

        final errsBefore =
            (await appLog.watchEntries(errorFilter).first).length;

        try {
          await emails.getEmailBody(e.id);
        } catch (err, st) {
          fail(_report(e, err.toString(), st.toString()));
        }

        // getEmailBody decodes best-effort and logs (rather than throws) on a
        // malformed body, so a new error-level app-log entry is also a failure.
        final errsAfter = await appLog.watchEntries(errorFilter).first;
        if (errsAfter.length > errsBefore) {
          final top = errsAfter.first; // newest first
          fail(
            _report(
              e,
              '${top.event}: ${top.message}',
              top.dataJson ?? '(no data/stack captured in app log)',
            ),
          );
        }

        clean.add(key);
        _saveClean(cacheFile, clean); // persist progress after every message
      }
    },
    skip: creds
        ? false
        : 'set GMAIL_MAIL and GMAIL_PASSWORD (e.g. via ~/.env) to run',
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

Set<String> _loadClean(File f) {
  if (!f.existsSync()) return <String>{};
  try {
    final list = jsonDecode(f.readAsStringSync()) as List<dynamic>;
    return list.map((e) => e as String).toSet();
  } catch (_) {
    return <String>{};
  }
}

void _saveClean(File f, Set<String> clean) {
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(jsonEncode(clean.toList()));
}

String _report(Email e, String error, String stack) {
  return '\n'
      '================ GMAIL DECODE FAILURE ================\n'
      'folder:     ${e.mailboxPath}\n'
      'uid:        ${e.uid}\n'
      'message-id: ${e.messageId ?? '(none)'}\n'
      'subject:    ${e.subject ?? '(none)'}\n'
      'received:   ${e.receivedAt.toIso8601String()}\n'
      'error:      $error\n'
      'stack/data:\n$stack\n'
      '=====================================================';
}
