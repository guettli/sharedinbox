import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/filter/filter_matcher.dart';
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/services/body_cache_service.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';
import 'package:sharedinbox/data/repositories/notification_rule_repository_impl.dart';
import 'package:sharedinbox/data/storage/flutter_secure_storage_impl.dart';

import 'package:workmanager/workmanager.dart';

const _kTaskName = 'si_bg_sync';
const _kPrefetchTaskName = 'si_bg_prefetch';
const _kResourceType = 'background_check';

@pragma('vm:entry-point')
void callbackDispatcher() {
  // Required so that path_provider and other plugins are available in this
  // background isolate (issue #192).
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((taskName, __) async {
    // An unreadable DB (e.g. missing cipher key after a device restore) throws
    // when the background isolate opens it. Catch and return success so
    // WorkManager stops retrying instead of crash-looping against a DB that
    // will never open — the foreground app surfaces the problem to the user.
    try {
      if (taskName == _kPrefetchTaskName) {
        await _doBodyPrefetch();
      } else {
        await _doBackgroundSync();
      }
    } catch (_) {}
    return true;
  });
}

Future<void> registerBackgroundSync() async {
  try {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _kTaskName,
      _kTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } on PlatformException {
    // WorkManager channel unavailable on this device; background sync disabled.
  } on MissingPluginException {
    // Plugin not registered on this device; background sync disabled.
  } catch (_) {
    // Unexpected initialization failure; background sync disabled.
  }
}

/// Registers (or cancels) the body-prefetch WorkManager task based on [mode].
/// Call on app startup and whenever the user changes the prefetch preference.
Future<void> registerBodyPrefetchTask(PrefetchMode mode) async {
  try {
    if (mode == PrefetchMode.disabled) {
      await Workmanager().cancelByUniqueName(_kPrefetchTaskName);
      return;
    }
    final networkType = mode == PrefetchMode.wifiOnly
        ? NetworkType.unmetered
        : NetworkType.connected;
    await Workmanager().registerPeriodicTask(
      _kPrefetchTaskName,
      _kPrefetchTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: networkType),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  } on PlatformException {
    // Ignore — WorkManager unavailable.
  } on MissingPluginException {
    // Ignore — plugin not registered.
  } catch (_) {}
}

Future<AppDatabase> _openBackgroundDb() async {
  final dir = await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, 'sharedinbox.db'));
  return AppDatabase(await openNativeDatabaseForBackground(file));
}

Future<void> _doBackgroundSync() async {
  final db = await _openBackgroundDb();
  try {
    final accountRepo = AccountRepositoryImpl(
      db,
      const FlutterSecureStorageImpl(),
    );
    final noteRepo = NoteRepositoryImpl(db, accountRepo);
    final accounts = await accountRepo.observeAccounts().first;
    await initNotifications();
    for (final account in accounts) {
      // IMAP accounts additionally get the uidNext check that drives the
      // new-mail notification. JMAP accounts get notes-only.
      if (account.type == model.AccountType.imap) {
        await _checkAccount(db, accountRepo, account);
      }
      await _syncNotesForAccount(noteRepo, account);
    }
  } finally {
    await db.close();
  }
}

/// Refreshes the per-account Notes cache from the WorkManager isolate so
/// notes arrive even when the app isn't running. Swallows failures so a
/// broken Notes folder never blocks the new-mail-notification pass.
Future<void> _syncNotesForAccount(
  NoteRepository noteRepo,
  model.Account account,
) async {
  try {
    await noteRepo.syncAllNotes(account.id);
  } catch (e, st) {
    log(
      'background notes sync failed for ${account.email}',
      error: e,
      stackTrace: st,
    );
  }
}

Future<void> _doBodyPrefetch() async {
  final db = await _openBackgroundDb();
  try {
    final accountRepo = AccountRepositoryImpl(
      db,
      const FlutterSecureStorageImpl(),
    );
    await BodyCacheService(db, accountRepo).run();
  } finally {
    await db.close();
  }
}

