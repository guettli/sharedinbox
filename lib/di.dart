import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'core/models/account.dart' as model;
import 'core/repositories/account_repository.dart';
import 'core/repositories/draft_repository.dart';
import 'core/repositories/email_repository.dart';
import 'core/repositories/mailbox_repository.dart';
import 'core/services/account_discovery_service.dart';
import 'core/services/connection_test_service.dart';
import 'core/storage/secure_storage.dart';
import 'core/sync/account_sync_manager.dart';
import 'data/db/database.dart';
import 'data/repositories/account_repository_impl.dart';
import 'data/repositories/draft_repository_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'data/repositories/mailbox_repository_impl.dart';
import 'data/repositories/sync_log_repository_impl.dart';
import 'data/storage/flutter_secure_storage_impl.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return const FlutterSecureStorageImpl();
});

final httpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  return AccountRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(secureStorageProvider),
  );
});

final mailboxRepositoryProvider = Provider<MailboxRepository>((ref) {
  return MailboxRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
  );
});

final draftRepositoryProvider = Provider<DraftRepository>((ref) {
  return DraftRepositoryImpl(ref.watch(dbProvider));
});

final emailRepositoryProvider = Provider<EmailRepository>((ref) {
  return EmailRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
  );
});

final syncLogRepositoryProvider = Provider((ref) {
  return SyncLogRepositoryImpl(ref.watch(dbProvider));
});

final syncManagerProvider = Provider<AccountSyncManager>((ref) {
  final manager = AccountSyncManager(
    ref.watch(accountRepositoryProvider),
    ref.watch(mailboxRepositoryProvider),
    ref.watch(emailRepositoryProvider),
    syncLog: ref.watch(syncLogRepositoryProvider),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final accountDiscoveryServiceProvider =
    Provider<AccountDiscoveryService>((ref) {
  return AccountDiscoveryServiceImpl(ref.watch(httpClientProvider));
});

final connectionTestServiceProvider = Provider<ConnectionTestService>((ref) {
  return ConnectionTestServiceImpl(ref.watch(httpClientProvider));
});

final accountByIdProvider =
    StreamProvider.autoDispose.family<model.Account?, String>((ref, accountId) {
  return ref.watch(accountRepositoryProvider).observeAccounts().map(
        (accounts) => accounts.cast<model.Account?>().firstWhere(
              (a) => a?.id == accountId,
              orElse: () => null,
            ),
      );
});

final accountConnectionStatusProvider =
    FutureProvider.autoDispose.family<void, String>((ref, accountId) async {
  final repo = ref.read(accountRepositoryProvider);
  final account = await repo.getAccount(accountId);
  if (account == null) throw Exception('Account not found');
  final password = await repo.getPassword(accountId);
  await ref
      .read(connectionTestServiceProvider)
      .testConnection(account, password);
});
