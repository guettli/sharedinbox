// Shared helpers for widget tests.
//
// Each test pumps [buildApp] which wires up a fresh GoRouter (same route tree
// as the real app) inside a ProviderScope whose repository providers are
// replaced with lightweight in-memory fakes.  No database or network is used.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/discovery_result.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/models/outbox_message.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/models/user_preferences.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/core/repositories/search_history_repository.dart';
import 'package:sharedinbox/core/repositories/share_key_repository.dart';
import 'package:sharedinbox/core/repositories/sync_log_repository.dart';
import 'package:sharedinbox/core/repositories/user_preferences_repository.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';
import 'package:sharedinbox/core/services/connection_test_service.dart';
import 'package:sharedinbox/core/services/db_encryption_service.dart';
import 'package:sharedinbox/core/services/managesieve_probe_service.dart';
import 'package:sharedinbox/core/services/share_encryption_service.dart';
import 'package:sharedinbox/core/sync/message_debug_service.dart';
import 'package:sharedinbox/data/db/database.dart'
    show AppDatabase, SyncHealthRow;
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/account_home_screen.dart';
import 'package:sharedinbox/ui/screens/account_list_screen.dart';
import 'package:sharedinbox/ui/screens/account_receive_screen.dart';
import 'package:sharedinbox/ui/screens/account_send_screen.dart';
import 'package:sharedinbox/ui/screens/add_account_screen.dart';
import 'package:sharedinbox/ui/screens/address_emails_screen.dart';
import 'package:sharedinbox/ui/screens/combined_inbox_screen.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';
import 'package:sharedinbox/ui/screens/edit_account_screen.dart';
import 'package:sharedinbox/ui/screens/email_detail_nav.dart';
import 'package:sharedinbox/ui/screens/email_detail_screen.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';
import 'package:sharedinbox/ui/screens/message_debug_screen.dart';
import 'package:sharedinbox/ui/screens/push_settings_screen.dart';
import 'package:sharedinbox/ui/screens/search_screen.dart';
import 'package:sharedinbox/ui/screens/thread_detail_screen.dart';
import 'package:sharedinbox/ui/screens/trusted_image_senders_screen.dart';
import 'package:sharedinbox/ui/screens/user_preferences_screen.dart';

// ---------------------------------------------------------------------------
// Fake repositories
// ---------------------------------------------------------------------------

class FakeAccountRepository implements AccountRepository {
  FakeAccountRepository([List<Account>? accounts])
      : _accounts = List.of(accounts ?? []);

  final List<Account> _accounts;
  bool hasPassword = true;

  @override
  Stream<List<Account>> observeAccounts() => Stream.value(List.of(_accounts));

  @override
  Future<Account?> getAccount(String id) async {
    for (final a in _accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  @override
  Future<void> addAccount(Account account, String password) async =>
      _accounts.add(account);

  @override
  Future<void> updateAccount(Account account, {String? password}) async {
    final idx = _accounts.indexWhere((a) => a.id == account.id);
    if (idx >= 0) _accounts[idx] = account;
  }

  @override
  Future<void> removeAccount(String id) async =>
      _accounts.removeWhere((a) => a.id == id);

  @override
  Future<String> getPassword(String accountId) async {
    if (!hasPassword) {
      throw StateError('No password stored for account $accountId');
    }
    return 'test-password';
  }
}

class FakeShareKeyRepository implements ShareKeyRepository {
  FakeShareKeyRepository({ShareKeyMaterial? material}) : _material = material;

  ShareKeyMaterial? _material;

  @override
  Future<ShareKeyMaterial> createKeyPair() async {
    _material ??= await ShareEncryptionService.generateKeyPair();
    return _material!;
  }

  @override
  Future<ShareKeyMaterial?> findByKeyId(dynamic keyId) async => _material;
}

class FakeDraftRepository implements DraftRepository {
  int _nextId = 1;
  final Map<int, SavedDraft> _drafts = {};

  @override
  Future<SavedDraft> saveDraft({
    int? id,
    String? accountId,
    String? replyToEmailId,
    required String toText,
    required String ccText,
    required String subjectText,
    required String bodyText,
  }) async {
    final draftId = id ?? _nextId++;
    final draft = SavedDraft(
      id: draftId,
      accountId: accountId,
      replyToEmailId: replyToEmailId,
      toText: toText,
      ccText: ccText,
      subjectText: subjectText,
      bodyText: bodyText,
      updatedAt: DateTime.now(),
    );
    _drafts[draftId] = draft;
    return draft;
  }

  @override
  Future<SavedDraft?> findDraft({String? replyToEmailId}) async {
    final matches = _drafts.values.where((d) {
      if (replyToEmailId == null) return d.replyToEmailId == null;
      return d.replyToEmailId == replyToEmailId;
    }).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return matches.isEmpty ? null : matches.first;
  }

  @override
  Future<SavedDraft?> getDraft(int id) async => _drafts[id];

  @override
  Future<void> deleteDraft(int id) async => _drafts.remove(id);

  @override
  Future<void> syncDrafts(String accountId) async {}
}

class FakeMailboxRepository implements MailboxRepository {
  final List<Mailbox> _mailboxes;

  FakeMailboxRepository([List<Mailbox>? mailboxes])
      : _mailboxes = mailboxes ?? [];

  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) =>
      Stream.value(List.of(_mailboxes));

  @override
  Future<int> syncMailboxes(String accountId) async => 0;

  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      _mailboxes.where((m) => m.role == role).firstOrNull;

  @override
  Future<void> clearForResync(String accountId) async {}

  @override
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) async {
    final displayPath =
        parentDisplayPath == null ? name : '$parentDisplayPath/$name';
    final mailbox = Mailbox(
      id: '$accountId:$displayPath',
      accountId: accountId,
      path: displayPath,
      name: name,
      displayPath: displayPath,
      role: role,
      unreadCount: 0,
      totalCount: 0,
    );
    _mailboxes.add(mailbox);
    return mailbox;
  }

