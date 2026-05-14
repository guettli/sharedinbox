import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/storage/flutter_secure_storage_impl.dart';

import 'package:workmanager/workmanager.dart';

const _kTaskName = 'si_bg_sync';
const _kResourceType = 'background_check';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((_, __) async {
    try {
      await _doBackgroundSync();
    } catch (_) {}
    return true;
  });
}

Future<void> registerBackgroundSync() async {
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    _kTaskName,
    _kTaskName,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

Future<void> _doBackgroundSync() async {
  final dir = await getApplicationSupportDirectory();
  final db = AppDatabase(
    NativeDatabase(File(p.join(dir.path, 'sharedinbox.db'))),
  );
  try {
    final accountRepo = AccountRepositoryImpl(
      db,
      const FlutterSecureStorageImpl(),
    );
    final accounts = await accountRepo.observeAccounts().first;
    await initNotifications();
    for (final account in accounts) {
      if (account.type != model.AccountType.imap) continue;
      await _checkAccount(db, accountRepo, account);
    }
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
        await showNewMailNotification(account.email);
      }
    } finally {
      await client.logout();
    }
  } catch (_) {}
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
