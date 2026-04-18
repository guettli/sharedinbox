import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/repositories/account_repository.dart';
import 'core/repositories/email_repository.dart';
import 'core/repositories/mailbox_repository.dart';
import 'core/storage/secure_storage.dart';
import 'core/sync/account_sync_manager.dart';
import 'data/db/database.dart';
import 'data/repositories/account_repository_impl.dart';
import 'data/repositories/email_repository_impl.dart';
import 'data/repositories/mailbox_repository_impl.dart';
import 'data/storage/flutter_secure_storage_impl.dart';

final dbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final secureStorageProvider = Provider<SecureStorage>((ref) {
  return const FlutterSecureStorageImpl();
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

final emailRepositoryProvider = Provider<EmailRepository>((ref) {
  return EmailRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
  );
});

final syncManagerProvider = Provider<AccountSyncManager>((ref) {
  final manager = AccountSyncManager(
    ref.watch(accountRepositoryProvider),
    ref.watch(mailboxRepositoryProvider),
    ref.watch(emailRepositoryProvider),
  );
  ref.onDispose(manager.dispose);
  return manager;
});