  @override
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) async {
    final displayPath =
        parentDisplayPath == null ? name : '$parentDisplayPath/$name';
    final mailbox = Mailbox(
      id: '$accountId:$displayPath',
      accountId: accountId,
      path: displayPath,
      name: name,
      displayPath: displayPath,
      unreadCount: 0,
      totalCount: 0,
    );
    _mailboxes.add(mailbox);
    return mailbox;
  }

  final List<({String path, String newName})> renameCalls = [];
  final List<String> deleteCalls = [];
  final List<({String path, String? newParent})> moveCalls = [];

  @override
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async {
    renameCalls.add((path: mailboxPath, newName: newName));
    final idx = _mailboxes.indexWhere(
      (m) => m.accountId == accountId && m.path == mailboxPath,
    );
    if (idx < 0) throw Exception('Mailbox "$mailboxPath" not found');
    final old = _mailboxes[idx];
    final parts = old.displayPath.split('/');
    parts[parts.length - 1] = newName;
    final newDisplay = parts.join('/');
    final updated = old.copyWith(name: newName, displayPath: newDisplay);
    _mailboxes[idx] = updated;
    return updated;
  }

  @override
  Future<void> deleteMailbox(String accountId, String mailboxPath) async {
    deleteCalls.add(mailboxPath);
    _mailboxes.removeWhere(
      (m) => m.accountId == accountId && m.path == mailboxPath,
    );
  }

  @override
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async {
    moveCalls.add((path: mailboxPath, newParent: newParentDisplayPath));
    final idx = _mailboxes.indexWhere(
      (m) => m.accountId == accountId && m.path == mailboxPath,
    );
    if (idx < 0) throw Exception('Mailbox "$mailboxPath" not found');
    final old = _mailboxes[idx];
    final newDisplay = newParentDisplayPath == null
        ? old.name
        : '$newParentDisplayPath/${old.name}';
    final updated = old.copyWith(displayPath: newDisplay);
    _mailboxes[idx] = updated;
    return updated;
  }
}

class FakeOutboxRepository implements OutboxRepository {
  final List<OutboxMessage> messages = [];

  @override
  Future<int> enqueue(String accountId, EmailDraft draft) async => 0;

  @override
  Future<int> flush(
    String accountId,
    Future<void> Function(OutboxJob job) sender, {
    DateTime? now,
    OutboxFlushObserver? observer,
  }) async =>
      0;

  @override
  Stream<List<OutboxMessage>> observeOutbox(String accountId) =>
      Stream.value(messages);

  @override
  Stream<List<OutboxMessage>> observeAllOutbox() => Stream.value(messages);

  @override
  Future<void> retry(int id) async {}

  @override
  Future<void> discard(int id) async {}
}

class FakeEmailRepository implements EmailRepository {
  final List<Email> _emails;
  final Email? _emailDetail;
  final EmailBody _emailBody;
  final String _rawRfc822;

  final List<Email> _searchResults;

