import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/services/body_cache_service.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/storage/flutter_secure_storage_impl.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

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
    // Pre-load libsqlcipher.so before any sqlite3 call. This isolate runs
    // independently of the main app process, so the workaround must be applied
    // here rather than relying on main() having done it earlier.
    await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
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
