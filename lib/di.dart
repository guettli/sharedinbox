import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sharedinbox/core/models/account.dart' as model;
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/mailbox_sync_state.dart';
import 'package:sharedinbox/core/models/note.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/note_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/core/repositories/search_history_repository.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/repositories/sync_state_repository.dart';
import 'package:sharedinbox/core/repositories/undo_repository.dart';
import 'package:sharedinbox/core/repositories/user_preferences_repository.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/services/connection_test_service.dart';
import 'package:sharedinbox/core/services/connectivity_service.dart';
import 'package:sharedinbox/core/services/db_encryption_service.dart';
import 'package:sharedinbox/core/services/managesieve_probe_service.dart';
import 'package:sharedinbox/core/services/notification_service.dart';
import 'package:sharedinbox/core/services/undo_service.dart';
import 'package:sharedinbox/core/services/unified_push_service.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
import 'package:sharedinbox/core/sync/reliability_runner.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart'
    hide Email, EmailBody, UserPreferences;
import 'package:sharedinbox/data/db/local_sieve_repository.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/sieve_repository.dart';
import 'package:sharedinbox/data/repositories/account_repository_impl.dart';
import 'package:sharedinbox/data/repositories/app_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/draft_repository_impl.dart';
import 'package:sharedinbox/data/repositories/email_repository_impl.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/note_repository_impl.dart';
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/search_history_repository_impl.dart';
import 'package:sharedinbox/data/repositories/share_key_repository_impl.dart';
import 'package:sharedinbox/data/repositories/sync_log_repository_impl.dart';
import 'package:sharedinbox/data/repositories/sync_state_repository_impl.dart';
import 'package:sharedinbox/data/repositories/undo_repository_impl.dart';
import 'package:sharedinbox/data/repositories/user_preferences_repository_impl.dart';
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

/// Controls the SQLCipher encryption toggle exposed in Preferences. The
/// service operates on `<applicationSupportDir>/sharedinbox.db`, the same
/// path resolved by [initDatabasePath].
final dbEncryptionServiceProvider = Provider<DbEncryptionService>((ref) {
  return DbEncryptionService(currentDatabasePath());
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

/// Streams the [Mailbox] for `(accountId, path)`, or `null` if not yet synced.
/// Used to resolve the human-readable name for a mailbox referenced by path —
/// JMAP accounts store the opaque server id (e.g. "a") as `path`, so anything
/// rendering the path directly would otherwise show the bare id.
final mailboxByPathProvider =
    StreamProvider.autoDispose.family<Mailbox?, (String, String)>((ref, key) {
  final (accountId, path) = key;
  return ref.watch(mailboxRepositoryProvider).observeMailboxes(accountId).map(
        (mailboxes) => mailboxes.cast<Mailbox?>().firstWhere(
              (m) => m?.path == path,
              orElse: () => null,
            ),
      );
});

final draftRepositoryProvider = Provider<DraftRepository>((ref) {
  return DraftRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
    httpClient: ref.watch(httpClientProvider),
  );
});

final outboxRepositoryProvider = Provider<OutboxRepository>((ref) {
  return OutboxRepositoryImpl(ref.watch(dbProvider));
});

/// Live list of every queued outbox row across all accounts, ordered oldest
/// first. Backs the global "Sent Queue" screen and its drawer badge.
final allOutboxProvider = StreamProvider<List<OutboxMessage>>((ref) {
  return ref.watch(outboxRepositoryProvider).observeAllOutbox();
});

/// Every row in the outbound `pending_changes` queue, oldest first. Backs
/// the global Pending Changes screen and the "Pending Changes" drawer badge.
final allPendingChangesProvider = StreamProvider<List<PendingChange>>((ref) {
  return ref.watch(emailRepositoryProvider).observeAllPendingChanges();
});

/// Per-account pending-change count — powers the badge next to each account
/// row in the Manage Accounts (Settings) screen.
final pendingChangeCountForAccountProvider =
    StreamProvider.autoDispose.family<int, String>((ref, accountId) {
  return ref
      .watch(emailRepositoryProvider)
      .observePendingChanges(accountId)
      .map((rows) => rows.length);
});

final emailRepositoryProvider = Provider<EmailRepository>((ref) {
  return EmailRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
    smtpConnect: ref.watch(smtpConnectProvider),
    outbox: ref.watch(outboxRepositoryProvider),
    appLogger: ref.watch(appLoggerProvider),
  );
});