  /// Optional override: when set, [searchEmails] calls this instead of
  /// returning [_searchResults]. Useful for testing race-condition fixes.
  final Future<List<Email>> Function(String query)? onSearch;

  FakeEmailRepository({
    List<Email>? emails,
    Email? emailDetail,
    EmailBody? emailBody,
    EmailBody? refreshedEmailBody,
    List<Email>? searchResults,
    List<Email>? structuredSearchResults,
    String rawRfc822 = '',
    this.onSearch,
  })  : _emails = emails ?? [],
        _emailDetail = emailDetail,
        _searchResults = searchResults ?? [],
        _structuredSearchResults = structuredSearchResults ?? const [],
        _rawRfc822 = rawRfc822,
        _refreshedEmailBody = refreshedEmailBody,
        _emailBody = emailBody ?? const EmailBody(emailId: '', attachments: []);

  final List<Email> _structuredSearchResults;

  /// Returned when [getEmailBody] is called with `forceRefresh: true`. Falls
  /// back to [_emailBody] when null, so existing tests stay unaffected.
  final EmailBody? _refreshedEmailBody;

  /// Forced-refresh call counter, asserted in tests that exercise the
  /// "self-heal" path triggered by the structure / headers menu items.
  int getEmailBodyForceRefreshCalls = 0;

  @override
  Stream<List<Email>> observeEmails(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) =>
      Stream.value(List.of(_emails));

  @override
  Stream<List<EmailThread>> observeThreads(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) =>
      observeEmails(accountId, mailboxPath)
          .map((emails) => emails.map(_toThread).toList());

  @override
  Stream<List<EmailThread>> observeAllInboxThreads({int limit = 50}) =>
      Stream.value(_emails.map(_toThread).toList());

  static EmailThread _toThread(Email e) => EmailThread(
        threadId: e.threadId ?? e.id,
        subject: e.subject,
        preview: e.preview,
        participants: e.from,
        latestDate: e.sentAt ?? e.receivedAt,
        messageCount: 1,
        hasUnread: !e.isSeen,
        isFlagged: e.isFlagged,
        latestEmailId: e.id,
        emailIds: [e.id],
        accountId: e.accountId,
        mailboxPath: e.mailboxPath,
      );

  @override
  Stream<List<Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) =>
      Stream.value(_emails.where((e) => e.threadId == threadId).toList());

  @override
  Future<Email?> getEmail(String emailId) async {
    for (final e in _searchResults) {
      if (e.id == emailId) return e;
    }
    for (final e in _emails) {
      if (e.id == emailId) return e;
    }
    return _emailDetail;
  }

  @override
  Future<EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      getEmailBodyForceRefreshCalls++;
      return _refreshedEmailBody ?? _emailBody;
    }
    return _emailBody;
  }

  @override
  Future<SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) async =>
      SyncEmailsResult.zero;

  /// Records every [setFlag] call so tests can assert on batch behaviour.
  final List<({String emailId, bool? seen, bool? flagged})> setFlagCalls = [];

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {
    setFlagCalls.add((emailId: emailId, seen: seen, flagged: flagged));
  }

  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) async {}

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {}

  @override
  Future<bool> cancelPendingChange(String id, String type) async => false;

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) async {}

  @override
  Future<int> wakeUpEmails(String accountId) async => 0;

  @override
  Future<void> restoreEmails(List<Email> emails) async {}

  @override
  Future<Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async =>
      null;

  @override
  Future<String?> deleteEmail(String emailId) async => null;

  @override
  Stream<String> get onChangesQueued => const Stream.empty();

  @override
  Future<int> flushPendingChanges(String accountId, String password) async => 0;

  /// Records the most recent [sendEmail] call so tests can assert on it.
  String? sentEmailAccountId;
  EmailDraft? sentEmailDraft;

  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {
    sentEmailAccountId = accountId;
    sentEmailDraft = draft;
  }

  @override
  Future<int> enqueueSend(String accountId, EmailDraft draft) async {
    sentEmailAccountId = accountId;
    sentEmailDraft = draft;
    return 0;
  }

  @override
  Future<int> flushOutbox(String accountId, String password) async => 0;

  @override
  Future<String> downloadAttachment(
    String emailId,
    EmailAttachment attachment,
  ) async =>
      '/tmp/${attachment.filename}';

  @override
  Future<String> fetchRawRfc822(String emailId) async => _rawRfc822;

  @override
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async {
    if (onSearch != null) return onSearch!(query);
    return _searchResults;
  }

  @override
  Future<List<Email>> searchEmailsGlobal(
    String? accountId,
    String query,
  ) async =>
      _searchResults;

  @override
  Future<List<Email>> searchEmailsStructured(
    String? accountId,
    FilterGroup filter,
  ) async =>
      List.of(_structuredSearchResults);

  @override
  Future<List<Email>> getEmailsByAddress(
    String? accountId,
    String address,
  ) async =>
      [];

  @override
  Future<List<EmailAddress>> searchAddresses(
    String? accountId,
    String query, {
    int limit = 10,
  }) async =>
      [];

  @override
  Stream<void> watchJmapPush(String accountId, String password) =>
      const Stream.empty();

  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async =>
      ReliabilityResult.healthy;

  @override
  Stream<List<FailedMutation>> observeFailedMutations(String accountId) =>
      Stream.value([]);

  @override
  Stream<List<PendingChange>> observePendingChanges(String accountId) =>
      Stream.value([]);

  @override
  Stream<List<PendingChange>> observeAllPendingChanges() => Stream.value([]);

  @override
  Future<void> discardMutation(int id) async {}

  @override
  Future<void> retryMutation(int id) async {}

  @override
  Future<void> clearForResync(String accountId) async {}

  @override
  Future<int> applySieveRules(String accountId) async => 0;

  @override
  Future<int> previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) async =>
      0;

  @override
  Future<int> applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) async =>
      0;
}