Future<void> _checkAccount(
  AppDatabase db,
  AccountRepository accountRepo,
  model.Account account,
) async {
  try {
    final password = await accountRepo.getPassword(account.id);
    final username =
        account.username.isNotEmpty ? account.username : account.email;
    final client = await connectImap(account, username, password);
    try {
      final status = await client.statusMailbox(
        imap.Mailbox.virtual('INBOX', []),
        [imap.StatusFlags.uidNext],
      );
      final currentUidNext = status.uidNext;

      final stored = await (db.select(db.syncStates)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.resourceType.equals(_kResourceType),
            ))
          .getSingleOrNull();
      final lastUidNext = _parseUidNext(stored?.state);

      await db.into(db.syncStates).insertOnConflictUpdate(
            SyncStatesCompanion.insert(
              accountId: account.id,
              resourceType: _kResourceType,
              state: jsonEncode({'uidNext': currentUidNext}),
              syncedAt: DateTime.now(),
            ),
          );

      if (lastUidNext != null &&
          currentUidNext != null &&
          currentUidNext > lastUidNext) {
        await _notifyForNewMail(db, account, client, lastUidNext);
      }
    } finally {
      await client.logout();
    }
  } catch (_) {}
}

/// Fetches the envelopes of the messages that arrived since the last check and
/// fires a notification for each one that matches the account's rules. Default
/// behaviour is silent: nothing fires unless the master switch is on and a rule
/// matches. Also records the considered messages so the foreground dispatcher
/// does not notify a second time when the app next syncs.
Future<void> _notifyForNewMail(
  AppDatabase db,
  model.Account account,
  imap.ImapClient client,
  int fromUid,
) async {
  if (!account.notificationsEnabled) return;
  final ruleRepo = NotificationRuleRepositoryImpl(db);
  final rules = await ruleRepo.listRules(account.id);
  if (rules.isEmpty) return;

  await client.selectMailboxByPath('INBOX');
  final search =
      await client.uidSearchMessages(searchCriteria: 'UID $fromUid:*');
  final uids = search.matchingSequence?.toList() ?? [];
  if (uids.isEmpty) return;

  final fetch = await client.uidFetchMessages(
    imap.MessageSequence.fromIds(uids, isUid: true),
    '(UID ENVELOPE)',
  );

  final consideredIds = <String>[];
  for (final msg in fetch.messages) {
    final uid = msg.uid;
    final envelope = msg.envelope;
    if (uid == null || envelope == null) continue;
    final emailId = '${account.id}:INBOX:$uid';
    consideredIds.add(emailId);
    if (rules
        .any((r) => matchesFilter(r.filter, _matchableFromEnvelope(msg)))) {
      await showNewMailNotification(
        title: _envelopeTitle(msg),
        body: _envelopeBody(msg),
        id: emailId.hashCode & 0x7FFFFFFF,
        payload: '${account.id}|$emailId',
      );
    }
  }
  await ruleRepo.markNotified(account.id, consideredIds);
}

MatchableMessage _matchableFromEnvelope(imap.MimeMessage msg) {
  final env = msg.envelope;
  MatchAddress conv(imap.MailAddress a) =>
      MatchAddress(name: a.personalName ?? '', email: a.email);
  List<MatchAddress> list(List<imap.MailAddress>? l) =>
      [for (final a in l ?? const <imap.MailAddress>[]) conv(a)];
  return MatchableMessage(
    from: list(env?.from),
    to: list(env?.to),
    cc: list(env?.cc),
    subject: env?.subject ?? '',
    folder: 'INBOX',
  );
}

String _envelopeTitle(imap.MimeMessage msg) {
  final from = msg.envelope?.from;
  if (from != null && from.isNotEmpty) {
    final name = from.first.personalName?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (from.first.email.isNotEmpty) return from.first.email;
  }
  return 'New mail';
}

String _envelopeBody(imap.MimeMessage msg) {
  final subject = msg.envelope?.subject?.trim();
  return (subject != null && subject.isNotEmpty) ? subject : '(no subject)';
}

int? _parseUidNext(String? state) {
  if (state == null) return null;
  try {
    final decoded = jsonDecode(state);
    if (decoded is Map<String, Object?>) {
      return decoded['uidNext'] as int?;
    }
    return null;
  } catch (_) {
    return null;
  }
}
