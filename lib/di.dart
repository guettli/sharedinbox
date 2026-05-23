import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/search_history_repository.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/repositories/undo_repository.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';
import 'package:sharedinbox/core/services/connection_test_service.dart';
import 'package:sharedinbox/core/services/managesieve_probe_service.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/core/services/undo_service.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:sharedinbox/core/sync/reliability_runner.dart';
import 'package:sharedinbox/data/db/database.dart' hide Email, EmailBody;
import 'package:sharedinbox/data/db/local_sieve_repository.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/search_history_repository_impl.dart';
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';
import 'package:sharedinbox/data/repositories/sync_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/undo_repository_impl.dart';
import 'package:sharedinbox/data/storage/flutter_secure_storage_impl.dart';

/// Swappable IMAP connection factory — override in tests to use plaintext.
final imapConnectProvider = Provider<ImapConnectFn>((ref) => connectImap);

/// Swappable SMTP connection factory — override in tests to use plaintext.
final smtpConnectProvider = Provider<SmtpConnectFn>((ref) => connectSmtp);

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

final shareKeyRepositoryProvider = Provider<ShareKeyRepository>((ref) {
  return ShareKeyRepositoryImpl(ref.watch(dbProvider));
});

final mailboxRepositoryProvider = Provider<MailboxRepository>((ref) {
  return MailboxRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
  );
});

final draftRepositoryProvider = Provider<DraftRepository>((ref) {
  return DraftRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
  );
});

final emailRepositoryProvider = Provider<EmailRepository>((ref) {
  return EmailRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
    smtpConnect: ref.watch(smtpConnectProvider),
  );
});

final undoRepositoryProvider = Provider<UndoRepository>((ref) {
  return UndoRepositoryImpl(ref.watch(dbProvider));
});

final searchHistoryRepositoryProvider =
    Provider<SearchHistoryRepository>((ref) {
  return SearchHistoryRepositoryImpl(ref.watch(dbProvider));
});

final syncLogRepositoryProvider = Provider<SyncLogRepository>((ref) {
  return SyncLogRepositoryImpl(ref.watch(dbProvider));
});

final syncLastErrorProvider =
    StreamProvider.autoDispose.family<String?, String>((ref, accountId) {
  return ref.watch(syncLogRepositoryProvider).observeLastError(accountId);
});

final reliabilityRunnerProvider = Provider<ReliabilityRunner>((ref) {
  final runner = ReliabilityRunner(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    ref.watch(mailboxRepositoryProvider),
    ref.watch(emailRepositoryProvider),
  );
  ref.onDispose(runner.stop);
  return runner;
});

final syncHealthProvider =
    StreamProvider.autoDispose.family<SyncHealthRow?, String>((ref, accountId) {
  final db = ref.watch(dbProvider);
  return (db.select(
    db.syncHealth,
  )..where((t) => t.accountId.equals(accountId)))
      .watchSingleOrNull();
});

final isSyncingProvider =
    StreamProvider.autoDispose.family<bool, String>((ref, accountId) {
  return ref.watch(syncManagerProvider).watchSyncing(accountId);
});

final syncManagerProvider = Provider<AccountSyncManager>((ref) {
  final manager = AccountSyncManager(
    ref.watch(accountRepositoryProvider),
    ref.watch(mailboxRepositoryProvider),
    ref.watch(emailRepositoryProvider),
    syncLog: ref.watch(syncLogRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
    drafts: ref.watch(draftRepositoryProvider),
    onNewMail: showNewMailNotification,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final accountDiscoveryServiceProvider = Provider<AccountDiscoveryService>((
  ref,
) {
  return AccountDiscoveryServiceImpl(ref.watch(httpClientProvider));
});

final sieveRepositoryProvider = Provider<SieveRepository>((ref) {
  return SieveRepository(
    ref.watch(accountRepositoryProvider),
    ref.watch(httpClientProvider),
  );
});

final localSieveRepositoryProvider = Provider<LocalSieveRepository>((ref) {
  return LocalSieveRepository(ref.watch(dbProvider));
});

final connectionTestServiceProvider = Provider<ConnectionTestService>((ref) {
  return ConnectionTestServiceImpl(
    ref.watch(httpClientProvider),
    imapConnect: ref.watch(imapConnectProvider),
    smtpConnect: ref.watch(smtpConnectProvider),
  );
});

final manageSieveProbeServiceProvider = Provider<ManageSieveProbeService>((
  ref,
) {
  return ManageSieveProbeService(ref.watch(accountRepositoryProvider));
});

final undoServiceProvider =
    NotifierProvider<UndoService, List<UndoAction>>(UndoService.new);

/// Loads email header + body and marks the email as seen.
/// Owned by [EmailDetailScreen]; decouples data loading from the widget tree.
final emailDetailProvider = AsyncNotifierProvider.autoDispose
    .family<EmailDetailNotifier, (Email?, EmailBody), String>(
  EmailDetailNotifier.new,
);

class EmailDetailNotifier extends AsyncNotifier<(Email?, EmailBody)> {
  EmailDetailNotifier(this._emailId);
  final String _emailId;

  @override
  Future<(Email?, EmailBody)> build() async {
    final repo = ref.read(emailRepositoryProvider);
    final results = await Future.wait([
      repo.getEmail(_emailId),
      repo.getEmailBody(_emailId),
    ]);
    unawaited(repo.setFlag(_emailId, seen: true));
    return (results[0] as Email?, results[1] as EmailBody);
  }
}

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
