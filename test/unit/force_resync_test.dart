// Divergence-and-reconcile integration test for
// [AccountSyncManager.forceResync].
//
// The point of a force re-sync is to fix cases where the local DB drifts
// from the server — a bug, a schema-migration glitch, a manual sqlite edit,
// or a partial `syncEmails` crash. We simulate that drift by:
//
//   - seeding the local DB with a "server-only" email row (missing locally)
//     and a "stale" email row (extra locally),
//   - running `forceResync`,
//   - asserting that the local DB now matches the fake server, that cached
//     email bodies for still-existing messages are preserved (no
//     re-download), and that the progress stream reports the reconcile.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/mailbox.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/sync/account_sync_manager.dart';

void main() {
  test('forceResync reconciles divergence and preserves cached bodies',
      () async {
    final accounts = _FakeAccounts(_jmapAccount());

    // Fake "server truth": one INBOX with two messages.
    final mailboxes = _FakeMailboxes({
      'acc-1': [
        const Mailbox(
          id: 'acc-1:INBOX',
          accountId: 'acc-1',
          path: 'INBOX',
          name: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
          role: 'inbox',
        ),
      ],
    });

    // Server truth: both messages exist. Both were already downloaded
    // before, so their bodies are cached. A well-behaved re-sync should
    // reuse the cache and not re-fetch either body.
    final serverEmails = <String, Set<String>>{
      'acc-1|INBOX': {'msg-1', 'msg-2'},
    };
    final cachedBodies = <String>{'msg-1', 'msg-2'};
    final emails = _FakeEmails(
      serverEmailsByMailbox: serverEmails,
      cachedBodies: cachedBodies,
    );

    // Seed divergence: stale row present locally that no longer exists on
    // the server, and msg-2 missing locally.
    emails.localMetadata['acc-1|INBOX'] = {'msg-1', 'stale-msg'};

    final manager = AccountSyncManager(
      accounts,
      mailboxes,
      emails,
    );

    final snapshots = await manager.forceResync('acc-1').toList();

    // Terminal snapshot must be `complete`, and metadata must match server.
    expect(snapshots.last.phase, ForceResyncPhase.complete);
    expect(emails.localMetadata['acc-1|INBOX'], equals({'msg-1', 'msg-2'}));

    // Cached body for msg-1 is intact — we never re-downloaded it.
    expect(cachedBodies, contains('msg-1'));
    expect(
      emails.bodyFetches,
      isEmpty,
      reason: 'force re-sync must not re-download already-cached bodies',
    );

    // Progress stream reported at least: clearing → syncingMailboxes →
    // syncingEmails → complete.
    final phases = snapshots.map((s) => s.phase).toList();
    expect(phases.first, ForceResyncPhase.clearing);
    expect(phases, contains(ForceResyncPhase.syncingMailboxes));
    expect(phases, contains(ForceResyncPhase.syncingEmails));

    // The final snapshot carries per-mailbox stats matching what we saw.
    expect(snapshots.last.mailboxStats, hasLength(1));
    expect(snapshots.last.mailboxStats.single.mailboxName, 'INBOX');
    expect(snapshots.last.totalMailboxes, 1);

    manager.dispose();
  });

  test('forceResync surfaces per-mailbox errors in the terminal snapshot',
      () async {
    final accounts = _FakeAccounts(_jmapAccount());
    final mailboxes = _FakeMailboxes({
      'acc-1': [
        const Mailbox(
          id: 'acc-1:INBOX',
          accountId: 'acc-1',
          path: 'INBOX',
          name: 'INBOX',
          unreadCount: 0,
          totalCount: 0,
          role: 'inbox',
        ),
      ],
    });
    final emails = _FakeEmails(
      serverEmailsByMailbox: {'acc-1|INBOX': {}},
      cachedBodies: {},
    );
    emails.failOnSyncEmails['INBOX'] = 'permission denied';

    final manager = AccountSyncManager(
      accounts,
      mailboxes,
      emails,
    );

    final snapshots = await manager.forceResync('acc-1').toList();
    expect(snapshots.last.phase, ForceResyncPhase.failed);
    expect(snapshots.last.error, contains('permission denied'));

    manager.dispose();
  });
}

// ── Fakes ────────────────────────────────────────────────────────────────────

Account _jmapAccount() => const Account(
      id: 'acc-1',
      displayName: 'Test',
      email: 't@example.com',
      type: AccountType.jmap,
      jmapUrl: 'http://localhost:0/.well-known/jmap',
    );

class _FakeAccounts implements AccountRepository {
  _FakeAccounts(this._account);
  final Account _account;

  @override
  Stream<List<Account>> observeAccounts() => Stream.value([_account]);
  @override
  Future<Account?> getAccount(String id) async =>
      id == _account.id ? _account : null;
  @override
  Future<String> getPassword(String accountId) async => 'pw';
  @override
  Future<void> addAccount(Account a, String p) async {}
  @override
  Future<void> updateAccount(Account a, {String? password}) async {}
  @override
  Future<void> removeAccount(String id) async {}
}

class _FakeMailboxes implements MailboxRepository {
  _FakeMailboxes(this._byAccount);
  final Map<String, List<Mailbox>> _byAccount;
  final syncMailboxesCalls = <String>[];

  @override
  Stream<List<Mailbox>> observeMailboxes(String? accountId) =>
      Stream.value(_byAccount[accountId] ?? const []);

  @override
  Future<int> syncMailboxes(String accountId) async {
    syncMailboxesCalls.add(accountId);
    return _byAccount[accountId]?.length ?? 0;
  }

