import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/pending_change.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';

/// No-op [EmailRepository] stand-in that implements the whole interface with
/// empty/default results. Shared across the reliability-runner and
/// account-sync-manager suites (and any other test that only needs a subset of
/// the repository) so each can subclass it and override just the handful of
/// methods it exercises — instead of restating the full interface and tripping
/// the jscpd duplication gate. Mirrors [FakeSecureStorage] in this folder.
class FakeEmailRepositoryBase implements EmailRepository {
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
  Stream<List<Email>> observeThreadAcrossFolders(String a, String t) =>
      Stream.value([]);
  @override
  Future<Email?> getEmail(String id) async => null;
  @override
  Future<EmailBody> getEmailBody(
    String id, {
    bool forceRefresh = false,
  }) async =>
      const EmailBody(emailId: '', attachments: []);
  @override
  Future<SyncEmailsResult> syncEmails(String a, String m) async =>
      SyncEmailsResult.zero;
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
  Future<String> downloadAttachment(String id, EmailAttachment att) async => '';
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
  Future<List<Email>> getEmailsByAddress(String? a, String addr) async => [];
  @override
  Future<List<EmailAddress>> searchAddresses(
    String? a,
    String q, {
    int limit = 10,
  }) async =>
      [];
  @override
  Stream<List<FailedMutation>> observeFailedMutations(String a) =>
      Stream.value([]);
  @override
  Stream<List<PendingChange>> observePendingChanges(String a) =>
      Stream.value([]);
  @override
  Stream<List<PendingChange>> observeAllPendingChanges() => Stream.value([]);
  @override
  Future<void> discardMutation(int id) async {}
  @override
  Future<void> retryMutation(int id) async {}
  @override
  Future<bool> cancelPendingChange(String id, String type) async => false;
  @override
  Future<void> snoozeEmail(String id, DateTime until) async {}
  @override
  Future<int> wakeUpEmails(String accountId) async => 0;
  @override
  Future<void> restoreEmails(List<Email> emails) async {}
  @override
  Future<Email?> findEmailByMessageId(String a, String messageId) async => null;
  @override
  Stream<String> get onChangesQueued => const Stream.empty();
  @override
  Stream<void> watchJmapPush(String a, String password) => const Stream.empty();
  @override
  Future<int> flushPendingChanges(String a, String password) async => 0;
  @override
  Future<ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async =>
      ReliabilityResult.healthy;
  @override
  Future<MailboxDiagnostics> diagnoseMailbox(String a, String m) async =>
      MailboxDiagnostics.empty(accountId: a, mailboxPath: m);
  @override
  Future<int> sweepOrphanThreads(String a, String m) async => 0;
  @override
  Future<void> clearForResync(String accountId) async {}
  @override
  Future<void> clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) async {}
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
