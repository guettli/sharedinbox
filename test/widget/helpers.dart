// Shared helpers for widget tests.
//
// Each test pumps [buildApp] which wires up a fresh GoRouter (same route tree
// as the real app) inside a ProviderScope whose repository providers are
// replaced with lightweight in-memory fakes.  No database or network is used.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/discovery_result.dart';
import 'package:sharedinbox/core/models/draft.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/draft_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/services/account_discovery_service.dart';
import 'package:sharedinbox/core/services/connection_test_service.dart';
import 'package:sharedinbox/core/services/managesieve_probe_service.dart';
import 'package:sharedinbox/di.dart';
import 'package:sharedinbox/ui/screens/account_list_screen.dart';
import 'package:sharedinbox/ui/screens/add_account_screen.dart';
import 'package:sharedinbox/ui/screens/address_emails_screen.dart';
import 'package:sharedinbox/ui/screens/compose_screen.dart';
import 'package:sharedinbox/ui/screens/edit_account_screen.dart';
import 'package:sharedinbox/ui/screens/email_detail_screen.dart';
import 'package:sharedinbox/ui/screens/email_list_screen.dart';
import 'package:sharedinbox/ui/screens/mailbox_list_screen.dart';
import 'package:sharedinbox/ui/screens/search_screen.dart';

// ---------------------------------------------------------------------------
// Fake repositories
// ---------------------------------------------------------------------------

class FakeAccountRepository implements AccountRepository {
  final List<Account> _accounts;

  FakeAccountRepository([List<Account>? accounts])
      : _accounts = List.of(accounts ?? []);

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
  Future<String> getPassword(String accountId) async => 'test-password';
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
}

class FakeMailboxRepository implements MailboxRepository {
  final List<Mailbox> _mailboxes;

  FakeMailboxRepository([List<Mailbox>? mailboxes])
      : _mailboxes = mailboxes ?? [];

  @override
  Stream<List<Mailbox>> observeMailboxes(String accountId) =>
      Stream.value(List.of(_mailboxes));

  @override
  Future<int> syncMailboxes(String accountId) async => 0;

  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      _mailboxes.where((m) => m.role == role).firstOrNull;
}

class FakeEmailRepository implements EmailRepository {
  final List<Email> _emails;
  final Email? _emailDetail;
  final EmailBody _emailBody;

  final List<Email> _searchResults;

  FakeEmailRepository({
    List<Email>? emails,
    Email? emailDetail,
    EmailBody? emailBody,
    List<Email>? searchResults,
  })  : _emails = emails ?? [],
        _emailDetail = emailDetail,
        _searchResults = searchResults ?? [],
        _emailBody = emailBody ?? const EmailBody(emailId: '', attachments: []);

  @override
  Stream<List<Email>> observeEmails(String accountId, String mailboxPath) =>
      Stream.value(List.of(_emails));

  @override
  Stream<List<EmailThread>> observeThreads(
    String accountId,
    String mailboxPath,
  ) =>
      observeEmails(accountId, mailboxPath).map((emails) {
        return emails.map((e) {
          return EmailThread(
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
        }).toList();
      });

  @override
  Future<Email?> getEmail(String emailId) async => _emailDetail;

  @override
  Future<EmailBody> getEmailBody(String emailId) async => _emailBody;

  @override
  Future<SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) async =>
      SyncEmailsResult.zero;

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {}

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {}

  @override
  Future<void> deleteEmail(String emailId) async {}

  @override
  Future<int> flushPendingChanges(String accountId, String password) async => 0;

  @override
  Future<void> sendEmail(String accountId, EmailDraft draft) async {}

  @override
  Future<String> downloadAttachment(
    String emailId,
    EmailAttachment attachment,
  ) async =>
      '/tmp/${attachment.filename}';

  @override
  Future<List<Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query,
  ) async =>
      _searchResults;

  @override
  Future<List<Email>> searchEmailsGlobal(
    String accountId,
    String query,
  ) async =>
      _searchResults;

  @override
  Future<List<Email>> getEmailsByAddress(
    String accountId,
    String address,
  ) async =>
      [];

  @override
  Stream<void> watchJmapPush(String accountId, String password) =>
      const Stream.empty();

  @override
  Stream<List<FailedMutation>> observeFailedMutations(String accountId) =>
      Stream.value([]);

  @override
  Future<void> discardMutation(int id) async {}

  @override
  Future<void> retryMutation(int id) async {}
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
  Future<void> probe(Account account) async {/* no-op in tests */}
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
}) {
  final testRouter = GoRouter(
    initialLocation: initialLocation,
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
            path: ':accountId/edit',
            builder: (ctx, state) => EditAccountScreen(
              accountId: state.pathParameters['accountId']!,
            ),
          ),
          GoRoute(
            path: ':accountId/search',
            builder: (ctx, state) => SearchScreen(
              accountId: state.pathParameters['accountId']!,
            ),
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
                    ),
                  ),
                ],
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
    ],
  );

  return ProviderScope(
    // Always neutralise the ManageSieve probe so widget tests never open a
    // real socket. Tests that need to assert on probe behaviour should supply
    // their own override before this default in [overrides].
    overrides: [
      ...overrides,
      manageSieveProbeServiceProvider
          .overrideWith((ref) => _NoOpManageSieveProbeService()),
    ],
    child: MaterialApp.router(
      routerConfig: testRouter,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
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
}) =>
    [
      accountRepositoryProvider
          .overrideWithValue(FakeAccountRepository(accounts)),
      mailboxRepositoryProvider
          .overrideWithValue(FakeMailboxRepository(mailboxes)),
      emailRepositoryProvider.overrideWithValue(FakeEmailRepository()),
      draftRepositoryProvider.overrideWithValue(FakeDraftRepository()),
      accountDiscoveryServiceProvider.overrideWithValue(
        FakeDiscoveryService(discovery ?? UnknownDiscovery()),
      ),
      connectionTestServiceProvider.overrideWithValue(
        FakeConnectionTestService(error: connectionError),
      ),
    ];

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
    );
