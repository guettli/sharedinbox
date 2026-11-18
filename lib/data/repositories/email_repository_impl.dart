import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:sharedinbox/core/filter/filter_expression.dart';
import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/email.dart' as model;
import 'package:sharedinbox/core/models/pending_change.dart' as model;
import 'package:sharedinbox/core/models/send_timing.dart';
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sieve/sieve_flags.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/push_status.dart';
import 'package:sharedinbox/core/utils/cid_utils.dart';
import 'package:sharedinbox/core/utils/email_preview.dart';
import 'package:sharedinbox/core/utils/imap_date.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/core/utils/mail_body_decode.dart';
import 'package:sharedinbox/core/utils/mail_header_decode.dart';
import 'package:sharedinbox/core/utils/mail_header_encode.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/core/utils/mime_filename.dart';
import 'package:sharedinbox/core/utils/subject_normalize.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/db/keyword_fold.dart';
import 'package:sharedinbox/data/imap/header_mail_address.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
import 'package:sharedinbox/data/imap/imap_expunge.dart';
import 'package:sharedinbox/data/imap/mailbox_path_codec.dart';
import 'package:sharedinbox/data/imap/object_id.dart';
import 'package:sharedinbox/data/imap/object_id_fetch.dart';
import 'package:sharedinbox/data/imap/preview_fetch.dart';
import 'package:sharedinbox/data/imap/preview_snippet.dart';
import 'package:sharedinbox/data/imap/rcpt_checking_smtp_client.dart';
import 'package:sharedinbox/data/imap/reply_headers.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';
import 'package:sharedinbox/data/repositories/email_ids.dart';
import 'package:sharedinbox/data/repositories/email_state_writer.dart';
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show removeLocalMailbox;
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';
import 'package:sharedinbox/data/repositories/thread_aggregate.dart';

part 'email_repository_impl/bodies.dart';
part 'email_repository_impl/change_failures.dart';
part 'email_repository_impl/change_queue.dart';
part 'email_repository_impl/counterparts.dart';
part 'email_repository_impl/diagnostics.dart';
part 'email_repository_impl/flush_imap.dart';
part 'email_repository_impl/flush_jmap.dart';
part 'email_repository_impl/jmap_push.dart';
part 'email_repository_impl/local_rows.dart';
part 'email_repository_impl/queries.dart';
part 'email_repository_impl/row_identity.dart';
part 'email_repository_impl/row_mapping.dart';
part 'email_repository_impl/send.dart';
part 'email_repository_impl/sieve.dart';
part 'email_repository_impl/sync.dart';
part 'email_repository_impl/sync_imap.dart';
part 'email_repository_impl/sync_jmap.dart';
part 'email_repository_impl/threads.dart';
part 'email_repository_impl/user_actions.dart';

typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
  account_model.Account account,
  String username,
  String password,
);
typedef GetCacheDirFn = Future<Directory> Function();