// ---------------------------------------------------------------------------
// Fake services
// ---------------------------------------------------------------------------

class FakeDiscoveryService implements AccountDiscoveryService {
  FakeDiscoveryService(this._result);
  final DiscoveryResult _result;

  @override
  Future<DiscoveryResult> discover(String email) async => _result;
}

class FakeConnectionTestService implements ConnectionTestService {
  FakeConnectionTestService({Exception? error}) : _error = error;
  final Exception? _error;

  @override
  Future<String> testConnection(Account account, String password) async {
    if (_error != null) throw _error;
    return account.username.isNotEmpty ? account.username : account.email;
  }
}

class _NoOpManageSieveProbeService implements ManageSieveProbeService {
  @override
  Future<void> probe(Account account) async {
    /* no-op in tests */
  }
}

// ---------------------------------------------------------------------------
// App builder
// ---------------------------------------------------------------------------

/// Builds a fully wired test app that starts at [initialLocation].
///
/// Providers are replaced with [overrides], so no database or network is used.
/// A fresh [GoRouter] is created for every call so tests are independent.
Widget buildApp({
  required String initialLocation,
  required List<Override> overrides,
  UserPreferencesRepository? userPreferences,
  ThemeMode themeMode = ThemeMode.light,
  bool debugShowCheckedModeBanner = true,
  Object? initialExtra,
}) {
  final testRouter = GoRouter(
    initialLocation: initialLocation,
    initialExtra: initialExtra,
    routes: [
      GoRoute(
        path: '/accounts',
        builder: (ctx, state) => const AccountListScreen(),
        routes: [
          GoRoute(
            path: 'add',
            builder: (ctx, state) => const AddAccountScreen(),
          ),
          GoRoute(
            path: 'receive',
            builder: (ctx, state) => const AccountReceiveScreen(),
          ),
          GoRoute(
            path: 'send',
            builder: (ctx, state) => const AccountSendScreen(),
          ),
          GoRoute(
            path: 'preferences',
            builder: (ctx, state) => const UserPreferencesScreen(),
          ),
          GoRoute(
            path: 'push',
            builder: (ctx, state) => const PushSettingsScreen(),
          ),
          GoRoute(
            path: 'trusted-senders',
            builder: (ctx, state) => TrustedImageSendersScreen(
              highlightedSender: state.extra as String?,
            ),
          ),
          GoRoute(
            path: ':accountId',
            builder: (ctx, state) => AccountHomeScreen(
              accountId: state.pathParameters['accountId']!,
            ),
          ),
          GoRoute(
            path: ':accountId/edit',
            builder: (ctx, state) => EditAccountScreen(
              accountId: state.pathParameters['accountId']!,
            ),
          ),
          GoRoute(
            path: ':accountId/search',
            builder: (ctx, state) =>
                SearchScreen(accountId: state.pathParameters['accountId']!),
          ),
          GoRoute(
            path: ':accountId/emails/by-address/:address',
            builder: (ctx, state) => AddressEmailsScreen(
              accountId: state.pathParameters['accountId']!,
              address: state.pathParameters['address']!,
            ),
          ),
          GoRoute(
            path: ':accountId/mailboxes',
            builder: (ctx, state) => MailboxListScreen(
              accountId: state.pathParameters['accountId']!,
            ),
            routes: [
              GoRoute(
                path: ':mailboxPath/emails',
                builder: (ctx, state) => EmailListScreen(
                  accountId: state.pathParameters['accountId']!,
                  mailboxPath: state.pathParameters['mailboxPath']!,
                ),
                routes: [
                  GoRoute(
                    path: ':emailId',
                    builder: (ctx, state) => EmailDetailScreen(
                      emailId: state.pathParameters['emailId']!,
                      nav: state.extra is EmailDetailNav
                          ? state.extra as EmailDetailNav
                          : null,
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: ':mailboxPath/threads/:threadId',
                builder: (ctx, state) => ThreadDetailScreen(
                  accountId: state.pathParameters['accountId']!,
                  mailboxPath: Uri.decodeComponent(
                    state.pathParameters['mailboxPath']!,
                  ),
                  threadId: Uri.decodeComponent(
                    state.pathParameters['threadId']!,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/compose',
        builder: (ctx, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return ComposeScreen(
            accountId: extra?['accountId'] as String?,
            replyToEmailId: extra?['replyToEmailId'] as String?,
            prefillTo: extra?['prefillTo'] as String?,
            prefillCc: extra?['prefillCc'] as String?,
            prefillSubject: extra?['prefillSubject'] as String?,
            prefillBody: extra?['prefillBody'] as String?,
          );
        },
      ),
      GoRoute(
        path: '/inbox',
        builder: (ctx, state) => const CombinedInboxScreen(),
      ),
      GoRoute(
        path: '/debug/messages',
        builder: (ctx, state) {
          final messages = (state.extra as List<DebugMessageRef>?) ?? const [];
          return MessageDebugScreen(messages: messages);
        },
      ),
    ],
  );

  return ProviderScope(
    // Defaults come first so tests can override them via [overrides].
    //
    // syncLogRepositoryProvider is backed by a Drift StreamQuery. When the
    // provider is disposed, Drift schedules a Timer.run() for cache
    // debouncing. Flutter's test framework then fails the test with "A Timer
    // is still pending". Replacing it with a synchronous stream avoids this.
    // syncHealthProvider has the same issue and is overridden in baseOverrides.
    overrides: [
      dbProvider.overrideWith((ref) {
        final db = AppDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return db;
      }),
      syncLogRepositoryProvider.overrideWithValue(
        const NoOpSyncLogRepository(),
      ),
      userPreferencesRepositoryProvider.overrideWithValue(
        userPreferences ?? FakeUserPreferencesRepository(),
      ),
      ...overrides,
      manageSieveProbeServiceProvider.overrideWith(
        (ref) => _NoOpManageSieveProbeService(),
      ),
    ],
    child: MaterialApp.router(
      routerConfig: testRouter,
      themeMode: themeMode,
      debugShowCheckedModeBanner: debugShowCheckedModeBanner,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        splashFactory: NoSplash.splashFactory,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        splashFactory: NoSplash.splashFactory,
      ),
    ),
  );
}

/// Convenience override list used by most widget tests.
///
/// Includes fakes for all repositories and the two network services so tests
/// never hit the real database, network, or IMAP server.
List<Override> baseOverrides({
  List<Account>? accounts,
  List<Mailbox>? mailboxes,
  DiscoveryResult? discovery,
  Exception? connectionError,
  ShareKeyRepository? shareKeyRepository,
  bool hasStoredPassword = true,
  SyncHealthRow? syncHealth,
}) =>
    [
      accountRepositoryProvider.overrideWithValue(
        FakeAccountRepository(accounts)..hasPassword = hasStoredPassword,
      ),
      mailboxRepositoryProvider
          .overrideWithValue(FakeMailboxRepository(mailboxes)),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      outboxRepositoryProvider.overrideWithValue(FakeOutboxRepository()),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      accountDiscoveryServiceProvider.overrideWithValue(
        FakeDiscoveryService(discovery ?? UnknownDiscovery()),
      ),
      connectionTestServiceProvider.overrideWithValue(
        FakeConnectionTestService(error: connectionError),
      ),
      shareKeyRepositoryProvider.overrideWithValue(
        shareKeyRepository ?? FakeShareKeyRepository(),
      ),
      // syncHealthProvider is backed by a Drift StreamQuery; override with a
      // plain stream to avoid "A Timer is still pending" in tests.
      syncHealthProvider.overrideWith((ref, _) => Stream.value(syncHealth)),
      // The real provider reads the resolved DB path which is only set in
      // production after initDatabasePath() runs. Point it at a temp file
      // so the Preferences screen can render in widget tests.
      dbEncryptionServiceProvider.overrideWith(
        (ref) => DbEncryptionService(_makeTempDbPathForTest()),
      ),
    ];

String _makeTempDbPathForTest() {
  final dir = Directory.systemTemp.createTempSync('si_widget_db_');
  return '${dir.path}/sharedinbox.db';
}

// ---------------------------------------------------------------------------
// Common test fixtures
// ---------------------------------------------------------------------------

const kTestAccount = Account(
  id: 'acc-1',
  displayName: 'Alice',
  email: 'alice@example.com',
  imapHost: 'imap.example.com',
  smtpHost: 'smtp.example.com',
);

const kTestMailbox = Mailbox(
  id: 'acc-1:INBOX',
  accountId: 'acc-1',
  path: 'INBOX',
  name: 'INBOX',
  unreadCount: 3,
  totalCount: 10,
);

Email testEmail({
  String id = 'acc-1:42',
  String subject = 'Hello world',
  bool isSeen = false,
  bool isFlagged = false,
  bool hasAttachment = false,
  String? listUnsubscribeHeader,
}) =>
    Email(
      id: id,
      accountId: 'acc-1',
      mailboxPath: 'INBOX',
      uid: 42,
      subject: subject,
      receivedAt: DateTime(2024, 6),
      sentAt: DateTime(2024, 6),
      from: const [EmailAddress(name: 'Bob', email: 'bob@example.com')],
      to: const [EmailAddress(email: 'alice@example.com')],
      cc: const [],
      isSeen: isSeen,
      isFlagged: isFlagged,
      hasAttachment: hasAttachment,
      listUnsubscribeHeader: listUnsubscribeHeader,
    );

class FakeUserPreferencesRepository implements UserPreferencesRepository {
  FakeUserPreferencesRepository({
    this.menuPosition = MenuPosition.bottom,
    this.mailViewButtonPosition = MenuPosition.bottom,
    this.afterMailViewAction = AfterMailViewAction.nextMessage,
    List<String>? trustedImageSenders,
  }) : _trustedImageSenders = trustedImageSenders ?? [];

  MenuPosition menuPosition;
  MenuPosition mailViewButtonPosition;
  AfterMailViewAction afterMailViewAction;
  final List<String> _trustedImageSenders;

  List<String> get trustedImageSendersForTest =>
      List.unmodifiable(_trustedImageSenders);

  @override
  Stream<UserPreferences> observePreferences() => Stream.value(
        UserPreferences(
          menuPosition: menuPosition,
          mailViewButtonPosition: mailViewButtonPosition,
          afterMailViewAction: afterMailViewAction,
        ),
      );

  @override
  Future<void> updateMenuPosition(MenuPosition position) async {
    menuPosition = position;
  }

  @override
  Future<void> updateMailViewButtonPosition(MenuPosition position) async {
    mailViewButtonPosition = position;
  }

  @override
  Future<void> updateAfterMailViewAction(AfterMailViewAction action) async {
    afterMailViewAction = action;
  }

  @override
  Future<void> updatePrefetchMode(PrefetchMode mode) async {}

  @override
  Future<void> updateBodyCacheLimitMb(int mb) async {}

  @override
  Stream<List<String>> observeTrustedImageSenders() =>
      Stream.value(List.of(_trustedImageSenders));

  @override
  Future<void> addTrustedImageSender(String senderEmail) async {
    final normalized = senderEmail.toLowerCase();
    if (!_trustedImageSenders.contains(normalized)) {
      _trustedImageSenders.add(normalized);
    }
  }

  @override
  Future<void> removeTrustedImageSender(String senderEmail) async {
    _trustedImageSenders.remove(senderEmail.toLowerCase());
  }
}

class FakeSearchHistoryRepository implements SearchHistoryRepository {
  FakeSearchHistoryRepository([List<String> initial = const []])
      : _history = List.of(initial);

  final List<String> _history;

  @override
  Future<List<String>> getRecentSearches() async => List.unmodifiable(_history);

  @override
  Future<void> saveSearch(String query) async {
    _history.remove(query);
    _history.insert(0, query);
    if (_history.length > 10) _history.removeLast();
  }

  @override
  Future<void> deleteSearch(String query) async {
    _history.remove(query);
  }

  @override
  Future<void> clearHistory() async => _history.clear();
}