final undoRepositoryProvider = Provider<UndoRepository>((ref) {
  return UndoRepositoryImpl(ref.watch(dbProvider));
});

final searchHistoryRepositoryProvider = Provider<SearchHistoryRepository>((
  ref,
) {
  return SearchHistoryRepositoryImpl(ref.watch(dbProvider));
});

final syncLogRepositoryProvider = Provider<SyncLogRepository>((ref) {
  return SyncLogRepositoryImpl(ref.watch(dbProvider));
});

final syncStateRepositoryProvider = Provider<SyncStateRepository>((ref) {
  return SyncStateRepositoryImpl(ref.watch(dbProvider));
});

/// One-shot future of the per-mailbox sync state for a single account.
/// autoDispose so leaving the screen releases the loaded snapshot.
final syncStateForAccountProvider = FutureProvider.autoDispose
    .family<List<MailboxSyncState>, String>((ref, accountId) {
  return ref.watch(syncStateRepositoryProvider).statesForAccount(accountId);
});

final appLogRepositoryProvider = Provider<AppLogRepository>((ref) {
  return AppLogRepositoryImpl(ref.watch(dbProvider));
});

final appLoggerProvider = Provider<AppLogger>((ref) {
  return AppLogger(ref.watch(appLogRepositoryProvider));
});