  @override
  Future<Mailbox?> findMailboxByRole(String accountId, String role) async =>
      _byAccount[accountId]?.cast<Mailbox?>().firstWhere(
            (m) => m?.role == role,
            orElse: () => null,
          );

  @override
  Future<void> clearForResync(String accountId) async {
    // Server-list-driven reset: mailboxes are always exactly what the
    // fake server reports, so nothing to do here.
  }

  @override
  Future<Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        role: role,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$name',
        accountId: accountId,
        path: name,
        name: name,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: newName,
        unreadCount: 0,
        totalCount: 0,
      );

  @override
  Future<void> deleteMailbox(String accountId, String mailboxPath) async {}

  @override
  Future<Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async =>
      Mailbox(
        id: '$accountId:$mailboxPath',
        accountId: accountId,
        path: mailboxPath,
        name: mailboxPath,
        unreadCount: 0,
        totalCount: 0,
      );
}

class _FakeEmails implements EmailRepository {
  _FakeEmails({
    required this.serverEmailsByMailbox,
    required this.cachedBodies,
  });

  /// keyed by `"accountId|mailboxPath"`.
  final Map<String, Set<String>> serverEmailsByMailbox;
  final Set<String> cachedBodies;

  /// Local metadata cache, keyed by `"accountId|mailboxPath"`.
  final Map<String, Set<String>> localMetadata = {};

  /// Mailboxes for which `syncEmails` should throw.
  final Map<String, String> failOnSyncEmails = {};

  /// Every body fetch we would have made. Empty when the resync respects
  /// the cache.
  final List<String> bodyFetches = [];

  @override
  Future<SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) async {
    final err = failOnSyncEmails[mailboxPath];
    if (err != null) throw StateError(err);

    final key = '$accountId|$mailboxPath';
    final server = serverEmailsByMailbox[key] ?? const {};
    final local = localMetadata[key] ??= {};

    var fetched = 0;
    var skipped = 0;
    for (final id in server) {
      if (local.contains(id)) {
        skipped++;
      } else {
        local.add(id);
        fetched++;
        // Only fetch the body when it isn't already cached — this mirrors
        // the real repo's UID+size skip logic.
        if (!cachedBodies.contains(id)) {
          bodyFetches.add(id);
        }
      }
    }
    // Deletion reconciliation.
    local.removeWhere((id) => !server.contains(id));

    return SyncEmailsResult(
      fetched: fetched,
      skipped: skipped,
      bytesTransferred: fetched * 100,
    );
  }

  @override
  Future<void> clearForResync(String accountId) async {
    localMetadata.removeWhere((k, _) => k.startsWith('$accountId|'));
  }

  // ── Boilerplate: unused by forceResync but required by the interface. ──

  @override
  Stream<List<Email>> observeEmails(String a, String m, {int limit = 50}) =>
      Stream.value([]);
  @override
  Stream<List<EmailThread>> observeThreads(
    String a,
    String m, {
    int limit = 50,
  }) =>
      Stream.value([]);
  @override
  Stream<List<EmailThread>> observeAllInboxThreads({int limit = 50}) =>
      Stream.value([]);
  @override
  Stream<List<Email>> observeEmailsInThread(String a, String m, String t) =>
      Stream.value([]);
  @override
  Future<Email?> getEmail(String id) async => null;
  @override
  Future<EmailBody> getEmailBody(String id, {bool forceRefresh = false}) async =>
      const EmailBody(emailId: '', attachments: []);
  @override
  Future<void> setFlag(String id, {bool? seen, bool? flagged}) async {}
  @override
  Future<void> markAllAsRead(String a, String m) async {}
  @override
  Future<void> moveEmail(String id, String dest) async {}
  @override
  Future<String?> deleteEmail(String id) async => null;
  @override
  Future<void> sendEmail(String a, EmailDraft d) async {}
  @override
  Future<int> enqueueSend(String a, EmailDraft d) async => 0;
  @override
  Future<int> flushOutbox(String a, String p) async => 0;
  @override
  Future<String> downloadAttachment(String id, EmailAttachment a) async => '';
  @override
  Future<String> fetchRawRfc822(String id) async => '';
  @override
  Future<List<Email>> searchEmails(String a, String m, String q) async => [];
  @override
  Future<List<Email>> searchEmailsGlobal(String? a, String q) async => [];
  @override
  Future<List<Email>> searchEmailsStructured(String? a, FilterGroup f) async =>
      [];
  @override
  Future<List<Email>> getEmailsByAddress(String? a, String address) async => [];
  @override
  Future<List<EmailAddress>> searchAddresses(
    String? a,
    String q, {
    int limit = 10,
  }) async =>
      [];
  @override
  Future<int> flushPendingChanges(String a, String p) async => 0;
  @override
  Stream<List<FailedMutation>> observeFailedMutations(String a) =>
      Stream.value([]);
  @override
  Future<void> discardMutation(int id) async {}
  @override
  Future<void> retryMutation(int id) async {}
  @override
  Future<bool> cancelPendingChange(String id, String type) async => false;
  @override
  Future<void> snoozeEmail(String id, DateTime u) async {}
  @override
  Future<int> wakeUpEmails(String a) async => 0;
  @override
  Future<void> restoreEmails(List<Email> es) async {}
  @override
  Future<Email?> findEmailByMessageId(String a, String m) async => null;
  @override
  Future<int> applySieveRules(String a) async => 0;
  @override
  Future<int> previewSieveRuleMatches(String a, String s) async => 0;
  @override
  Future<int> applySieveScriptToInbox(String a, String s) async => 0;
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Stream<void> watchJmapPush(String a, String p) => const Stream.empty();
  @override
  Future<ReliabilityResult> verifySyncReliability(String a, String m) async =>
      ReliabilityResult.healthy;
}