/// The [EmailRepository] backed by the local database, IMAP, JMAP and SMTP.
///
/// The implementation is split by writer role (SYNC-REDESIGN.md, Appendix A)
/// into the part files under `email_repository_impl/`, one private
/// extension on this class each. This file keeps the constructor, the state
/// (all fields) and the public API, which forwards to the role implementing
/// it. Constants and static helpers are private top-level declarations in
/// the part of their role.
class EmailRepositoryImpl implements EmailRepository {
  EmailRepositoryImpl(
    AppDatabase db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    SmtpConnectFn smtpConnect = connectSmtp,
    GetCacheDirFn getCacheDir = getTemporaryDirectory,
    FetchObjectIdsFn fetchObjectIds = fetchObjectIdsFromServer,
    FetchPreviewSnippetsFn fetchPreviewSnippets =
        fetchPreviewSnippetsFromServer,
    http.Client? httpClient,
    OutboxRepository? outbox,
    AppLogger? appLogger,
    Duration sendOperationTimeout = const Duration(seconds: 50),
    DateTime Function() now = DateTime.now,
    EmailIdGenerator newId = newEmailId,
    OverlayConsistencySampler? consistencySampler,
  })  : _db = db,
        _now = now,
        _newId = newId,
        _imapConnect = imapConnect,
        _smtpConnect = smtpConnect,
        _getCacheDir = getCacheDir,
        _fetchObjectIds = fetchObjectIds,
        _fetchPreviewSnippets = fetchPreviewSnippets,
        _httpClient = httpClient ?? http.Client(),
        _outbox = outbox ?? OutboxRepositoryImpl(db),
        _appLogger = appLogger,
        _state = EmailStateWriter(db, appLogger: appLogger, now: now),
        _consistencySampler = consistencySampler,
        _sendOperationTimeout = sendOperationTimeout;

  final AppDatabase _db;
  final AccountRepository _accounts;

  /// The clock for change leases; injectable for tests.
  final DateTime Function() _now;

  /// Makes the id of a new email row ([newEmailId]); injectable for tests.
  final EmailIdGenerator _newId;
  final ImapConnectFn _imapConnect;
  final FetchObjectIdsFn _fetchObjectIds;
  final FetchPreviewSnippetsFn _fetchPreviewSnippets;
  final SmtpConnectFn _smtpConnect;
  final GetCacheDirFn _getCacheDir;
  final http.Client _httpClient;
  final OutboxRepository _outbox;
  final AppLogger? _appLogger;

  /// Upper bound on each network call inside [_sendEmailImap]. `SmtpClient`
  /// has no built-in response timeout and `ImapClient.appendMessage` does not
  /// pick up the client's `defaultResponseTimeout` unless `responseTimeout`
  /// is passed explicitly — without these guards a stalled server wedges the
  /// caller indefinitely. This covers the SMTP connect/auth, sendMessage,
  /// the IMAP connect/login, createMailbox, and appendMessage paths so a
  /// hang anywhere along the send pipeline fails fast instead of running
  /// out the wall clock (surfaced by the nightly chaos monkey at #191/#193).
  final Duration _sendOperationTimeout;

  // Lives as long as the repository; never closed (as before the split,
  // when its uses in the same class kept the lint quiet).
  // ignore: close_sinks
  final _changeCtrl = StreamController<String>.broadcast();

  imap.ImapClient? _bodyClient;
  String? _bodyClientAccountId;
  bool _bodyClientBusy = false;
  Timer? _bodyClientIdleTimer;

  /// The email state writer (SYNC-REDESIGN.md §2): the only writer of the
  /// read/star/snooze and location columns.
  final EmailStateWriter _state;

  /// The sampled overlay consistency check after each sync run
  /// ([EmailStateWriter.checkSample]); off when null (tests check the whole
  /// table themselves).
  final OverlayConsistencySampler? _consistencySampler;

  /// Tail of the in-flight [_setFlag] chain per email id. [_setFlag] reads the
  /// row, drops no-op flags, then writes; two overlapping calls for the same
  /// email could otherwise interleave, e.g. the unawaited auto-mark-read on
  /// open landing after the user's "Mark as unread", which read the still
  /// unread row, saw nothing to change and returned (#1186). Chaining makes
  /// each call see the previous call's write.
  final Map<String, Future<void>> _flagChains = {};

  @override
  Stream<String> get onChangesQueued => _changeCtrl.stream;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  /// Closes the pooled body-fetch connection and cancels its idle timer.
  ///
  /// Call this when a repository instance is done with (e.g. the one
  /// BodyCacheService builds per run) so the connection is not held until the
  /// idle timer fires. Safe to call more than once.
  Future<void> dispose() => _closePooledBodyClient();

  // ── Threads (email_repository_impl/threads.dart) ───────────────────────────

  @override
  Future<int> sweepOrphanThreads(String accountId, String mailboxPath) =>
      _sweepOrphanThreads(accountId, mailboxPath);

  @visibleForTesting
  static String? computeThreadIdForTest({
    required String? messageId,
    required String? inReplyTo,
    required String? references,
    String? subject,
    DateTime? date,
  }) =>
      _computeThreadId(
        messageId: messageId,
        inReplyTo: inReplyTo,
        references: references,
        subject: subject,
        date: date,
      );

  // ── Queries (email_repository_impl/queries.dart) ───────────────────────────

  @override
  Stream<List<model.Email>> observeEmails(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) =>
      _observeEmails(accountId, mailboxPath, limit: limit);

  @override
  Stream<List<model.EmailThread>> observeThreads(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) =>
      _observeThreads(accountId, mailboxPath, limit: limit);

  @override
  Stream<List<model.EmailThread>> observeAllInboxThreads({int limit = 50}) =>
      _observeAllInboxThreads(limit: limit);

  @override
  Future<model.Email?> getEmail(String emailId) => _getEmail(emailId);

  @override
  Future<model.Email?> findEmailByMessageId(
    String accountId,
    String messageId, {
    String? preferMailboxPath,
  }) =>
      _findEmailByMessageId(
        accountId,
        messageId,
        preferMailboxPath: preferMailboxPath,
      );

  @override
  Future<List<model.Email>> searchEmailsGlobal(
    String? accountId,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsGlobal(accountId, query, limit: limit);

  @override
  Future<List<model.Email>> searchEmailsStructured(
    String? accountId,
    FilterGroup filter, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsStructured(accountId, filter, limit: limit);

  @override
  Future<List<model.Email>> getEmailsByAddress(
    String? accountId,
    String address, {
    int? limit,
  }) =>
      _getEmailsByAddress(accountId, address, limit: limit);

  @override
  Future<List<model.EmailAddress>> searchAddresses(
    String? accountId,
    String query, {
    int limit = 10,
  }) =>
      _searchAddresses(accountId, query, limit: limit);

  @override
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmails(accountId, mailboxPath, query, limit: limit);

  @override
  Stream<List<model.Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) =>
      _observeEmailsInThread(accountId, mailboxPath, threadId);

  @override
  Stream<List<model.Email>> observeThreadAcrossFolders(
    String accountId,
    String threadId,
  ) =>
      _observeThreadAcrossFolders(accountId, threadId);

  // ── Bodies and attachments (email_repository_impl/bodies.dart) ─────────────

  @override
  Future<model.EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
    bool prefetch = false,
  }) =>
      _getEmailBody(emailId, forceRefresh: forceRefresh, prefetch: prefetch);

  @visibleForTesting
  (String? textBody, String? htmlBody, String attachmentsJson)
      parseJmapBodyForTest(Map<String, dynamic> m) => _parseJmapBodyForTest(m);

  @override
  Future<String> downloadAttachment(
    String emailId,
    model.EmailAttachment attachment,
  ) =>
      _downloadAttachment(emailId, attachment);

  @override
  Future<String> fetchRawRfc822(String emailId) => _fetchRawRfc822(emailId);

  // ── Sync (email_repository_impl/sync.dart) ─────────────────────────────────

  @override
  Future<model.SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) =>
      _syncEmails(accountId, mailboxPath);

  @override
  Future<void> clearForResync(String accountId) => _clearForResync(accountId);

  @override
  Future<void> clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) =>
      _clearMailboxForResync(accountId, mailboxPath);

  // ── IMAP sync (email_repository_impl/sync_imap.dart) ───────────────────────

  @override
  Future<model.ImapMailboxState?> lastImapMailboxState(
    String accountId,
    String mailboxPath,
  ) =>
      _lastImapMailboxState(accountId, mailboxPath);

  @visibleForTesting
  Future<void> reconcileDeletedImapForTest(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
  }) =>
      _reconcileDeletedImapForTest(
        accountId,
        mailboxPath,
        serverUids,
        serverMessageCount: serverMessageCount,
      );

  // ── JMAP push (email_repository_impl/jmap_push.dart) ───────────────────────

  @override
  Stream<void> watchJmapPush(String accountId, String password) =>
      _watchJmapPush(accountId, password);

  // ── Diagnostics (email_repository_impl/diagnostics.dart) ───────────────────

  @override
  Future<model.ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) =>
      _verifySyncReliability(accountId, mailboxPath);

  @override
  Future<model.MailboxDiagnostics> diagnoseMailbox(
    String accountId,
    String mailboxPath,
  ) =>
      _diagnoseMailbox(accountId, mailboxPath);

  // ── Pending-change queue (email_repository_impl/change_queue.dart) ─────────

  @override
  Future<(T, Map<String, List<int>>)> captureOps<T>(
    Future<T> Function() apply,
  ) =>
      _captureOps<T>(apply);

  @override
  Future<Set<int>> cancelOps(Iterable<int> ids) => _cancelOps(ids);

  @override
  Future<bool> cancelPendingChange(String emailId, String changeType) =>
      _cancelPendingChange(emailId, changeType);

  @override
  Stream<List<model.FailedMutation>> observeFailedMutations(String accountId) =>
      _observeFailedMutations(accountId);

  @override
  Future<void> discardMutation(int id) => _discardMutation(id);

  @override
  Future<void> retryMutation(int id) => _retryMutation(id);

  @override
  Stream<List<model.PendingChange>> observePendingChanges(String accountId) =>
      _observePendingChanges(accountId);

  @override
  Stream<List<model.PendingChange>> observeAllPendingChanges() =>
      _observeAllPendingChanges();

  // ── IMAP flush (email_repository_impl/flush_imap.dart) ─────────────────────

  @override
  Future<int> flushPendingChanges(String accountId, String password) =>
      _flushPendingChanges(accountId, password);

  // ── User actions (email_repository_impl/user_actions.dart) ─────────────────

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) =>
      _setFlag(emailId, seen: seen, flagged: flagged);

  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) =>
      _markAllAsRead(accountId, mailboxPath);

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) =>
      _moveEmail(emailId, destMailboxPath);

  @override
  Future<String?> deleteEmail(String emailId) => _deleteEmail(emailId);

  @override
  Future<String?> deleteEmails(List<String> emailIds) =>
      _deleteEmails(emailIds);

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) =>
      _snoozeEmail(emailId, until);

  @override
  Future<bool> isSnoozedMailbox(String accountId, String mailboxPath) async =>
      _isSnoozedPath(mailboxPath, await _snoozedMailboxPath(accountId));

  @override
  Future<int> wakeUpEmails(String accountId) =>
      _asAutomaticChange(() => _wakeUpEmails(accountId));

  @override
  Future<void> restoreLocalSnooze(
    String emailId, {
    required DateTime until,
    String? fromMailboxPath,
  }) =>
      _restoreLocalSnooze(
        emailId,
        until: until,
        fromMailboxPath: fromMailboxPath,
      );

  @override
  Future<void> restoreEmails(List<model.Email> emails) =>
      _restoreEmails(emails);

  // ── Counterparts (email_repository_impl/counterparts.dart) ─────────────────

  /// Matches row [realEmailId], just stored by sync, with a row waiting for
  /// its server copy (a virtual row, SYNC-REDESIGN.md §6).
  @visibleForTesting
  Future<void> matchArrivalForTest(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _matchArrivalForTest(
        accountId,
        arrivalMailboxPath,
        realEmailId,
        messageId,
      );

  // ── Sieve (email_repository_impl/sieve.dart) ───────────────────────────────

  @override
  Future<int> applySieveRules(String accountId) => _applySieveRules(accountId);

  @override
  Future<int> previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) =>
      _previewSieveRuleMatches(accountId, scriptContent);

  @override
  Future<int> applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) =>
      _applySieveScriptToInbox(accountId, scriptContent);

  // ── Sending (email_repository_impl/send.dart) ──────────────────────────────

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) =>
      _sendEmail(accountId, draft);

  @override
  Future<int> enqueueSend(String accountId, model.EmailDraft draft) =>
      _enqueueSend(accountId, draft);

  @override
  Future<int> flushOutbox(String accountId, String password) =>
      _flushOutbox(accountId, password);

  @override
  Future<SendNowResult> sendNow(String accountId, {int? outboxRowId}) =>
      _sendNow(accountId, outboxRowId: outboxRowId);
}