final appLogEntriesProvider = StreamProvider.autoDispose
    .family<List<AppLogEntry>, AppLogFilter>((ref, filter) {
  return ref.watch(appLogRepositoryProvider).watchEntries(filter);
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

final isSyncingProvider = StreamProvider.autoDispose.family<bool, String>((
  ref,
  accountId,
) {
  return ref.watch(syncManagerProvider).watchSyncing(accountId);
});

/// Read-only "fetch a single message from the server" probe used by the
/// per-message debug screen (`/debug/messages`) to compare local vs remote.
final messageProbeProvider = Provider<MessageProbe>((ref) {
  return MessageProbeImpl(
    imapConnect: ref.watch(imapConnectProvider),
    httpClient: ref.watch(httpClientProvider),
  );
});

/// Streams a per-message debug snapshot used by the debug screen at
/// `/debug/messages`. Kept out of `core/` so the UI never has to import
/// `data/db/*` (enforced by the layer check in `ci/main.go`).
final messageDebugSnapshotProvider = FutureProvider.autoDispose
    .family<MessageDebugSnapshot, DebugMessageRef>((ref, messageRef) async {
  final database = ref.watch(dbProvider);
  return loadMessageDebugSnapshot(database, messageRef);
});

/// Callback wrapper around [AccountSyncManager.syncNow]. The queued-message
/// tiles depend on this instead of the full [syncManagerProvider] so widget
/// tests can override the kick without materialising a real sync manager.
final syncNowProvider = Provider<bool Function(String accountId)>((ref) {
  return ref.watch(syncManagerProvider).syncNow;
});

final syncManagerProvider = Provider<AccountSyncManager>((ref) {
  final manager = AccountSyncManager(
    ref.watch(accountRepositoryProvider),
    ref.watch(mailboxRepositoryProvider),
    ref.watch(emailRepositoryProvider),
    syncLog: ref.watch(syncLogRepositoryProvider),
    appLogger: ref.watch(appLoggerProvider),
    imapConnect: ref.watch(imapConnectProvider),
    drafts: ref.watch(draftRepositoryProvider),
    notes: ref.watch(noteRepositoryProvider),
    onNewMail: showNewMailNotification,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// UnifiedPush registration owned by the running app. Reads back to the
/// [AccountSyncManager] to trigger an immediate fetch on every push wake-up.
final unifiedPushServiceProvider = Provider<UnifiedPushService>((ref) {
  final service = UnifiedPushService(
    onPushKick: () => ref.read(syncManagerProvider).syncAll(),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Watches offline → online transitions so the outbox is drained as soon as
/// the device is back on the network (#353). Owned by the running app; a
/// missing platform channel just makes the reconnect kick a no-op.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(service.dispose);
  return service;
});

/// Installs the subscription that turns each connectivity reconnect into an
/// immediate outbox flush: clears the per-row backoff (so rows currently
/// waiting on `nextAttemptAt` are eligible now) and kicks every account's
/// sync loop (which calls `flushOutbox` at the start of its next iteration).
///
/// Reading this provider from app startup installs the subscription; the
/// `onDispose` hook cancels it on shutdown.
final reconnectFlushProvider = Provider<StreamSubscription<void>>((ref) {
  final connectivity = ref.watch(connectivityServiceProvider);
  final outbox = ref.watch(outboxRepositoryProvider);
  final syncManager = ref.watch(syncManagerProvider);
  final sub = connectivity.onOnline.listen((_) async {
    await outbox.resetPendingBackoff();
    syncManager.syncAll();
  });
  ref.onDispose(sub.cancel);
  return sub;
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

final undoServiceProvider = NotifierProvider<UndoService, List<UndoAction>>(
  UndoService.new,
);

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
    final header = results[0] as Email?;
    if (header != null) {
      unawaited(_prefetchNextEmailBody(repo, header));
    }
    return (results[0] as Email?, results[1] as EmailBody);
  }

  Future<void> _prefetchNextEmailBody(
    EmailRepository repo,
    Email header,
  ) async {
    // Prefetch is purely opportunistic — swallow any failure (malformed body
    // decode, network, DB) so a background prefetch cannot tear the app down
    // via the runZonedGuarded → CrashScreen path (see #232). The specific
    // trigger from #232 is fixed upstream in Enough-Software/enough_mail#283;
    // once released we still keep this guard for network/DB failures.
    try {
      final prefs = ref.read(userPreferencesProvider).value;
      final action =
          prefs?.afterMailViewAction ?? AfterMailViewAction.nextMessage;
      if (action != AfterMailViewAction.nextMessage) return;

      // Restrict to threads in the current mailbox so a stray thread from
      // another folder (e.g. Junk) does not cause us to prefetch — and later
      // navigate to — a mail that isn't the actual next inbox message (#293).
      final threads = (await repo
              .observeThreads(header.accountId, header.mailboxPath)
              .first)
          .where((t) => t.mailboxPath == header.mailboxPath)
          .toList();
      final currentIndex = threads.indexWhere(
        (t) => t.emailIds.contains(_emailId),
      );
      if (currentIndex < 0 || currentIndex + 1 >= threads.length) return;

      final nextId = threads[currentIndex + 1].latestEmailId;
      await repo.getEmailBody(nextId);
    } catch (e, st) {
      log('prefetch next email body failed', error: e, stackTrace: st);
    }
  }
}

final allAccountsProvider = StreamProvider<List<model.Account>>((ref) {
  return ref.watch(accountRepositoryProvider).observeAccounts();
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

final userPreferencesRepositoryProvider = Provider<UserPreferencesRepository>((
  ref,
) {
  return UserPreferencesRepositoryImpl(ref.watch(dbProvider));
});

final userPreferencesProvider = StreamProvider.autoDispose<UserPreferences>((
  ref,
) {
  return ref.watch(userPreferencesRepositoryProvider).observePreferences();
});

final trustedImageSendersProvider =
    StreamProvider.autoDispose<List<String>>((ref) {
  return ref
      .watch(userPreferencesRepositoryProvider)
      .observeTrustedImageSenders();
});

final noteRepositoryProvider = Provider<NoteRepository>((ref) {
  return NoteRepositoryImpl(
    ref.watch(dbProvider),
    ref.watch(accountRepositoryProvider),
    imapConnect: ref.watch(imapConnectProvider),
  );
});

final installedVersionsProvider = FutureProvider<Map<String, DateTime>>((ref) {
  return ref.watch(dbProvider).loadInstalledVersions();
});

/// Stream of notes for a specific email, identified by (accountId, messageId).
final notesProvider =
    StreamProvider.autoDispose.family<List<EmailNote>, (String, String)>(
  (ref, params) =>
      ref.watch(noteRepositoryProvider).observeNotes(params.$1, params.$2),
);
