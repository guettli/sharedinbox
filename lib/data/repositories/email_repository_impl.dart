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
import 'package:sharedinbox/data/repositories/mailbox_repository_impl.dart'
    show removeLocalMailbox;
import 'package:sharedinbox/data/repositories/outbox_repository_impl.dart';

typedef SmtpConnectFn = Future<imap.SmtpClient> Function(
  account_model.Account account,
  String username,
  String password,
);
typedef GetCacheDirFn = Future<Directory> Function();

/// Selects how [EmailRepositoryImpl._runSieveOverInbox] tallies matches.
///
/// * [anyMatch] counts any INBOX row where a rule's test fires, including
///   pure-`keep` matches with no visible effect. Used by the "preview" and
///   "apply to inbox now" flows so the count matches user intuition.
/// * [visibleEffect] counts only rows whose actions would move, discard or
///   flag the message. Used by the automatic sync-time apply so the number
///   reported matches the number of pending changes actually enqueued.
enum _SieveCountMode { anyMatch, visibleEffect }

/// The live server-side view of one mailbox gathered by
/// [EmailRepositoryImpl.diagnoseMailbox]: the server's own counts plus the
/// discrepancies against the local cache.
class _LiveMailboxCounts {
  const _LiveMailboxCounts({
    required this.serverTotal,
    required this.serverUnread,
    required this.serverMessageCount,
    required this.missingLocally,
    required this.missingOnServer,
  });

  final int? serverTotal;
  final int? serverUnread;
  final int serverMessageCount;
  final List<String> missingLocally;
  final List<String> missingOnServer;
}

class EmailRepositoryImpl implements EmailRepository {
  /// SQL `ORDER BY` of the mail search results (table alias `e`): starred
  /// first, then [model.compareNewestFirst]. Searches span folders and
  /// accounts, whose UIDs are not comparable; there the UID tiebreak only
  /// makes the order deterministic.
  static const _emailListOrderSql =
      'e.is_flagged DESC, e.received_at DESC, e.uid DESC, e.id DESC';

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
  })  : _db = db,
        _now = now,
        _imapConnect = imapConnect,
        _smtpConnect = smtpConnect,
        _getCacheDir = getCacheDir,
        _fetchObjectIds = fetchObjectIds,
        _fetchPreviewSnippets = fetchPreviewSnippets,
        _httpClient = httpClient ?? http.Client(),
        _outbox = outbox ?? OutboxRepositoryImpl(db),
        _appLogger = appLogger,
        _sendOperationTimeout = sendOperationTimeout;

  final AppDatabase _db;
  final AccountRepository _accounts;

  /// The clock for change leases; injectable for tests.
  final DateTime Function() _now;
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

  final _changeCtrl = StreamController<String>.broadcast();

  @override
  Stream<String> get onChangesQueued => _changeCtrl.stream;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  // ── Observe ────────────────────────────────────────────────────────────────

  @override
  Stream<List<model.Email>> observeEmails(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          // Mail from the same second: highest UID (newest arrival) first.
          // `id` makes rows with equal UIDs (JMAP, local) deterministic.
          // Matches the `emails_list_order` index.
          ..orderBy([
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Stream<List<model.EmailThread>> observeThreads(
    String accountId,
    String mailboxPath, {
    int limit = 50,
  }) {
    return (_db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          )
          // Matches the `threads_list_order` index; see [observeEmails] for
          // the tiebreakers.
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.latestDate),
            (t) => OrderingTerm.desc(t.latestUid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_threadRowToModel).toList());
  }

  @override
  Stream<List<model.EmailThread>> observeAllInboxThreads({int limit = 50}) {
    final query = _db.select(_db.threads).join([
      innerJoin(
        _db.mailboxes,
        _db.mailboxes.accountId.equalsExp(_db.threads.accountId) &
            _db.mailboxes.path.equalsExp(_db.threads.mailboxPath),
      ),
      // Pull the latest message's Message-ID so counterpart copies of the same
      // server message (IMAP + JMAP accounts on the same server) can be
      // collapsed to one row — see [_dedupeCounterpartThreads].
      leftOuterJoin(
        _db.emails,
        _db.emails.accountId.equalsExp(_db.threads.accountId) &
            _db.emails.id.equalsExp(_db.threads.latestEmailId),
      ),
    ]);
    query
      ..where(_db.mailboxes.role.equals('inbox'))
      ..orderBy([
        OrderingTerm.desc(_db.threads.isFlagged),
        OrderingTerm.desc(_db.threads.latestDate),
        // UIDs of different accounts are not comparable: across inboxes
        // this tiebreak only makes the order deterministic.
        OrderingTerm.desc(_db.threads.latestUid),
        OrderingTerm.desc(_db.threads.id),
      ])
      ..limit(limit);
    return query.watch().asyncMap((rows) async {
      final withMessageId = [
        for (final row in rows)
          (
            _threadRowToModel(row.readTable(_db.threads)),
            row.readTableOrNull(_db.emails)?.messageId,
          ),
      ];
      final accounts = await _accounts.observeAccounts().first;
      return _dedupeCounterpartThreads(withMessageId, accounts);
    });
  }

  /// Collapses threads that are the same server message reached through two
  /// counterpart accounts (one IMAP, one JMAP on the same server — see
  /// [AccountComparison]) down to a single row, so the combined inbox never
  /// shows the mail twice.
  ///
  /// [rows] pairs each inbox thread with the (raw) Message-ID of its latest
  /// message. Threads are only merged when their account has a counterpart and
  /// the normalised Message-IDs match; everything else passes through
  /// unchanged, so two genuinely-different accounts that happen to receive the
  /// same Message-ID both remain, as do threads with no Message-ID.
  ///
  /// The kept copy is deterministic (IMAP preferred, then lowest account id)
  /// and keeps its original list position, preserving the query's
  /// `isFlagged`/`latestDate`/`latestUid`/`id` ordering.
  List<model.EmailThread> _dedupeCounterpartThreads(
    List<(model.EmailThread, String?)> rows,
    List<account_model.Account> accounts,
  ) {
    final accountById = {for (final a in accounts) a.id: a};

    account_model.Account? preferred(
      account_model.Account? a,
      account_model.Account? b,
    ) {
      if (a == null) return b;
      if (b == null) return a;
      final aImap = a.type == account_model.AccountType.imap;
      final bImap = b.type == account_model.AccountType.imap;
      if (aImap != bImap) return aImap ? a : b;
      return a.id.compareTo(b.id) <= 0 ? a : b;
    }

    final result = <model.EmailThread>[];
    // dedupKey -> index into [result] of the currently-kept copy.
    final keptIndexByKey = <String, int>{};

    for (final (thread, rawMessageId) in rows) {
      final account = accountById[thread.accountId];
      final counterparts = account == null
          ? const <account_model.Account>[]
          : AccountComparison.counterpartsOf(account, accounts);
      final mid = normaliseMessageId(rawMessageId);

      if (account == null || counterparts.isEmpty || mid == null) {
        result.add(thread);
        continue;
      }

      // Stable per-group key: the lowest account id across the group.
      final groupIds = [account.id, for (final c in counterparts) c.id]..sort();
      final dedupKey = '${groupIds.first}\u0000$mid';

      final existingIndex = keptIndexByKey[dedupKey];
      if (existingIndex == null) {
        keptIndexByKey[dedupKey] = result.length;
        result.add(thread);
        continue;
      }

      // Already have a copy of this message — keep the preferred account's row
      // in the same position and drop the other.
      final existing = result[existingIndex];
      if (preferred(account, accountById[existing.accountId]) == account) {
        result[existingIndex] = thread;
      }
    }

    return result;
  }

  model.EmailThread _threadRowToModel(ThreadRow row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.EmailThread(
      threadId: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      subject: row.subject,
      latestDate: row.latestDate,
      messageCount: row.messageCount,
      hasUnread: row.hasUnread,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
      participants: parseAddresses(row.participantsJson),
      preview: row.preview,
      latestEmailId: row.latestEmailId,
      emailIds: List<String>.from(jsonDecode(row.emailIdsJson) as List),
    );
  }

  /// Recalculates and updates the [Threads] table for [threadId].
  /// Called after any change to the [Emails] table.
  Future<void> _updateThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) async {
    final threadEmails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.threadId.equals(threadId),
          )
          // Same key as `latestDate` below, so an undated message sorts by
          // its arrival time rather than first (SQLite orders NULL lowest).
          // Same-second mail by UID, so `latest` is the newest arrival.
          ..orderBy([
            (t) => OrderingTerm.asc(coalesce([t.sentAt, t.receivedAt])),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.uid),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .get();

    if (threadEmails.isEmpty) {
      await (_db.delete(_db.threads)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath) &
                  t.id.equals(threadId),
            ))
          .go();
      return;
    }

    if (threadEmails.isEmpty) return;
    final latest = threadEmails.last;

    // Collect unique participants across the whole thread.
    final seen = <String>{};
    final participants = <Map<String, dynamic>>[];
    for (final e in threadEmails) {
      final from = jsonDecode(e.fromJson) as List<dynamic>;
      for (final a in from.cast<Map<String, dynamic>>()) {
        final email = a['email'] as String;
        if (seen.add(email)) {
          participants.add({'name': a['name'], 'email': email});
        }
      }
    }

    await _db.into(_db.threads).insertOnConflictUpdate(
          ThreadsCompanion.insert(
            id: threadId,
            accountId: accountId,
            mailboxPath: mailboxPath,
            subject: Value(latest.subject),
            latestDate: latest.sentAt ?? latest.receivedAt,
            messageCount: Value(threadEmails.length),
            hasUnread: Value(threadEmails.any((e) => !e.isSeen)),
            isFlagged: Value(threadEmails.any((e) => e.isFlagged)),
            hasAttachment: Value(threadEmails.any((e) => e.hasAttachment)),
            participantsJson: Value(jsonEncode(participants)),
            preview: Value(latest.preview),
            latestEmailId: latest.id,
            latestUid: Value(latest.uid),
            emailIdsJson: Value(
              jsonEncode(threadEmails.map((e) => e.id).toList()),
            ),
          ),
        );
  }

  /// Recomputes the source-mailbox thread for an email that just left
  /// [mailboxPath], and sweeps any *other* thread rows in that mailbox that
  /// still list [emailId].
  ///
  /// A folder can accumulate stale thread rows whose `id` no longer matches any
  /// email's current `threadId` — e.g. when a thread-id derivation change
  /// (message-id / subject normalisation, see #418, #500) re-threads a message
  /// on resync and leaves the previous row behind. Moving every message out of
  /// such a folder must remove those orphans too, otherwise the folder keeps
  /// showing rows backed by no local mail (#498).
  Future<void> _reconcileSourceThreads(
    String accountId,
    String mailboxPath,
    String emailId,
    String currentThreadId,
  ) async {
    final referencing = await (_db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.emailIdsJson.like('%"$emailId"%'),
          ))
        .get();
    final threadIds = <String>{
      currentThreadId,
      for (final row in referencing) row.id,
    };
    for (final id in threadIds) {
      await _updateThread(accountId, mailboxPath, id);
    }
  }

  /// Deletes thread rows in [mailboxPath] that are backed by no email currently
  /// in that folder — orphans left when a message is re-threaded on resync
  /// (#418 / #500) or bulk-removed and [_updateThread] only rebuilt the
  /// *current* threadId, leaving the previous row behind. `observeThreads`
  /// renders every thread row for the folder, so these orphans surface as
  /// phantom conversations backed by no local mail (#523).
  ///
  /// [_reconcileSourceThreads] does the same sweep but only for the interactive
  /// move flows; this runs it over the whole folder at sync time (and on demand
  /// from the diagnostics screen). It only ever removes rows with **zero**
  /// backing emails, so it stays consistent with the `emails` table and is a
  /// no-op on a healthy folder. Returns the number of rows removed.
  Future<int> _sweepOrphanThreads(String accountId, String mailboxPath) async {
    final emails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();
    // Matches how every _updateThread call derives its key: `threadId ?? id`.
    final validIds = <String>{for (final e in emails) e.threadId ?? e.id};

    // A folder with no emails has no valid thread ids, so every row is an
    // orphan. `[""]` (a value thread ids never take) makes `id NOT IN (...)`
    // match every row while avoiding the ambiguous `id NOT IN ()`.
    final Iterable<String> keepIds = validIds.isEmpty ? const [''] : validIds;
    final removed = await (_db.delete(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.id.isNotIn(keepIds),
          ))
        .go();
    if (removed > 0) {
      log(
        'sweep-orphan-threads: mailbox=$mailboxPath removed=$removed orphan '
        'thread row(s) (emails=${emails.length})',
      );
    }
    return removed;
  }

  @override
  Future<int> sweepOrphanThreads(String accountId, String mailboxPath) =>
      _sweepOrphanThreads(accountId, mailboxPath);

  @override
  Future<model.Email?> getEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  // ── Body (on-demand) ───────────────────────────────────────────────────────

  static const _bodyCacheTtl = Duration(days: 7);

  /// [prefetch] marks a background prefetch (the opportunistic next-message
  /// load on open, or the [BodyCacheService] cache warmer) so its App Log
  /// entry is distinguishable from the foreground open the user triggered
  /// (#642). It is deliberately absent from the [EmailRepository] interface —
  /// only the concrete implementation needs it.
  @override
  Future<model.EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
    bool prefetch = false,
  }) async {
    final startedAt = DateTime.now();
    final cached = await (_db.select(
      _db.emailBodies,
    )..where((t) => t.emailId.equals(emailId)))
        .getSingleOrNull();
    if (cached != null && !forceRefresh) {
      // Re-fetch if cachedAt is null (legacy row) or older than the TTL.
      final age = cached.cachedAt == null
          ? _bodyCacheTtl + const Duration(seconds: 1)
          : DateTime.now().difference(cached.cachedAt!);
      // Also re-fetch when mimeTreeJson/headersJson are missing: such rows
      // were cached before the structure fetch existed (or before the server
      // returned bodyStructure). Without this, "Show Mail Structure" stays
      // empty for up to 7 days even after we start asking for it.
      final isMissingExtras =
          cached.mimeTreeJson == null || cached.headersJson == null;
      if (age <= _bodyCacheTtl && !isMissingExtras) {
        _logBodyLoaded(
          emailId: emailId,
          source: 'cache',
          network: false,
          prefetch: prefetch,
          cacheAgeSeconds: age.inSeconds,
        );
        final body = _bodyRowToModel(cached);
        await _backfillAddressHeaders(emailId, body.headers);
        return body;
      }
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    // Local self-sent "virtual" messages have no server copy to fetch — always
    // serve the cached body we wrote when the message was composed (#545).
    if (emailRow.isLocal) {
      _logBodyLoaded(
        emailId: emailId,
        accountId: emailRow.accountId,
        mailboxPath: emailRow.mailboxPath,
        source: 'local',
        network: false,
        prefetch: prefetch,
      );
      return cached != null
          ? _bodyRowToModel(cached)
          : const model.EmailBody(emailId: '', attachments: []);
    }
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      return _getEmailBodyJmap(
        emailId,
        account,
        password,
        prefetch: prefetch,
        startedAt: startedAt,
      );
    }

    return _withBodyImapClient(
      account,
      _effectiveUsername(account),
      password,
      (client) async {
        await client.selectUnicodeMailboxByPath(emailRow.mailboxPath);
        final fetch =
            await client.uidFetchMessage(emailRow.uid, '(BODY.PEEK[])');
        final msg = fetch.messages.firstOrNull;
        if (msg == null) {
          throw StateError(
            'IMAP server returned no message for UID ${emailRow.uid}.',
          );
        }

        // Guard against caching another message's body under this row (#616). An
        // optimistic snooze/unsnooze/move flips mailbox_path to the destination
        // but keeps the source UID until the server MOVE is remapped (see
        // [_remapEmailAfterImapMove]). If that remap never lands and the stale
        // source UID happens to also exist in the destination mailbox, this
        // (mailboxPath, uid) pair now points at an unrelated message — the fetch
        // above would silently return it. Never trust a body whose Message-ID
        // contradicts the row's; try to re-resolve the real UID instead.
        final expectedMessageId = normaliseMessageId(emailRow.messageId);
        final fetchedMessageId =
            normaliseMessageId(msg.getHeaderValue('Message-ID'));
        if (expectedMessageId != null &&
            fetchedMessageId != null &&
            expectedMessageId != fetchedMessageId) {
          // The pooled client is held until this future completes, so the
          // re-resolve search below still runs on an open connection.
          return _healMismatchedImapBody(
            client: client,
            emailId: emailId,
            emailRow: emailRow,
            cached: cached,
            expectedMessageId: expectedMessageId,
            fetchedMessageId: fetchedMessageId,
          );
        }
        // Decoding a malformed MIME message can make enough_mail throw — e.g. a
        // `RangeError (end)` on an off-by-a-few-bytes part boundary (#579), the
        // same class of bug already guarded against on the prefetch path (#232).
        // Decode each piece defensively so one bad part can't blank the whole
        // message: salvage what we can, flag the body as partial, and log so the
        // failure is discoverable in the per-message "Show Logs" view.
        var decodeFailed = false;
        Object? decodeError;
        StackTrace? decodeStack;
        T? tryDecode<T>(T Function() decode) {
          try {
            return decode();
          } catch (e, stack) {
            decodeFailed = true;
            decodeError ??= e;
            decodeStack ??= stack;
            return null;
          }
        }

        // Use the QP-recovering wrappers (#588): enough_mail throws a RangeError
        // on a quoted-printable part that ends with a dangling `=`, which would
        // otherwise drop the whole part; the wrappers salvage the content when
        // they can and only rethrow — letting tryDecode flag the body as
        // partial — when the part is genuinely unrecoverable.
        final textBody = tryDecode(() => decodeTextPlainPartSafe(msg));
        final rawHtml = tryDecode(() => decodeTextHtmlPartSafe(msg));
        final htmlBody = rawHtml == null
            ? null
            : tryDecode(() => injectInlineImages(rawHtml, msg));
        final contentInfos =
            tryDecode(msg.findContentInfo) ?? const <imap.ContentInfo>[];

        final attachmentsJson = tryDecode(
              () => jsonEncode(
                contentInfos
                    .map(
                      (a) => {
                        'filename': mimePartFileName(
                              a.contentDisposition,
                              a.contentType,
                            ) ??
                            '',
                        'contentType': a.contentType?.mediaType.text ?? '',
                        // ContentInfo.fetchId is empty for parts that aren't
                        // addressable (e.g. a non-multipart message whose
                        // top-level part is itself marked as an attachment).
                        // MimeMessage.getPart() throws on an empty fetchId, so
                        // guard before calling it.
                        'size': a.size ??
                            (a.fetchId.isNotEmpty
                                ? msg
                                    .getPart(a.fetchId)
                                    ?.decodeContentBinary()
                                    ?.length
                                : null) ??
                            0,
                        'fetchPartId': a.fetchId,
                      },
                    )
                    .toList(),
              ),
            ) ??
            '[]';

        final headersJson = tryDecode(
              () => jsonEncode(
                (msg.headers ?? [])
                    .map((h) => {'name': h.name, 'value': h.value})
                    .toList(),
              ),
            ) ??
            '[]';

        final mimeTreeJson = tryDecode(() => _buildMimeTreeJson(msg));

        if (decodeFailed) {
          unawaited(
            _appLogger?.error(
              'email.body.decode_failed',
              'Could not fully decode message body — showing what was salvaged',
              accountId: emailRow.accountId,
              mailboxPath: emailRow.mailboxPath,
              emailId: emailId,
              error: decodeError,
              stack: decodeStack,
            ),
          );
        }

        await _cacheFetchedBody(
          emailId: emailId,
          textBody: textBody,
          htmlBody: htmlBody,
          attachmentsJson: attachmentsJson,
          headersJson: headersJson,
          mimeTreeJson: mimeTreeJson,
        );

        // Opportunistic backfill for rows synced before we started writing
        // previews on the IMAP sync path. Costs no extra IMAP round trip.
        if ((emailRow.preview ?? '').isEmpty) {
          final backfill = previewFromBody(textBody, rawHtml);
          if (backfill != null && backfill.isNotEmpty) {
            await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
                .write(EmailsCompanion(preview: Value(backfill)));
            await _updateThread(
              emailRow.accountId,
              emailRow.mailboxPath,
              emailRow.threadId ?? emailRow.id,
            );
          }
        }

        // Same opportunistic backfill for the List-Unsubscribe header (#698).
        // The full message fetched above carries every header, so a row synced
        // before we captured this field — or one where sync missed it — gets its
        // Unsubscribe button as soon as the user opens the mail, without a full
        // account resync. Costs no extra IMAP round trip.
        if ((emailRow.listUnsubscribeHeader ?? '').isEmpty) {
          final listUnsubscribe =
              msg.getHeaderValue('List-Unsubscribe')?.trim();
          if (listUnsubscribe != null && listUnsubscribe.isNotEmpty) {
            await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
                .write(
              EmailsCompanion(listUnsubscribeHeader: Value(listUnsubscribe)),
            );
          }
        }

        // Same opportunistic backfill for Reply-To and Bcc.
        await _backfillAddressHeaders(
          emailId,
          _parseHeaders(headersJson),
          row: emailRow,
        );

        _logBodyLoaded(
          emailId: emailId,
          accountId: emailRow.accountId,
          mailboxPath: emailRow.mailboxPath,
          source: 'imap',
          network: true,
          prefetch: prefetch,
          bytes: _bodySize(textBody, htmlBody),
          durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        );

        return model.EmailBody(
          emailId: emailId,
          textBody: textBody,
          htmlBody: htmlBody,
          attachments: _parseAttachments(attachmentsJson),
          headers: _parseHeaders(headersJson),
          mimeTree: _parseMimeTree(mimeTreeJson),
          decodeFailed: decodeFailed,
        );
      },
    );
  }

  // ── Pooled IMAP connection for body fetches (#679) ───────────────────────
  //
  // getEmailBody used to connect and log in once per message. Gmail throttles
  // rapid logins, so anything that walks a mailbox — the background prefetch in
  // BodyCacheService, the "open the next message" prefetch, the read-only Gmail
  // probe — eventually stalls inside LOGIN until the 20s response timeout
  // fires. Keeping one connection open between fetches removes the login (and
  // the TLS handshake) from every message but the first.
  //
  // Only one fetch may hold the pooled client at a time: an ImapClient cannot
  // interleave commands. A fetch that arrives while it is busy opens its own
  // connection rather than queueing, so opening a message never waits behind a
  // background prefetch.

  /// How long the pooled connection is kept open after the last body fetch.
  static const _bodyClientIdle = Duration(seconds: 30);

  imap.ImapClient? _bodyClient;
  String? _bodyClientAccountId;
  bool _bodyClientBusy = false;
  Timer? _bodyClientIdleTimer;

  /// Runs [action] against an IMAP connection for [account], reusing the pooled
  /// one when it is free and belongs to the same account.
  Future<T> _withBodyImapClient<T>(
    account_model.Account account,
    String username,
    String password,
    Future<T> Function(imap.ImapClient client) action,
  ) async {
    if (_bodyClientBusy) {
      final client = await _imapConnect(account, username, password);
      try {
        return await action(client);
      } finally {
        await _logoutQuietly(client);
      }
    }

    _bodyClientBusy = true;
    _bodyClientIdleTimer?.cancel();
    try {
      final reused = _bodyClient != null && _bodyClientAccountId == account.id;
      if (!reused) {
        await _closePooledBodyClient();
        _bodyClient = await _imapConnect(account, username, password);
        _bodyClientAccountId = account.id;
      }
      try {
        return await action(_bodyClient!);
      } catch (e) {
        if (!reused) rethrow;
        // A pooled connection can have been dropped while it sat idle. Retry
        // once on a fresh one: the reuse is an optimisation and must never turn
        // a working fetch into a failure.
        log('IMAP: pooled body connection failed ($e) — reconnecting');
        await _closePooledBodyClient();
        _bodyClient = await _imapConnect(account, username, password);
        _bodyClientAccountId = account.id;
        return await action(_bodyClient!);
      }
    } finally {
      _bodyClientBusy = false;
      _armBodyClientIdleTimer();
    }
  }

  void _armBodyClientIdleTimer() {
    _bodyClientIdleTimer?.cancel();
    _bodyClientIdleTimer = null;
    if (_bodyClient == null) return;
    _bodyClientIdleTimer = Timer(
      _bodyClientIdle,
      () => unawaited(_closePooledBodyClient()),
    );
  }

  Future<void> _closePooledBodyClient() async {
    _bodyClientIdleTimer?.cancel();
    _bodyClientIdleTimer = null;
    final client = _bodyClient;
    _bodyClient = null;
    _bodyClientAccountId = null;
    if (client != null) await _logoutQuietly(client);
  }

  Future<void> _logoutQuietly(imap.ImapClient client) =>
      closeImapClient(client);

  /// Closes the pooled body-fetch connection and cancels its idle timer.
  ///
  /// Call this when a repository instance is done with (e.g. the one
  /// BodyCacheService builds per run) so the connection is not held until the
  /// idle timer fires. Safe to call more than once.
  Future<void> dispose() => _closePooledBodyClient();

  /// Handles the case where a body fetch returned a message whose Message-ID
  /// contradicts the local row's (#616): the row's (mailboxPath, uid) no longer
  /// identifies the intended message. Tries to re-resolve the true UID by
  /// Message-ID in the same mailbox; on success it re-keys the row and re-fetches
  /// under the corrected identity. When the message can't be found the stale
  /// (mailbox, uid) identity is invalid — we never cache the wrong body and
  /// return whatever we can without corrupting the cache.
  Future<model.EmailBody> _healMismatchedImapBody({
    required imap.ImapClient client,
    required String emailId,
    required Email emailRow,
    required EmailBody? cached,
    required String expectedMessageId,
    required String fetchedMessageId,
  }) async {
    final resolvedUid = await _searchUidByMessageId(
      client,
      emailRow.mailboxPath,
      emailRow.messageId,
    );
    if (resolvedUid != null && resolvedUid != emailRow.uid) {
      final newId =
          '${emailRow.accountId}:${emailRow.mailboxPath}:$resolvedUid';
      await _rekeyEmailRow(
        oldId: emailId,
        newId: newId,
        newUid: resolvedUid,
        newMailboxPath: emailRow.mailboxPath,
      );
      log(
        'getEmailBody: re-keyed mis-bound row $emailId → $newId after '
        'Message-ID mismatch (expected=$expectedMessageId, '
        'fetched=$fetchedMessageId)',
      );
      // forceRefresh bypasses the (now re-keyed, possibly stale) cache and
      // re-verifies identity under the corrected UID.
      return getEmailBody(newId, forceRefresh: true);
    }

    unawaited(
      _appLogger?.error(
        'email.body.identity_mismatch',
        'Skipped caching a body whose Message-ID did not match this message '
            '(expected $expectedMessageId, server returned $fetchedMessageId '
            'for UID ${emailRow.uid} in ${emailRow.mailboxPath}). The message '
            'is not at that UID; the correct copy will be re-fetched on sync.',
        accountId: emailRow.accountId,
        mailboxPath: emailRow.mailboxPath,
        emailId: emailId,
      ),
    );
    // The row's (mailbox, uid) no longer identifies this message, so we have no
    // trustworthy body to show. Flag the load failure so the detail screen can
    // tell the user instead of leaving a silently blank body (#837): serve the
    // cache only when it belongs to this same message, otherwise an empty body.
    const loadError =
        'This message is no longer at its previous location. It will be '
        're-fetched on the next sync.';
    if (cached != null) {
      return _bodyRowToModel(cached).copyWith(loadError: loadError);
    }
    return model.EmailBody(
      emailId: emailId,
      attachments: const [],
      loadError: loadError,
    );
  }

  /// Caches a body just fetched from the server. The fetch can outlast the
  /// email row (a sync pruned it, the user deleted it); its body is then
  /// still shown once, but there is nothing left to cache it for.
  Future<void> _cacheFetchedBody({
    required String emailId,
    required String? textBody,
    required String? htmlBody,
    required String attachmentsJson,
    required String? headersJson,
    required String? mimeTreeJson,
  }) async {
    try {
      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(textBody),
              htmlBody: Value(htmlBody),
              attachmentsJson: Value(attachmentsJson),
              headersJson: Value(headersJson),
              mimeTreeJson: Value(mimeTreeJson),
              cachedAt: Value(DateTime.now()),
              bodySize: Value(_bodySize(textBody, htmlBody)),
            ),
          );
    } catch (e) {
      if (!isForeignKeyViolation(e)) rethrow;
    }
  }

  /// Rewrites a local email row's identity (`id`, `uid`, `mailboxPath`) and all
  /// references that embed the old id — the cached body, pending changes,
  /// per-message logs, thread aggregates and undo history — in one transaction.
  /// Shared by [_remapEmailAfterImapMove] and the body-fetch identity guard.
  Future<void> _rekeyEmailRow({
    required String oldId,
    required String newId,
    required int newUid,
    required String newMailboxPath,
    bool keepShownWhileMovedOn = false,
    bool mergeDuplicate = false,
  }) async {
    if (newId == oldId) return;
    await _db.transaction(() async {
      final oldRow = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(oldId)))
          .getSingleOrNull();
      final oldUid = oldRow?.uid;
      // Sync already fetched the mail at its new place (its MOVE's answer
      // came after the destination's sync, or another client moved it there
      // first): that row is a second row of the same mail. Drop it and keep
      // this one, which carries the user's changes and local state; its body
      // and attachments go with it. Not with [mergeDuplicate] false: the
      // UID was found by Message-ID while a copy with that Message-ID is
      // still in the source, so it may be another copy (cross-posted mail).
      final existing = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(newId)))
          .getSingleOrNull();
      if (mergeDuplicate &&
          existing != null &&
          oldRow != null &&
          existing.messageId != null &&
          existing.messageId == oldRow.messageId) {
        log('Re-key $oldId → $newId: dropping the copy sync already fetched');
        await (_db.delete(_db.emails)..where((t) => t.id.equals(newId))).go();
        // The kept row has this app's view of the flags, the dropped one the
        // server's: read them again.
        await _makeFlagReconcileDue(
          oldRow.accountId,
          newMailboxPath,
          jmap: false,
        );
        await _updateThread(
          existing.accountId,
          existing.mailboxPath,
          existing.threadId ?? existing.id,
        );
      }
      // After a move: when a later move, snooze or unsnooze of the mail is
      // still queued (it starts in this move's destination), the row
      // already shows the mail where that one puts it and keeps doing so;
      // only its identity follows the server (#1276). Read in this
      // transaction, so an Undo or another move made meanwhile is kept.
      var movedOn = false;
      if (keepShownWhileMovedOn) {
        final queued = await (_db.select(_db.pendingChanges)
              ..where(
                (t) =>
                    t.resourceId.isIn([oldId, newId]) &
                    t.state.isIn(_liveStates) &
                    t.changeType.isIn(_locationChangeTypes),
              ))
            .get();
        movedOn = queued.any((c) {
          final p = _decodePayload(c);
          return (p?['mailboxPath'] ?? p?['src']) == newMailboxPath;
        });
      }
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');

      await _db.customStatement(
        'UPDATE email_bodies SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );
      // The downloaded files live in a folder named after the old id, so
      // their rows cannot follow; keeping them would break the foreign key
      // at COMMIT. The attachment is downloaded again when opened.
      await (_db.delete(_db.attachmentFiles)
            ..where((t) => t.emailId.equals(oldId)))
          .go();

      await (_db.update(_db.emails)..where((t) => t.id.equals(oldId))).write(
        EmailsCompanion(
          id: Value(newId),
          uid: Value(newUid),
          mailboxPath: movedOn ? const Value.absent() : Value(newMailboxPath),
        ),
      );

      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldId)))
          .write(PendingChangesCompanion(resourceId: Value(newId)));
      await _rewritePendingChangeUids(
        resourceId: newId,
        mailboxPath: newMailboxPath,
        newUid: newUid,
        oldUid: oldUid,
      );

      // app_logs.emailId references emails.id with onDelete:setNull but no
      // onUpdate action, so re-point the per-message logs by hand — otherwise
      // "Show Logs" would come up empty after a re-key. See #562.
      await _db.customStatement(
        'UPDATE app_logs SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );

      // threads.latest_email_id is a plain equality match; threads.email_ids_json
      // is a JSON array of email IDs — both are safe to update via REPLACE()
      // because email IDs are unique opaque strings. latest_uid follows the
      // latest email's UID, the thread list's same-second tiebreaker.
      await _db.customStatement(
        'UPDATE threads SET latest_email_id = ?1, latest_uid = ?3 '
        'WHERE latest_email_id = ?2',
        [newId, oldId, newUid],
      );
      await _db.customStatement(
        'UPDATE threads SET email_ids_json = '
        'REPLACE(email_ids_json, ?1, ?2) '
        'WHERE email_ids_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );

      // UndoAction.toJson() embeds email IDs as quoted JSON strings in both
      // emailIds and originalEmails[].id, so the same REPLACE() works.
      await _db.customStatement(
        'UPDATE undo_actions SET data_json = '
        'REPLACE(data_json, ?1, ?2) '
        'WHERE data_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );
    });
  }

  /// Points the IMAP payloads of [resourceId]'s queued changes that address
  /// the message in [mailboxPath] at its new [newUid]. Changes queued after an
  /// optimistic move (e.g. Undo's reverse move Trash→INBOX) still carry the
  /// pre-move UID, which does not exist in the destination mailbox: the server
  /// would accept the `UID MOVE` as a no-op and the change would be lost
  /// (#1048).
  Future<void> _rewritePendingChangeUids({
    required String resourceId,
    required String mailboxPath,
    required int newUid,
    int? oldUid,
  }) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where((t) => t.resourceId.equals(resourceId)))
        .get();
    for (final row in rows) {
      final Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row.payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      if (payload['uid'] is! int) continue;
      if (payload['uid'] == newUid && payload[_uidAfterMoveKey] == null) {
        continue;
      }
      if ((payload['mailboxPath'] ?? payload['src']) != mailboxPath) {
        // Queued behind a later move that is not answered yet: it stays
        // marked, but carries the mail's current UID, as one queued now
        // would. Undoing or failing that move points it back here by
        // this UID (`_unmarkAfterCancelledMove`,
        // `_pointLaterChangesAtSource`); before, it kept a UID from two
        // folders back and named whichever mail has it here (#1276).
        if (payload[_uidAfterMoveKey] == true &&
            oldUid != null &&
            payload['uid'] == oldUid) {
          payload['uid'] = newUid;
          await (_db.update(_db.pendingChanges)
                ..where((t) => t.id.equals(row.id)))
              .write(
            PendingChangesCompanion(payload: Value(jsonEncode(payload))),
          );
        }
        continue;
      }
      payload['uid'] = newUid;
      payload.remove(_uidAfterMoveKey);
      // The new UID was learned under the folder's current UIDVALIDITY.
      payload.remove('uidValidity');
      final checkpoint =
          await _loadImapCheckpoint(row.accountId, 'IMAP:$mailboxPath');
      if (checkpoint?['uidValidity'] case final int validity
          when validity != 0) {
        payload['uidValidity'] = validity;
      }
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
    }
  }

  Future<model.EmailBody> _getEmailBodyJmap(
    String emailId,
    account_model.Account account,
    String password, {
    bool prefetch = false,
    DateTime? startedAt,
  }) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final jmapEmailId = emailId.contains(':')
        ? emailId.substring(emailId.indexOf(':') + 1)
        : emailId;

    final responses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapEmailId],
          'properties': [
            'id',
            'headers',
            'textBody',
            'htmlBody',
            'bodyValues',
            'attachments',
            'bodyStructure',
          ],
          'fetchHTMLBodyValues': true,
          'fetchTextBodyValues': true,
          // `blobId` is required to download attachments: it is the id passed
          // to the JMAP downloadUrl. A spec-compliant server returns only the
          // body properties listed here (RFC 8621 §4.1.4), so omitting it left
          // every attachment with an empty part id and the download failed with
          // "missing part ID" (#762).
          'bodyProperties': [
            'partId',
            'blobId',
            'type',
            'name',
            'size',
            'subParts',
          ],
        },
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Email/get');
    final emailData =
        (result['list'] as List<dynamic>).first as Map<String, dynamic>;

    // Decode each piece defensively so a single malformed part can't blank the
    // whole message, mirroring the IMAP path (#579).
    var decodeFailed = false;
    Object? decodeError;
    StackTrace? decodeStack;
    T? tryDecode<T>(T Function() decode) {
      try {
        return decode();
      } catch (e, stack) {
        decodeFailed = true;
        decodeError ??= e;
        decodeStack ??= stack;
        return null;
      }
    }

    final (textBody, htmlBody, attachmentsJson) =
        tryDecode(() => _parseJmapBody(emailData)) ?? (null, null, '[]');

    final headersJson = tryDecode(
          () {
            final rawHeaders = emailData['headers'] as List<dynamic>? ?? [];
            return jsonEncode(
              rawHeaders.map((h) {
                final map = h as Map<String, dynamic>;
                return {
                  'name': map['name'] ?? '',
                  'value': map['value'] ?? '',
                };
              }).toList(),
            );
          },
        ) ??
        '[]';

    final mimeTreeJson = tryDecode(() {
      final rawBodyStructure =
          emailData['bodyStructure'] as Map<String, dynamic>?;
      return rawBodyStructure != null
          ? jsonEncode(_jmapBodyStructureToJson(rawBodyStructure))
          : null;
    });

    if (decodeFailed) {
      unawaited(
        _appLogger?.error(
          'email.body.decode_failed',
          'Could not fully decode message body — showing what was salvaged',
          accountId: account.id,
          emailId: emailId,
          error: decodeError,
          stack: decodeStack,
        ),
      );
    }

    await _cacheFetchedBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachmentsJson: attachmentsJson,
      headersJson: headersJson,
      mimeTreeJson: mimeTreeJson,
    );

    await _backfillAddressHeaders(emailId, _parseHeaders(headersJson));

    _logBodyLoaded(
      emailId: emailId,
      accountId: account.id,
      source: 'jmap',
      network: true,
      prefetch: prefetch,
      bytes: _bodySize(textBody, htmlBody),
      durationMs: startedAt == null
          ? null
          : DateTime.now().difference(startedAt).inMilliseconds,
    );

    return model.EmailBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: _parseAttachments(attachmentsJson),
      headers: _parseHeaders(headersJson),
      mimeTree: _parseMimeTree(mimeTreeJson),
      decodeFailed: decodeFailed,
    );
  }

  // ── Sync ───────────────────────────────────────────────────────────────────

  @override
  Future<model.SyncEmailsResult> syncEmails(
    String accountId,
    String mailboxPath,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _syncEmailsImap(account, password, mailboxPath);
      case account_model.AccountType.jmap:
        return _syncEmailsJmap(account, password, mailboxPath);
    }
  }

  @override
  Future<model.ImapMailboxState?> lastImapMailboxState(
    String accountId,
    String mailboxPath,
  ) async {
    final checkpoint =
        await _loadImapCheckpoint(accountId, 'IMAP:$mailboxPath');
    if (checkpoint == null) return null;
    return model.ImapMailboxState(
      uidNext: checkpoint['uidNext'] as int?,
      exists: checkpoint['exists'] as int?,
      highestModSeq: checkpoint['highestModSeq'] as int?,
    );
  }

  Future<model.SyncEmailsResult> _syncEmailsImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      // Only request CONDSTORE if the server advertises it. Servers that don't
      // support the extension may reject SELECT with (CONDSTORE) with BAD.
      final supportsCondStore = client.serverInfo.supports('CONDSTORE') ||
          client.serverInfo.supports('QRESYNC');
      final imap.Mailbox selectedMailbox;
      try {
        selectedMailbox = await client.selectUnicodeMailboxByPath(
          mailboxPath,
          enableCondStore: supportsCondStore,
        );
      } catch (e) {
        if (isImapMailboxNotFound(e)) {
          // The folder was deleted on the server between mailbox-sync and
          // email-sync of this cycle. Drop the local cache so subsequent
          // syncs don't keep retrying the same SELECT.
          log(
            'IMAP SELECT failed for "$mailboxPath" (folder deleted on '
            'server) — pruning local cache: $e',
          );
          await removeLocalMailbox(
            _db,
            account.id,
            mailboxPath,
            appLogger: _appLogger,
          );
          return model.SyncEmailsResult.zero;
        }
        rethrow;
      }
      final uidValidity = selectedMailbox.uidValidity ?? 0;
      final serverModSeq = selectedMailbox.highestModSequence;
      final resourceType = 'IMAP:$mailboxPath';
      final checkpoint = await _loadImapCheckpoint(account.id, resourceType);
      // Move-stable server id source (RFC 8474 EMAILID / Gmail X-GM-MSGID),
      // null when the server advertises neither (#589).
      final objectIdKind = resolveObjectIdKind(client.serverInfo);

      if (checkpoint == null || checkpoint['uidValidity'] != uidValidity) {
        // First run or UID validity changed — full sync.
        if (checkpoint != null) {
          // UID validity changed: remove stale local emails for this mailbox.
          await (_db.delete(_db.emails)
                ..where(
                  (t) =>
                      t.accountId.equals(account.id) &
                      t.mailboxPath.equals(mailboxPath),
                ))
              .go();
        }
        // Use UID SEARCH ALL + UID FETCH so every message gets a reliable UID.
        // Regular FETCH 1:* may not populate msg.uid on all servers.
        final allUids = (await client.uidSearchMessages(
              searchCriteria: 'ALL',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        var bytes = 0;
        if (allUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(allUids, isUid: true),
            objectIdKind: objectIdKind,
            uidValidity: selectedMailbox.uidValidity,
          );
        }
        final maxUid = allUids.isEmpty ? 0 : allUids.reduce(math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
          uidNext: selectedMailbox.uidNext,
          exists: selectedMailbox.messagesExists,
        );
        // Record that we've just fetched every flag so the periodic reconcile
        // in _maybeReconcileImapFlagsMailbox doesn't repeat it immediately.
        await _saveSyncState(
          account.id,
          'IMAP:FlagReconcile:$mailboxPath',
          DateTime.now().toIso8601String(),
        );
        await _sweepOrphanThreads(account.id, mailboxPath);
        return model.SyncEmailsResult(
          fetched: allUids.length,
          skipped: 0,
          bytesTransferred: bytes,
        );
      } else {
        // Incremental sync.
        final lastUid = checkpoint['lastUid'] as int;
        final storedModSeq = checkpoint['highestModSeq'] as int?;

        // Always search for new messages by UID. We intentionally do NOT use
        // CONDSTORE as a "skip everything" fast-path here because some servers
        // (including Stalwart 0.14.x) do not increment HIGHESTMODSEQ when new
        // mail is delivered via SMTP, causing newly arrived messages to be
        // silently missed when modseq values appear equal.
        // RFC 3501 §6.4.4 reads `n:*` as `*:n` when n is past the largest
        // UID, so with nothing new this still matches the newest message.
        // Without the filter every sync fetched that message again and
        // reported it as "1 new".
        final newUids = ((await client.uidSearchMessages(
                  searchCriteria: 'UID ${lastUid + 1}:*',
                ))
                    .matchingSequence
                    ?.toList() ??
                [])
            .where((uid) => uid > lastUid)
            .toList();
        var bytes = 0;
        if (newUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(newUids, isUid: true),
            objectIdKind: objectIdKind,
            uidValidity: selectedMailbox.uidValidity,
          );
        }

        // CONDSTORE flag update: refresh flags only when something changed.
        if (serverModSeq != null &&
            storedModSeq != null &&
            serverModSeq != storedModSeq) {
          await _refreshFlagsImap(client, account, mailboxPath, storedModSeq);
        }

        // Belt-and-braces: periodically re-fetch every FLAGS in the mailbox
        // and rewrite `isSeen`/`isFlagged` from server truth. Catches drift
        // when CONDSTORE misreports — Stalwart 0.14.x does not always bump
        // HIGHESTMODSEQ when a flag is toggled via JMAP on the same account,
        // so IMAP would otherwise never see the change (#407).
        await _maybeReconcileImapFlagsMailbox(client, account.id, mailboxPath);

        // Detect remote deletions.
        final serverUids = (await client.uidSearchMessages(
              searchCriteria: 'ALL',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        await _reconcileDeletedImap(
          account.id,
          mailboxPath,
          serverUids,
          serverMessageCount: selectedMailbox.messagesExists,
        );
        // Advance only past what was searched for and fetched above. Mail
        // that arrived after that search already shows up in [serverUids];
        // taking their maximum skipped it for good, since the next search
        // starts after the checkpoint. This relies on every UID in [newUids]
        // having been fetched above; if that fetch is ever capped or
        // chunked, advance only to the highest UID actually fetched.
        final maxUid = newUids.fold(lastUid, math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
          uidNext: selectedMailbox.uidNext,
          exists: selectedMailbox.messagesExists,
        );
        await _sweepOrphanThreads(account.id, mailboxPath);
        return model.SyncEmailsResult(
          fetched: newUids.length,
          skipped: serverUids.length - newUids.length,
          bytesTransferred: bytes,
        );
      }
    } finally {
      await closeImapClient(client);
    }
  }

  /// Resource ids on [accountId] with an unflushed optimistic mutation still
  /// queued in `pendingChanges` — used to protect a local edit from being
  /// reverted by a server-truth flag refresh before it has been pushed. The
  /// `flag_flagged` / `flag_seen` change a mail-to-self dissolve queues when it
  /// carries the star onto the real message lives here until it flushes (#565).
  /// A failed change protects nothing: server truth wins again.
  Future<Set<String>> _inFlightFlagResourceIds(String accountId) async {
    final ids = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.state.isIn(_liveStates) &
                _db.pendingChanges.changeType.isIn(
                  const [
                    'flag_seen',
                    'flag_flagged',
                    'move',
                    'snooze',
                    'unsnooze',
                    'clear_snooze',
                    'delete',
                  ],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    return ids.toSet();
  }

  /// Bumped, synchronously, when [_enqueueChange] starts and again once its
  /// row is queued; [_localEditSeqById] remembers the value
  /// per email while a server flag read is running. Together with
  /// [_ServerFlagRead] this closes the window a `pendingChanges` lookup alone
  /// leaves open: an edit queued *and already flushed* while the server's
  /// answer was on its way is no longer in `pendingChanges`, yet that answer
  /// predates it and would write the old read/star state back.
  ///
  /// In memory, so per isolate: a background (WorkManager) sync in another
  /// isolate does not see the UI's edits and relies on the queue check alone.
  int _localEditSeq = 0;
  final Map<String, int> _localEditSeqById = {};
  int _activeServerFlagReads = 0;

  void _noteLocalEdit(String emailId) {
    _localEditSeq++;
    // With no read running, any later read starts at or above this value.
    if (_activeServerFlagReads == 0) return;
    _localEditSeqById[emailId] = _localEditSeq;
  }

  /// Call right before asking the server for flags, and
  /// [_endServerFlagRead] when done with its answer (use try/finally).
  Future<_ServerFlagRead> _startServerFlagRead(String accountId) async {
    _activeServerFlagReads++;
    // Taken before the await: an edit landing during the lookup is caught by
    // the sequence instead.
    final seq = _localEditSeq;
    try {
      return _ServerFlagRead(
        seq,
        _localEditSeqById,
        await _inFlightFlagResourceIds(accountId),
      );
    } catch (_) {
      _endServerFlagRead();
      rethrow;
    }
  }

  void _endServerFlagRead() {
    _activeServerFlagReads--;
    // No read can still need the per-email sequence; keep the map small.
    if (_activeServerFlagReads == 0) _localEditSeqById.clear();
  }

  /// Fetches FLAGS for all messages modified since [sinceModSeq] and updates
  /// the local DB. Only messages whose modseq is > [sinceModSeq] are returned
  /// by the server (RFC 7162 §3.2). Skips rows with an unflushed optimistic
  /// flag edit still queued in `pendingChanges`, so a newly delivered message
  /// whose star the dissolve just carried over is not reverted to server truth
  /// within the same sync (#565).
  Future<void> _refreshFlagsImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    int sinceModSeq,
  ) async {
    final flagRead = await _startServerFlagRead(account.id);
    try {
      final result = await client.uidFetchMessages(
        imap.MessageSequence.fromAll(),
        'FLAGS',
        changedSinceModSequence: sinceModSeq,
      );
      // One transaction, and only rows whose flags really changed: a modseq
      // bump is not always a Seen/Flagged change, and CHANGEDSINCE can return
      // thousands of messages after a long time offline.
      await _db.transaction(() async {
        // Read inside the transaction: a local edit's queue insert and
        // optimistic write wait for it, so none can slip in between.
        final queuedNow = await _inFlightFlagResourceIds(account.id);
        final affectedThreads = <String>{};
        for (final msg in result.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final emailId = '${account.id}:$mailboxPath:$uid';
          final row = await (_db.select(_db.emails)
                ..where((t) => t.id.equals(emailId)))
              .getSingleOrNull();
          if (row == null) continue;
          final seen = msg.flags?.contains(r'\Seen') ?? false;
          final flagged = msg.flags?.contains(r'\Flagged') ?? false;
          if (row.isSeen == seen && row.isFlagged == flagged) continue;
          if (flagRead.protects(emailId, queuedNow)) continue;
          await (_db.update(_db.emails)..where((t) => t.id.equals(emailId)))
              .write(
            EmailsCompanion(isSeen: Value(seen), isFlagged: Value(flagged)),
          );
          affectedThreads.add(row.threadId ?? row.id);
        }
        // The message list reads unread/starred state from the thread row, so
        // a mail read, unread, starred or unstarred on another device kept its
        // old look here although its own row was already up to date.
        for (final tid in affectedThreads) {
          await _updateThread(account.id, mailboxPath, tid);
        }
      });
    } finally {
      _endServerFlagRead();
    }
  }

  static const _imapFlagReconcileInterval = Duration(minutes: 15);

  /// Periodic safety net: at most once per [_imapFlagReconcileInterval] per
  /// mailbox, unconditionally `UID FETCH 1:* FLAGS` and rewrite `isSeen` /
  /// `isFlagged` from server truth. Runs regardless of whether HIGHESTMODSEQ
  /// changed, so it catches drift when the server fails to advance MODSEQ on
  /// a flag mutation (Stalwart 0.14.x is known to do this for JMAP-side
  /// keyword changes, leaving the paired IMAP account permanently stale —
  /// #407). Skips rows whose flag change is still queued in `pendingChanges`
  /// so an unflushed optimistic edit is not silently reverted.
  Future<void> _maybeReconcileImapFlagsMailbox(
    imap.ImapClient client,
    String accountId,
    String mailboxPath,
  ) async {
    final key = 'IMAP:FlagReconcile:$mailboxPath';
    final last = await _loadSyncState(accountId, key);
    final dueValue = await _loadSyncState(
      accountId,
      _flagReconcileDueKey(mailboxPath, jmap: false),
    );
    if (last != null && dueValue == null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _imapFlagReconcileInterval) {
        return;
      }
    }

    final byUid = <int, ({bool seen, bool flagged})>{};
    final List<Email> localRows;
    final affectedThreads = <String>{};
    var corrected = 0;
    final flagRead = await _startServerFlagRead(accountId);
    try {
      final fetch = await client.uidFetchMessages(
        imap.MessageSequence.fromAll(),
        'FLAGS',
      );
      for (final msg in fetch.messages) {
        final uid = msg.uid;
        if (uid == null) continue;
        byUid[uid] = (
          seen: msg.flags?.contains(r'\Seen') ?? false,
          flagged: msg.flags?.contains(r'\Flagged') ?? false,
        );
      }

      localRows = await (_db.select(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .get();

      final queuedNow = await _inFlightFlagResourceIds(accountId);

      for (final row in localRows) {
        final serverFlags = byUid[row.uid];
        if (serverFlags == null) continue; // handled by _reconcileDeletedImap
        if (serverFlags.seen == row.isSeen &&
            serverFlags.flagged == row.isFlagged) {
          continue;
        }
        // Checked right before the write: a FETCH of a whole mailbox takes
        // a while, and a read/star change made meanwhile is newer than it.
        if (flagRead.protects(row.id, queuedNow)) continue;
        await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
          EmailsCompanion(
            isSeen: Value(serverFlags.seen),
            isFlagged: Value(serverFlags.flagged),
          ),
        );
        affectedThreads.add(row.threadId ?? row.id);
        corrected++;
      }
    } finally {
      _endServerFlagRead();
    }

    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }
    await _backfillImapSizes(
      client,
      [
        for (final row in localRows)
          if (row.sizeBytes == null &&
              !row.isLocal &&
              row.uid > 0 &&
              byUid.containsKey(row.uid))
            row,
      ],
    );

    if (corrected > 0) {
      log(
        'IMAP-sync: flag-reconcile mailbox=$mailboxPath corrected=$corrected '
        '(local=${localRows.length}, server=${byUid.length})',
      );
    }
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
    await _settleFlagReconcileDue(
      accountId,
      mailboxPath,
      jmap: false,
      dueValue: dueValue,
    );
  }

  static const _imapSizeBackfillBatch = 500;

  /// Fetches RFC822.SIZE for [rows] (cached before schema v64, still on the
  /// server) in batches and stores it. Only these rows are asked for, so once
  /// a mailbox is backfilled the reconcile costs nothing extra.
  Future<void> _backfillImapSizes(
    imap.ImapClient client,
    List<Email> rows,
  ) async {
    final idByUid = {for (final r in rows) r.uid: r.id};
    final uids = idByUid.keys.toList();
    for (var i = 0; i < uids.length; i += _imapSizeBackfillBatch) {
      final batch =
          uids.sublist(i, math.min(i + _imapSizeBackfillBatch, uids.length));
      final fetch = await client.uidFetchMessages(
        imap.MessageSequence.fromIds(batch, isUid: true),
        'RFC822.SIZE',
      );
      await _backfillSizes({
        for (final msg in fetch.messages)
          if (idByUid[msg.uid] != null && msg.size != null)
            idByUid[msg.uid]!: msg.size!,
      });
    }
  }

  /// Stores the message sizes in [sizeById] (email row id → bytes) in one
  /// batch: rows cached before schema v64 have none, and the first
  /// reconcile after the upgrade can fill in a whole mailbox at once.
  Future<void> _backfillSizes(Map<String, int> sizeById) async {
    if (sizeById.isEmpty) return;
    await _db.batch((b) {
      for (final MapEntry(key: id, value: size) in sizeById.entries) {
        b.update(
          _db.emails,
          EmailsCompanion(sizeBytes: Value(size)),
          where: (t) => t.id.equals(id),
        );
      }
    });
  }

  // Returns the total bytes transferred (sum of RFC822.SIZE for each message).
  Future<int> _fetchAndUpsertImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence, {
    ObjectIdKind? objectIdKind,
    int? uidValidity,
  }) async {
    // The offline preview snippet (matching the JMAP `preview` field, see
    // [_upsertJmapEmails] — IMAP has no standard preview property) is fetched
    // separately by [_fetchPreviewSnippetsSafely]: enough_mail's response
    // tokeniser mis-parses any partial `BODY.PEEK[…]<0.n>` item, so asking for
    // it here would set the message body to the literal string `0>` (#680).
    const fetchItems = '(UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE '
        'RFC822.SIZE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)])';
    // Usually new UIDs only, but a row can already exist (re-keyed after a
    // move, or a full sync without a checkpoint): its FLAGS must not undo a
    // read/star change made meanwhile.
    final flagRead = await _startServerFlagRead(account.id);
    try {
      return await _fetchAndUpsertImapGuarded(
        client,
        account,
        mailboxPath,
        sequence,
        fetchItems,
        flagRead,
        objectIdKind: objectIdKind,
        uidValidity: uidValidity,
      );
    } finally {
      _endServerFlagRead();
    }
  }

  Future<int> _fetchAndUpsertImapGuarded(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
    String fetchItems,
    _ServerFlagRead flagRead, {
    ObjectIdKind? objectIdKind,
    int? uidValidity,
  }) async {
    // Taken before the FETCH as well as after it: a move or delete queued
    // before the FETCH and sent by a flush while its answer was on the way
    // is no longer queued afterwards, yet the answer still lists the mail
    // here (#1269).
    final pendingBeforeFetch = await _pendingDeleteOrMoveUids(
      account.id,
      mailboxPath,
      uidValidity: uidValidity,
    );
    final fetch = sequence.isUidSequence
        ? await client.uidFetchMessages(sequence, fetchItems)
        : await client.fetchMessages(sequence, fetchItems);
    // enough_mail can't parse EMAILID/X-GM-MSGID, so pull the move-stable id
    // for the same sequence with a separate raw FETCH. Best-effort: any failure
    // leaves the map empty and the rows fall back to UID-only identity (#589).
    final serverEmailIdByUid = await _fetchServerEmailIds(
      client,
      sequence,
      objectIdKind,
    );
    final previewSnippetByUid = await _fetchPreviewSnippetsSafely(
      client,
      sequence,
    );
    // A change that failed meanwhile (e.g. a refused delete) no longer
    // hides the mail: the server's copy is shown again, as below for a
    // change made during the FETCH.
    final failedNow = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.state.equals(_failedState) &
                t.changeType.isIn(_placementChangeTypes),
          ))
        .get();
    final failedIds = {for (final c in failedNow) c.id};
    final failedResourceIds = {for (final c in failedNow) c.resourceId};
    final pendingByUid = {
      for (final MapEntry(:key, :value) in pendingBeforeFetch.entries)
        if (!failedIds.contains(value.id)) key: value,
      ...await _pendingDeleteOrMoveUids(
        account.id,
        mailboxPath,
        uidValidity: uidValidity,
      ),
    };
    var bytes = 0;
    final affectedThreads = <String>{};
    // (realEmailId, messageId) of each row we just wrote — checked afterwards
    // for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String?)>[];
    // (emailId, subject, size) of each row stored for the first time — logged
    // after the transaction so "Show Logs" starts with the fetch (#920).
    final newlyStored = <(String, String?, int?)>[];
    await _db.transaction(() async {
      final queuedNow = await _inFlightFlagResourceIds(account.id);
      for (final msg in fetch.messages) {
        final envelope = msg.envelope;
        if (envelope == null) {
          log(
            'IMAP: skipping message with no envelope (uid=${msg.uid}, mailbox=$mailboxPath)',
          );
          continue;
        }
        final uid = msg.uid;
        if (uid == null) {
          log('IMAP: skipping message with no uid (mailbox=$mailboxPath)');
          continue;
        }
        // Don't resurrect a row the user has already removed locally via a
        // pending delete or move. The IMAP server still has the message
        // until the next flushPendingChanges, and `UID lastUid+1:*` can
        // even return a UID smaller than `lastUid+1` because RFC 3501
        // §6.4.4 reverses `n:*` to `*:n` when `n` exceeds the largest UID.
        if (pendingByUid.containsKey(uid)) {
          log(
            'IMAP: skipping insert for uid=$uid in $mailboxPath '
            '(pending ${pendingByUid[uid]!.changeType})',
          );
          continue;
        }
        bytes += msg.size ?? 0;
        final emailId = '${account.id}:$mailboxPath:$uid';
        final serverEmailId = serverEmailIdByUid[uid];
        final msgId = normaliseMessageId(envelope.messageId);
        final inReplyTo = normaliseMessageId(envelope.inReplyTo);
        final refs = normaliseReferences(msg.getHeaderValue('References'));
        final listUnsubscribe = msg.getHeaderValue('List-Unsubscribe')?.trim();
        // Re-decode Subject from the raw header enough_mail stashed on the
        // message during envelope parsing (#418). `envelope.subject` uses
        // MailCodec.decodeHeader, which leaves stray spaces around ü/ö/ä
        // when adjacent encoded-words differ in charset case or are folded
        // with a tab.
        final subject =
            decodeMailHeader(msg.getHeaderValue('Subject')) ?? envelope.subject;
        final threadId = _computeThreadId(
              messageId: msgId,
              inReplyTo: inReplyTo,
              references: refs,
              subject: subject,
              date: envelope.date,
            ) ??
            emailId;
        affectedThreads.add(threadId);

        DateTime? snoozedUntil;
        for (final String flag in msg.flags ?? <String>[]) {
          if (flag.startsWith('snz:')) {
            final ts = flag.substring(4);
            // Format: YYYYMMDDTHHMMSSZ (no dashes/colons)
            if (ts.length >= 15) {
              final formatted =
                  '${ts.substring(0, 4)}-${ts.substring(4, 6)}-${ts.substring(6, 8)}T${ts.substring(9, 11)}:${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
              snoozedUntil = DateTime.tryParse(formatted);
            }
            break;
          }
        }

        final isNew = await (_db.selectOnly(_db.emails)
                  ..addColumns([_db.emails.id])
                  ..where(_db.emails.id.equals(emailId)))
                .getSingleOrNull() ==
            null;
        // No row, but the user changed it since the FETCH was sent: it was
        // moved or deleted here meanwhile, and maybe already sent, so the
        // answer predates that. Inserting it would duplicate the mail in its
        // old folder (#1269). If a move fails, its revert brings the row
        // back.
        if (isNew &&
            flagRead.editedSince(emailId) &&
            !failedResourceIds.contains(emailId)) {
          log(
            'IMAP: skipping insert for uid=$uid in $mailboxPath '
            '(changed locally while the FETCH ran)',
          );
          continue;
        }
        final keepLocalFlags = !isNew && flagRead.protects(emailId, queuedNow);
        await _db.into(_db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: emailId,
                accountId: account.id,
                mailboxPath: mailboxPath,
                uid: uid,
                subject: Value(subject),
                sentAt: Value(envelope.date),
                // The server's arrival time, like JMAP `receivedAt`. Never
                // the local fetch time when the server knows better: mail
                // without a Date header used to be re-dated to "now" on every
                // re-fetch, so a resync or reinstall moved it to the top.
                receivedAt: parseImapDateTime(msg.internalDate) ??
                    envelope.date ??
                    DateTime.now(),
                fromJson: Value(_encodeAddresses(envelope.from)),
                toAddresses: Value(_encodeAddresses(envelope.to)),
                ccJson: Value(_encodeAddresses(envelope.cc)),
                replyToJson: Value(_encodeAddresses(envelope.replyTo)),
                bccJson: Value(_encodeAddresses(envelope.bcc)),
                sizeBytes:
                    msg.size == null ? const Value.absent() : Value(msg.size),
                preview: Value(
                  previewFromSnippet(msg, previewSnippetByUid[uid]),
                ),
                // Absent keeps the stored value of an edited existing row.
                isSeen: keepLocalFlags
                    ? const Value.absent()
                    : Value(msg.flags?.contains(r'\Seen') ?? false),
                isFlagged: keepLocalFlags
                    ? const Value.absent()
                    : Value(msg.flags?.contains(r'\Flagged') ?? false),
                // enough_mail counts parts with Content-Disposition: attachment;
                // JMAP's hasAttachment (below) is server-defined, so the two
                // protocols may disagree on e.g. inline images.
                hasAttachment: Value(msg.hasAttachments()),
                threadId: Value(threadId),
                messageId: Value(msgId),
                inReplyTo: Value(inReplyTo),
                references: Value(refs),
                snoozedUntil: Value(snoozedUntil),
                listUnsubscribeHeader: Value(listUnsubscribe),
                // Preserve a previously captured id if this fetch couldn't
                // read one, rather than clobbering it with null.
                serverEmailId: serverEmailId == null
                    ? const Value.absent()
                    : Value(serverEmailId),
              ),
            );
        if (msgId != null) dissolveCandidates.add((emailId, msgId));
        if (isNew) newlyStored.add((emailId, subject, msg.size));
      }
    });
    // Outside the transaction: the app log writes through the same database.
    for (final (emailId, subject, size) in newlyStored) {
      _logEmailFetched(
        emailId: emailId,
        accountId: account.id,
        mailboxPath: mailboxPath,
        protocol: 'imap',
        subject: subject,
        bytes: size,
      );
    }
    for (final tid in affectedThreads) {
      await _updateThread(account.id, mailboxPath, tid);
    }
    if (dissolveCandidates.isNotEmpty && await _hasLocalMessages(account.id)) {
      for (final (emailId, msgId) in dissolveCandidates) {
        await _maybeDissolveLocalMessage(
          account.id,
          mailboxPath,
          emailId,
          msgId,
        );
      }
    }
    return bytes;
  }

  /// Fetches the move-stable server id for every UID in [sequence] when the
  /// server advertises one ([objectIdKind] non-null). Returns an empty map when
  /// unsupported or on any error, so a server that mishandles the raw FETCH
  /// degrades to the UID-based identity scheme instead of failing the sync.
  Future<Map<int, String>> _fetchServerEmailIds(
    imap.ImapClient client,
    imap.MessageSequence sequence,
    ObjectIdKind? objectIdKind,
  ) async {
    if (objectIdKind == null) return const {};
    try {
      return await _fetchObjectIds(client, sequence, objectIdKind);
    } catch (e) {
      log('IMAP: ${objectIdKind.fetchItem} fetch failed, '
          'falling back to UID identity: $e');
      return const {};
    }
  }

  /// Fetches the body prefix used for the offline preview snippet, best-effort.
  ///
  /// Fail-open: a server that rejects the partial fetch leaves rows without a
  /// preview until [getEmailBody] backfills one, which beats failing the sync.
  Future<Map<int, Uint8List>> _fetchPreviewSnippetsSafely(
    imap.ImapClient client,
    imap.MessageSequence sequence,
  ) async {
    try {
      return await _fetchPreviewSnippets(
        client,
        sequence,
        kPreviewSnippetBytes,
      );
    } catch (e) {
      log('IMAP: preview snippet fetch failed, syncing without previews: $e');
      return const {};
    }
  }

  /// Whether [accountId] has any local self-sent "virtual" rows awaiting a real
  /// counterpart (#545). A one-shot guard so sync's per-message dissolve scan is
  /// skipped entirely for the common case of no pending self-sends.
  Future<bool> _hasLocalMessages(String accountId) async {
    final row = await (_db.select(_db.emails)
          ..where((t) => t.accountId.equals(accountId) & t.isLocal.equals(true))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  // UIDs in [mailboxPath] that have a pending local delete, move, snooze or
  // unsnooze queued, with that change. Used by the IMAP fetch path to avoid
  // re-inserting rows the user has already removed from view but whose
  // change has not yet flushed. A failed change is not counted: the
  // server's copy is shown again. Neither is one stamped with another
  // [uidValidity] than the folder's current one: its UID names another
  // mail now.
  Future<Map<int, PendingChangeRow>> _pendingDeleteOrMoveUids(
    String accountId,
    String mailboxPath, {
    int? uidValidity,
  }) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.isIn(_liveStates) &
                t.resourceType.equals('Email') &
                t.changeType.isIn(_placementChangeTypes),
          ))
        .get();
    final result = <int, PendingChangeRow>{};
    for (final r in rows) {
      try {
        final payload = jsonDecode(r.payload) as Map<String, dynamic>;
        // Snooze and unsnooze name their source `src`.
        if ((payload['mailboxPath'] ?? payload['src']) != mailboxPath) {
          continue;
        }
        // Its UID is the one from before a queued move, not this folder's:
        // it may be another mail's here, which must not be skipped (#1266).
        if (payload[_uidAfterMoveKey] == true) continue;
        final stamped = payload['uidValidity'];
        if (uidValidity != null && stamped is int && stamped != uidValidity) {
          continue;
        }
        final uid = payload['uid'];
        if (uid is int) result[uid] = r;
      } catch (_) {
        // Malformed payload — skip.
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> _loadImapCheckpoint(
    String accountId,
    String resourceType,
  ) async {
    final raw = await _loadSyncState(accountId, resourceType);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> _saveImapCheckpoint(
    String accountId,
    String resourceType,
    int uidValidity,
    int lastUid, {
    int? highestModSeq,
    int? uidNext,
    int? exists,
  }) async {
    final data = <String, dynamic>{
      'uidValidity': uidValidity,
      'lastUid': lastUid,
    };
    if (highestModSeq != null) data['highestModSeq'] = highestModSeq;
    // What SELECT reported, for the IDLE wait's catch-up check
    // ([lastImapMailboxState]).
    if (uidNext != null) data['uidNext'] = uidNext;
    if (exists != null) data['exists'] = exists;
    await _saveSyncState(accountId, resourceType, jsonEncode(data));
  }

  @visibleForTesting
  Future<void> reconcileDeletedImapForTest(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
  }) =>
      _reconcileDeletedImap(
        accountId,
        mailboxPath,
        serverUids,
        serverMessageCount: serverMessageCount,
      );

  Future<void> _reconcileDeletedImap(
    String accountId,
    String mailboxPath,
    List<int> serverUids, {
    int? serverMessageCount,
  }) async {
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();

    // Guard: an empty `UID SEARCH ALL` is ambiguous — it can mean the mailbox
    // really is empty, or that the response was incomplete (network glitch,
    // buggy IMAP server). Distinguish the two using the authoritative EXISTS
    // count from the SELECT response:
    //   • EXISTS == 0  → the folder genuinely has no messages. Trust it and
    //     reconcile, so a folder emptied on the server (e.g. the last message
    //     was deleted/moved to Trash via another account or client) also
    //     clears locally instead of leaving a phantom row behind.
    //   • EXISTS  > 0  (or unknown) → the server claims messages exist but the
    //     search returned none. That's the suspicious case; skip to avoid
    //     wiping the cache on a bad response.
    if (serverUids.isEmpty && localRows.isNotEmpty && serverMessageCount != 0) {
      log(
        '_reconcileDeletedImap: skipping — server returned 0 UIDs for '
        '$mailboxPath but local DB has ${localRows.length} emails '
        '(EXISTS=${serverMessageCount ?? '?'})',
      );
      return;
    }

    // Email IDs that still have a queued move/snooze/unsnooze waiting to be
    // flushed. The optimistic local move has already updated mailbox_path, so
    // these rows look orphaned from both the old and new mailbox until the
    // server applies the change and we remap to the destination UID. Skipping
    // them here avoids wiping the row mid-flight.
    final inFlightSet = await _rowsWithUnflushedMoveOrSnooze(accountId);

    final serverUidSet = serverUids.toSet();
    final affectedThreads = <String>{};
    for (final row in localRows) {
      // Local self-sent "virtual" rows have no server UID and must survive
      // until the real message arrives and dissolves them (#545).
      if (row.isLocal) continue;
      if (!serverUidSet.contains(row.uid)) {
        if (inFlightSet.contains(row.id)) continue;
        // A message that vanished from this folder but reappeared under a
        // different folder with the same move-stable server id (RFC 8474
        // EMAILID / Gmail X-GM-MSGID) was moved, not deleted. Hand its
        // locally-cached body and undo/thread references to the destination
        // row before dropping this one, so a foreign move preserves the same
        // state as one we made ourselves (#589). Correct for Gmail/COPY too:
        // those keep the message in the source folder, so no vanish fires.
        final destId = await _movedDestinationId(accountId, row);
        if (destId != null) {
          await _adoptImapMovedRow(oldId: row.id, newId: destId);
        }
        affectedThreads.add(row.threadId ?? row.id);
        await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      }
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }
  }

  /// When [row] has just vanished from its folder, returns the id of another
  /// locally cached row (in a different folder of the same account) that
  /// carries the same move-stable server id — i.e. the destination of a folder
  /// move. Returns null when [row] has no server id or no such sibling exists.
  Future<String?> _movedDestinationId(String accountId, Email row) async {
    final serverEmailId = row.serverEmailId;
    if (serverEmailId == null || serverEmailId.isEmpty) return null;
    final dest = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.serverEmailId.equals(serverEmailId) &
                t.id.equals(row.id).not(),
          )
          ..limit(1))
        .getSingleOrNull();
    return dest?.id;
  }

  /// Migrates the locally-cached artifacts of a moved-away row [oldId] onto the
  /// destination row [newId]: the cached body (only when the destination has
  /// none, to avoid a primary-key clash) and every undo/thread/pending
  /// reference. The [oldId] `emails` row itself is deleted by the caller.
  Future<void> _adoptImapMovedRow({
    required String oldId,
    required String newId,
  }) async {
    await _db.transaction(() async {
      final destHasBody = await (_db.select(_db.emailBodies)
                ..where((t) => t.emailId.equals(newId))
                ..limit(1))
              .getSingleOrNull() !=
          null;
      if (destHasBody) {
        // Keep the destination's own body; drop the now-orphaned source copy.
        await (_db.delete(_db.emailBodies)
              ..where((t) => t.emailId.equals(oldId)))
            .go();
      } else {
        await _db.customStatement(
          'UPDATE email_bodies SET email_id = ?1 WHERE email_id = ?2',
          [newId, oldId],
        );
      }

      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldId)))
          .write(PendingChangesCompanion(resourceId: Value(newId)));

      // threads.latest_email_id / threads.email_ids_json and undo_actions
      // embed email ids as unique opaque strings — safe to rewrite by REPLACE.
      await _db.customStatement(
        'UPDATE threads SET latest_email_id = ?1 WHERE latest_email_id = ?2',
        [newId, oldId],
      );
      await _db.customStatement(
        'UPDATE threads SET email_ids_json = REPLACE(email_ids_json, ?1, ?2) '
        'WHERE email_ids_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );
      await _db.customStatement(
        'UPDATE undo_actions SET data_json = REPLACE(data_json, ?1, ?2) '
        'WHERE data_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );
      // Like [_rekeyEmailRow]: the per-message logs follow the message;
      // dropping the source row would set their email_id to null.
      await _db.customStatement(
        'UPDATE app_logs SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );
    });
  }

  // ── Sync Reliability ──────────────────────────────────────────────────────

  @override
  Future<model.ReliabilityResult> verifySyncReliability(
    String accountId,
    String mailboxPath,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);

    switch (account.type) {
      case account_model.AccountType.imap:
        return _verifyReliabilityImap(account, password, mailboxPath);
      case account_model.AccountType.jmap:
        return _verifyReliabilityJmap(account, password, mailboxPath);
    }
  }

  // ── Folder diagnostics (#511) ─────────────────────────────────────────────

  @override
  Future<model.MailboxDiagnostics> diagnoseMailbox(
    String accountId,
    String mailboxPath,
  ) async {
    final account = (await _accounts.getAccount(accountId))!;

    // Cached folder count — exactly what the folder list renders.
    final mailboxRow = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.path.equals(mailboxPath),
          )
          ..limit(1))
        .getSingleOrNull();

    // Local cache row counts.
    final localEmails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();
    final localThreads = await (_db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();
    final localEmailRows = localEmails.length;
    final localThreadRows = localThreads.length;

    // Orphaned thread rows: thread ids no longer backed by any email in this
    // folder. `observeThreads` renders these as phantom conversations (#523).
    // Uses the same `threadId ?? id` key derivation as _updateThread.
    final validThreadIds = <String>{
      for (final e in localEmails) e.threadId ?? e.id,
    };
    final orphanThreadRows =
        localThreads.where((t) => !validThreadIds.contains(t.id)).length;

    final protocol =
        account.type == account_model.AccountType.imap ? 'IMAP' : 'JMAP';

    int? serverTotal;
    int? serverUnread;
    int? serverMessageCount;
    var missingLocally = const <String>[];
    var missingOnServer = const <String>[];
    String? error;

    try {
      final password = await _accounts.getPassword(accountId);
      final _LiveMailboxCounts live;
      switch (account.type) {
        case account_model.AccountType.imap:
          live = await _liveDiagnosticsImap(account, password, mailboxPath);
        case account_model.AccountType.jmap:
          live = await _liveDiagnosticsJmap(account, password, mailboxPath);
      }
      serverTotal = live.serverTotal;
      serverUnread = live.serverUnread;
      serverMessageCount = live.serverMessageCount;
      missingLocally = live.missingLocally;
      missingOnServer = live.missingOnServer;
    } catch (e, stack) {
      error = e.toString();
      unawaited(
        _appLogger?.warn(
          'mailbox_diagnostics_failed',
          'Could not reach the server while diagnosing "$mailboxPath"',
          accountId: accountId,
          mailboxPath: mailboxPath,
          error: e,
          stack: stack,
        ),
      );
    }

    final diagnostics = model.MailboxDiagnostics(
      accountId: accountId,
      mailboxPath: mailboxPath,
      protocol: protocol,
      cachedTotal: mailboxRow?.totalCount ?? 0,
      cachedUnread: mailboxRow?.unreadCount ?? 0,
      localEmailRows: localEmailRows,
      localThreadRows: localThreadRows,
      orphanThreadRows: orphanThreadRows,
      serverTotal: serverTotal,
      serverUnread: serverUnread,
      serverMessageCount: serverMessageCount,
      missingLocally: missingLocally,
      missingOnServer: missingOnServer,
      error: error,
    );

    // Log a one-line summary so a diagnosis is discoverable in the App Log and
    // in bug reports (#511), mirroring the mailbox_count_failed convention.
    unawaited(
      _appLogger?.info(
        'mailbox_diagnostics',
        'Diagnosed "$mailboxPath": ${diagnostics.conclusions.first}',
        accountId: accountId,
        mailboxPath: mailboxPath,
        data: {
          'protocol': protocol,
          'cachedTotal': diagnostics.cachedTotal,
          'localEmailRows': localEmailRows,
          'localThreadRows': localThreadRows,
          'orphanThreadRows': orphanThreadRows,
          'serverTotal': serverTotal,
          'serverMessageCount': serverMessageCount,
          'missingLocally': missingLocally.length,
          'missingOnServer': missingOnServer.length,
        },
      ),
    );

    return diagnostics;
  }

  Future<_LiveMailboxCounts> _liveDiagnosticsImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      // SELECT yields the server's EXISTS count — the same number the folder
      // list's STATUS query trusts.
      final selected = await client.selectUnicodeMailboxByPath(mailboxPath);
      final serverTotal = selected.messagesExists;
      // uidSearchMessages defaults to the UNSEEN criteria.
      final unseen = await client.uidSearchMessages();
      final all = await client.uidSearchMessages(searchCriteria: 'ALL');
      final unseenUids = unseen.matchingSequence?.toList() ?? <int>[];
      final serverUids = all.matchingSequence?.toList() ?? <int>[];
      final serverUidSet = serverUids.toSet();

      final localRows = await (_db.select(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .get();
      final localUidSet = localRows.map((r) => r.uid).toSet();

      final missingLocally = [
        for (final uid in serverUids)
          if (!localUidSet.contains(uid)) uid.toString(),
      ];
      final missingOnServer = [
        for (final row in localRows)
          if (!serverUidSet.contains(row.uid)) row.id,
      ];

      return _LiveMailboxCounts(
        serverTotal: serverTotal,
        serverUnread: unseenUids.length,
        serverMessageCount: serverUids.length,
        missingLocally: missingLocally,
        missingOnServer: missingOnServer,
      );
    } finally {
      await closeImapClient(client);
    }
  }

  Future<_LiveMailboxCounts> _liveDiagnosticsJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxResponses = await jmap.call([
      [
        'Mailbox/get',
        {
          'accountId': jmap.accountId,
          'ids': [mailboxJmapId],
          'properties': ['id', 'totalEmails', 'unreadEmails'],
        },
        '0',
      ],
    ]);
    final mailboxResult = _responseArgs(mailboxResponses, 0, 'Mailbox/get');
    final mailboxList = mailboxResult['list'] as List<dynamic>;
    int? serverTotal;
    int? serverUnread;
    if (mailboxList.isNotEmpty) {
      final mb = mailboxList.first as Map<String, dynamic>;
      serverTotal = mb['totalEmails'] as int?;
      serverUnread = mb['unreadEmails'] as int?;
    }

    final allServerIds = <String>[];
    int position = 0;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'limit': 1000,
            'position': position,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      allServerIds.addAll(ids);
      if (ids.length < 1000) break;
      position += ids.length;
    }
    final serverIdSet = allServerIds.toSet();

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();
    final localIdSet = localRows.map((r) => r.id.split(':').last).toSet();

    final missingLocally = [
      for (final id in allServerIds)
        if (!localIdSet.contains(id)) id,
    ];
    final missingOnServer = [
      for (final row in localRows)
        if (!serverIdSet.contains(row.id.split(':').last)) row.id,
    ];

    return _LiveMailboxCounts(
      serverTotal: serverTotal,
      serverUnread: serverUnread,
      serverMessageCount: allServerIds.length,
      missingLocally: missingLocally,
      missingOnServer: missingOnServer,
    );
  }

  Future<model.ReliabilityResult> _verifyReliabilityImap(
    account_model.Account account,
    String password,
    String mailboxPath,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectUnicodeMailboxByPath(mailboxPath);
      final serverUids = (await client.uidSearchMessages(
            searchCriteria: 'ALL',
          ))
              .matchingSequence
              ?.toList() ??
          [];
      final serverUidSet = serverUids.toSet();

      final localRows = await (_db.select(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(account.id) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .get();
      final localUidSet = localRows.map((r) => r.uid).toSet();

      final missingLocally = <String>[];
      for (final uid in serverUids) {
        if (!localUidSet.contains(uid)) {
          missingLocally.add(uid.toString());
        }
      }

      final missingOnServer = <String>[];
      for (final row in localRows) {
        if (!serverUidSet.contains(row.uid)) {
          missingOnServer.add(row.id);
        }
      }

      final flagMismatches = <model.FlagMismatch>[];
      // To avoid fetching thousands of flags, we only check if there aren't too many.
      if (serverUids.isNotEmpty && serverUids.length < 5000) {
        final fetch = await client.uidFetchMessages(
          imap.MessageSequence.fromAll(),
          'FLAGS',
        );
        final localMap = {for (final r in localRows) r.uid: r};
        for (final msg in fetch.messages) {
          final uid = msg.uid;
          if (uid == null) continue;
          final local = localMap[uid];
          if (local == null) continue;

          final serverSeen = msg.flags?.contains(r'\Seen') ?? false;
          final serverFlagged = msg.flags?.contains(r'\Flagged') ?? false;

          if (serverSeen != local.isSeen || serverFlagged != local.isFlagged) {
            flagMismatches.add(
              model.FlagMismatch(
                id: local.id,
                serverSeen: serverSeen,
                localSeen: local.isSeen,
                serverFlagged: serverFlagged,
                localFlagged: local.isFlagged,
              ),
            );
          }
        }
      }

      return model.ReliabilityResult(
        missingLocally: missingLocally,
        missingOnServer: missingOnServer,
        flagMismatches: flagMismatches,
      );
    } finally {
      await closeImapClient(client);
    }
  }

  Future<model.ReliabilityResult> _verifyReliabilityJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl!;
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final allServerIds = <String>[];
    int position = 0;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'limit': 1000,
            'position': position,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      allServerIds.addAll(ids);
      if (ids.length < 1000) break;
      position += ids.length;
    }
    final serverIdSet = allServerIds.toSet();

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(account.id) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();
    final localIdSet = localRows.map((r) => r.id.split(':').last).toSet();

    final missingLocally = <String>[];
    for (final id in allServerIds) {
      if (!localIdSet.contains(id)) {
        missingLocally.add(id);
      }
    }

    final missingOnServer = <String>[];
    for (final row in localRows) {
      final jmapId = row.id.split(':').last;
      if (!serverIdSet.contains(jmapId)) {
        missingOnServer.add(row.id);
      }
    }

    final flagMismatches = <model.FlagMismatch>[];
    if (allServerIds.isNotEmpty) {
      final localMap = {for (final r in localRows) r.id.split(':').last: r};

      // Fetch keywords in pages: sending every id in a single Email/get can
      // exceed the server's maxObjectsInGet and fail with requestTooLarge
      // (see #513). Mirror the batching used elsewhere in this file.
      for (var offset = 0;
          offset < allServerIds.length;
          offset += _jmapPageSize) {
        final batch = allServerIds.sublist(
          offset,
          math.min(offset + _jmapPageSize, allServerIds.length),
        );
        final responses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': batch,
              'properties': ['id', 'keywords'],
            },
            '0',
          ],
        ]);
        final getResult = _responseArgs(responses, 0, 'Email/get');
        final list = getResult['list'] as List<dynamic>;

        for (final e in list) {
          final m = e as Map<String, dynamic>;
          final id = m['id'] as String;
          final local = localMap[id];
          if (local == null) continue;

          final keywords = (m['keywords'] as Map<String, dynamic>?) ?? {};
          final serverSeen = keywords.containsKey(r'$seen');
          final serverFlagged = keywords.containsKey(r'$flagged');

          if (serverSeen != local.isSeen || serverFlagged != local.isFlagged) {
            flagMismatches.add(
              model.FlagMismatch(
                id: local.id,
                serverSeen: serverSeen,
                localSeen: local.isSeen,
                serverFlagged: serverFlagged,
                localFlagged: local.isFlagged,
              ),
            );
          }
        }
      }
    }

    return model.ReliabilityResult(
      missingLocally: missingLocally,
      missingOnServer: missingOnServer,
      flagMismatches: flagMismatches,
    );
  }

  // ── JMAP email sync ────────────────────────────────────────────────────────

  static const _jmapPageSize = 500;

  /// Backstop on an `Email/query` walk. Set far above any real mailbox
  /// (2 000 pages = 1 000 000 messages) because it is not the mechanism that
  /// catches a misbehaving server — a walk that stops making progress is, and
  /// that trips after two pages rather than two thousand.
  ///
  /// Reaching this means the enumeration is incomplete, so nothing is pruned
  /// and — in the full sync — no state is checkpointed, because checkpointing
  /// a truncated walk would switch the mailbox to the incremental path with
  /// its older messages never downloaded.
  static const _jmapMaxQueryPages = 2000;

  /// Whether a walk that collected [seen] ids, with [reportedTotal] being the
  /// last `total` the server gave, can be trusted to have enumerated the whole
  /// mailbox.
  ///
  /// This gates every prune, because pruning against an untrustworthy
  /// enumeration deletes every message the walk did not see — and for a
  /// spurious empty first page that is the entire mailbox. A server that
  /// answers one bad `Email/query` should cost a deferred reconcile, not a
  /// folder.
  ///
  /// An empty mailbox reports `total: 0` and collects nothing, which is
  /// complete and correctly prunes away local leftovers. A server that does
  /// not report `total` at all is never trusted; the periodic reconcile
  /// retries instead.
  ///
  /// Exact equality, not `>=`. A `total` that is too small would otherwise
  /// wave the walk through: `total: 0` alongside a full page of ids ends the
  /// walk after that page, and `500 >= 0` would authorise pruning the rest of
  /// the folder away. Equality also rejects the case where the mailbox shrank
  /// mid-walk — position paging shifts backwards, so ids get skipped while the
  /// count still lines up, and `seen` would be missing messages that are
  /// still on the server. This is a count check, not an integrity check; it
  /// only has to be conservative.
  static bool _jmapEnumerationComplete(Set<String> seen, int? reportedTotal) =>
      reportedTotal != null && seen.length == reportedTotal;

  /// A pending change that has failed this many attempts is marked
  /// [_failedState] and no longer retried, so a permanent server error does
  /// not retry forever. It is kept until the user retries or discards it.
  static const _maxChangeAttempts = model.maxPendingChangeAttempts;

  /// `pending_changes.state` of a change that is queued or still retrying.
  /// Only these rows are flushed.
  static const _pendingState = 'pending';

  /// `pending_changes.state` of a change a flush claimed and may be sending
  /// right now ([_claimPendingChange]), until [PendingChangeRow.leaseUntil].
  /// It cannot be cancelled (Undo queues a reverse change instead) and is
  /// not claimed by another flush while the lease holds.
  static const _inflightState = 'inflight';

  /// States of a change that still protects its local value from sync and
  /// that later changes of the mail depend on: queued, retrying or being
  /// sent.
  static const _liveStates = [_pendingState, _inflightState, _stuckState];

  /// `pending_changes.state` of a change that kept failing in a way that may
  /// pass ([_maxChangeAttempts] tries): it keeps protecting the user's
  /// local value and is retried with a growing backoff ([_stuckBackoff];
  /// `lease_until` holds the next try). Shown as "not synced yet"; only the
  /// user's Retry (now) or Discard (undone locally) ends it early.
  static const _stuckState = 'stuck';

  /// [t] as local `HH:MM`, for log lines.
  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }

  /// The state for a claimed change put back in the queue without an
  /// outcome (not sent, maybe sent, released, lease expired) after
  /// [attempts]: `stuck` from the retry limit on (with its backoff, or due
  /// at once with [dueNow] for one that was not sent), so it stays among
  /// the stuck changes, else `pending`.
  PendingChangesCompanion _requeued(int attempts, {bool dueNow = false}) =>
      attempts >= _maxChangeAttempts
          ? PendingChangesCompanion(
              state: const Value(_stuckState),
              leaseUntil:
                  Value(dueNow ? _now() : _now().add(_stuckBackoff(attempts))),
              claimToken: const Value(null),
              attempts: Value(attempts),
            )
          : PendingChangesCompanion(
              state: const Value(_pendingState),
              leaseUntil: const Value(null),
              claimToken: const Value(null),
              attempts: Value(attempts),
            );

  /// Wait before the next try of a stuck change that has failed [attempts]
  /// times: 15 minutes at the limit, doubling, at most 6 hours.
  static Duration _stuckBackoff(int attempts) {
    final steps = math.max(0, attempts - _maxChangeAttempts);
    final minutes = 15 * math.pow(2, math.min(steps, 5)).toInt();
    return Duration(minutes: math.min(minutes, 6 * 60));
  }

  /// How long a claim holds. Longer than any single apply: a claim is taken
  /// right before its apply, and a batch's one-by-one fallback renews it
  /// ([_renewClaim]), so a second process flushing the same database does
  /// not take over a change being sent. An expired lease means the app died
  /// mid-send ([_recoverExpiredLeases]); short enough that a change killed
  /// with the app is sent again soon after the restart.
  static const _leaseDuration = Duration(minutes: 5);

  /// `pending_changes.state` of a change the app gave up on (retry limit or
  /// a permanent refusal). Never flushed and protects nothing, so the next
  /// server read shows server truth again; listed on the Pending Changes
  /// screen.
  static const _failedState = 'failed';

  static const _emailProperties = [
    'id',
    'threadId',
    'mailboxIds',
    'subject',
    // Raw Subject header so we can re-decode client-side when the server's
    // RFC 2047 decoding leaves stray spaces around encoded-word boundaries
    // (see #418, and [decodeMailHeader]).
    'header:Subject:asRaw',
    'sentAt',
    'receivedAt',
    'from',
    'to',
    'cc',
    'replyTo',
    'bcc',
    'size',
    'keywords',
    'hasAttachment',
    'preview',
    'messageId',
    'inReplyTo',
    'references',
    'textBody',
    'htmlBody',
    'bodyValues',
    'attachments',
    'header:List-Unsubscribe:asText',
  ];

  static const _emailGetBodyOptions = {
    'fetchHTMLBodyValues': true,
    'fetchTextBodyValues': true,
  };

  Future<model.SyncEmailsResult> _syncEmailsJmap(
    account_model.Account account,
    String password,
    String mailboxJmapId,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    final mailboxResourceType = 'JMAP:Email:$mailboxJmapId';
    var storedMailboxState =
        await _loadSyncState(account.id, mailboxResourceType);

    // A full sync that paused part-way leaves no `JMAP:Email:` state but does
    // leave a resume point. It MUST stay on the full-sync path: taking the
    // incremental path here would ask `Email/changes` for deltas and never
    // fetch the mailbox's remaining pages. Checked before the global-state
    // fallback, which would otherwise adopt another mailbox's state and send
    // this one incremental (the defect that sank the first resume attempt).
    final resuming =
        await _loadSyncState(account.id, _jmapFullSyncKey(mailboxJmapId)) !=
            null;

    if (storedMailboxState == null && !resuming) {
      // Fallback to global 'Email' state
      final globalState = await _loadSyncState(account.id, 'Email');
      if (globalState != null) {
        storedMailboxState = globalState;
        await _saveSyncState(account.id, mailboxResourceType, globalState);
      }
    }

    try {
      if (resuming || storedMailboxState == null) {
        log(
          'JMAP-sync: full sync mailbox=$mailboxJmapId '
          '(${resuming ? 'resuming' : 'no stored state'})',
        );
        return await _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
      }
      log(
        'JMAP-sync: incremental sync mailbox=$mailboxJmapId '
        'sinceState=$storedMailboxState',
      );
      return await _jmapIncrementalEmailSync(
        account.id,
        jmap,
        storedMailboxState,
        mailboxJmapId: mailboxJmapId,
      );
    } finally {
      // Defence-in-depth: periodically diff the local cache against a bare
      // Email/query to catch server-side edge cases where Email/changes
      // under-reports deletions (see #262). Cheap: ids only, no bodies.
      //
      // In a `finally` because this is the only cleanup that ever reaches a
      // row the server silently omitted — `Email/changes` will not re-report
      // it once the page is checkpointed. Sequenced after the sync, a folder
      // that throws every cycle (`_syncFolders` catches per folder and moves
      // on) would never be reconciled at all, and its ghosts would be
      // permanent.
      //
      // Its own failure must not replace the sync's: a throw out of a
      // `finally` discards the exception in flight.
      try {
        await _maybeReconcileJmapMailbox(account.id, jmap, mailboxJmapId);
      } catch (e, stack) {
        log(
          'JMAP-sync: reconcile failed for mailbox=$mailboxJmapId',
          error: e,
          stackTrace: stack,
        );
      }
    }
  }

  /// How many `Email/query` pages one full-sync invocation walks before it
  /// pauses and hands back, so the next cycle continues from the resume point.
  ///
  /// #973 split the chained body fetch into bounded batches, taking a
  /// 10 000-mail mailbox from ~20 requests to ~220. Running all of that in one
  /// invocation and losing it to a backgrounded app or a dropped connection
  /// would be the "never catches up" shape of #967 again, moved from a
  /// per-request timeout to total run length.
  static const _jmapFullSyncPagesPerRun = 4;

  /// Where an unfinished full sync stores its resume point.
  ///
  /// Deliberately NOT `JMAP:Email:<mailbox>`: that key means "incrementally
  /// synced", and writing it mid-sync would send the next cycle to
  /// `Email/changes`, which never fetches the mailbox's remaining pages.
  static String _jmapFullSyncKey(String mailboxJmapId) =>
      'JMAP:FullSync:$mailboxJmapId';

  Future<model.SyncEmailsResult> _jmapFullEmailSync(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    final resumeKey = _jmapFullSyncKey(mailboxJmapId);

    // Resume point: the id of the last message fetched (the paging anchor) and
    // the Email state token captured on the very first page. Resuming by a
    // stable id rather than a numeric `position` is the whole reason this is a
    // second attempt: `Email/query` offsets shift when mail is added or
    // removed between runs, so a position-based resume silently skipped
    // messages. An anchor is immune to changes above it, and when the anchor
    // message itself is deleted the server answers `anchorNotFound` and the
    // walk restarts from the top — mbsync's UIDVALIDITY reset, in JMAP terms.
    String? anchor;
    String? state;
    final stored = await _loadSyncState(accountId, resumeKey);
    if (stored != null) {
      try {
        final decoded = jsonDecode(stored) as Map<String, dynamic>;
        final a = decoded['anchor'] as String?;
        final t = decoded['state'] as String?;
        if (a != null && t != null) {
          anchor = a;
          state = t;
        }
      } catch (e) {
        log(
          'JMAP-sync: unreadable full-sync resume point for '
          'mailbox=$mailboxJmapId ($e) — starting over',
        );
      }
    }
    var resumed = anchor != null;
    if (resumed) {
      log(
        'JMAP-sync: resuming full sync mailbox=$mailboxJmapId anchor=$anchor',
      );
    }

    var fetched = 0;
    var bytes = 0;
    var pages = 0;
    int? reportedTotal;
    var truncated = false;
    var drained = false;
    var restartedOnce = false;
    final seenIds = <String>{};

    while (pages < _jmapFullSyncPagesPerRun) {
      // Anchor-based once we have an anchor (resumed, or after page one of a
      // fresh run); `position: 0` only for the very first page of a fresh run.
      final query = <String, dynamic>{
        'accountId': jmap.accountId,
        'filter': {'inMailbox': mailboxJmapId},
        'sort': [
          {'property': 'receivedAt', 'isAscending': false},
        ],
        'limit': _jmapPageSize,
        'calculateTotal': true,
        if (anchor != null) ...{'anchor': anchor, 'anchorOffset': 1} else
          'position': 0,
      };
      final methodCalls = <List<dynamic>>[
        ['Email/query', query, '0'],
        // `Email/get` with an empty `ids` list returns the Email state and
        // nothing else (RFC 8620 §5.1 — `ids: null` would mean *every* email).
        // Captured once, before any body is fetched, so a change landing
        // during a long full sync is picked up by the next incremental sweep.
        // Reused across runs via the resume point rather than re-probed.
        if (state == null)
          [
            'Email/get',
            {'accountId': jmap.accountId, 'ids': <String>[]},
            '1',
          ],
      ];
      final responses = await jmap.call(methodCalls);

      // A resumed run's anchor may have been destroyed since it was stored.
      // The server then cannot place the anchor in the result set and returns
      // `anchorNotFound`; restart the whole mailbox from the top, once.
      final triple = responses[0] as List<dynamic>;
      if (triple[0] == 'error') {
        final type = (triple[1] as Map<String, dynamic>)['type'];
        if (type == 'anchorNotFound' && !restartedOnce) {
          log(
            'JMAP-sync: full-sync anchor gone for mailbox=$mailboxJmapId — '
            'restarting from the top',
          );
          await _clearSyncState(accountId, resumeKey);
          anchor = null;
          state = null;
          resumed = false;
          restartedOnce = true;
          seenIds.clear();
          fetched = 0;
          bytes = 0;
          pages = 0;
          reportedTotal = null;
          continue;
        }
        throw JmapException('Email/query error: $type');
      }

      final queryResult = triple[1] as Map<String, dynamic>;
      final ids = List<String>.from(queryResult['ids'] as List);
      reportedTotal = (queryResult['total'] as int?) ?? reportedTotal;
      state ??= _responseArgs(responses, 1, 'Email/get')['state'] as String;
      final seenBefore = seenIds.length;
      seenIds.addAll(ids);

      final batched = await _fetchJmapEmailBatches(
        accountId,
        jmap,
        ids,
        mailboxJmapId: mailboxJmapId,
        deleteMissing: false,
      );
      fetched += batched.fetched;
      bytes += batched.bytes;
      pages++;

      if (ids.isEmpty) {
        drained = true;
        break;
      }
      anchor = ids.last;
      // A page that adds nothing new means the server is not honouring the
      // anchor (or a proxy is replaying a response). Stop rather than
      // re-fetching the same bodies up to the page cap.
      if (seenIds.length == seenBefore) {
        truncated = true;
        log(
          'JMAP-sync: full mailbox=$mailboxJmapId stalled — Email/query '
          'stopped returning new ids',
        );
        break;
      }
      // Prefer the server's own count; fall back to "a short page is the end"
      // only when it does not report one. Not breaking outright on an absent
      // total: that used to truncate a mailbox to its first page.
      if (reportedTotal != null) {
        if (seenIds.length >= reportedTotal) {
          drained = true;
          break;
        }
      } else if (ids.length < _jmapPageSize) {
        drained = true;
        break;
      }
    }

    if (truncated) {
      // Checkpointing here would be the worst outcome available: storing the
      // state switches the mailbox to the incremental path, and
      // `Email/changes` only reports what happened after it, so everything the
      // truncated walk never reached would be unreachable by any path. Leave
      // the mailbox on the full-sync path (resume key untouched) to retry.
      unawaited(
        _appLogger?.warn(
          'jmap_sync.full_sync_truncated',
          'Full sync of a mailbox stopped before the end; it will be retried',
          accountId: accountId,
          data: {
            'mailbox': mailboxJmapId,
            'pages': pages,
            'seen': seenIds.length,
            'total': reportedTotal,
          },
        ),
      );
      return model.SyncEmailsResult(
        fetched: fetched,
        skipped: 0,
        bytesTransferred: bytes,
      );
    }

    final reconcileKey = 'JMAP:Reconcile:$mailboxJmapId';

    if (!drained) {
      // Paused at the per-run page cap. Persist the anchor so the next cycle
      // continues, and leave `JMAP:Email:` unset so path selection keeps this
      // mailbox on the full-sync path. Stamp the reconcile marker to keep the
      // periodic pass from walking a half-synced mailbox every cycle.
      await _saveSyncState(
        accountId,
        resumeKey,
        jsonEncode({'anchor': anchor, 'state': state}),
      );
      await _saveSyncState(
        accountId,
        reconcileKey,
        DateTime.now().toIso8601String(),
      );
      log(
        'JMAP-sync: full mailbox=$mailboxJmapId paused after $pages page(s), '
        'fetched=$fetched anchor=$anchor',
      );
      return model.SyncEmailsResult(
        fetched: fetched,
        skipped: 0,
        bytesTransferred: bytes,
      );
    }

    // Drained. `seenIds` covers the whole mailbox only for a fresh sync that
    // finished in one invocation; a sync spread over several runs holds just
    // the final run's pages, so it cannot prune — the other runs' ids would
    // all look absent and be deleted. Hand pruning to the periodic reconcile,
    // which re-lists the mailbox from scratch (and, post-#1016, declines
    // safely if that listing is itself incomplete).
    final complete =
        !resumed && _jmapEnumerationComplete(seenIds, reportedTotal);
    var pruned = 0;
    if (complete) {
      pruned = await _pruneJmapMailboxToServerIds(
        accountId,
        mailboxJmapId,
        seenIds,
      );
    }
    log(
      'JMAP-sync: full mailbox=$mailboxJmapId fetched=$fetched pruned=$pruned '
      'complete=$complete resumed=$resumed total=$reportedTotal',
    );

    await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', state!);
    await _clearSyncState(accountId, resumeKey);
    if (complete) {
      // Pruned exhaustively just now, so hold the periodic pass off for its
      // normal interval.
      await _saveSyncState(
        accountId,
        reconcileKey,
        DateTime.now().toIso8601String(),
      );
    } else {
      // Nothing was pruned (a resumed drain can't), so make the reconcile due
      // now rather than leaving a stamp to defer it: `_syncEmailsJmap` runs it
      // immediately after this returns.
      await _clearSyncState(accountId, reconcileKey);
    }
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  /// Upper bound on how many ids `Email/changes` may report per request
  /// (RFC 8620 §5.2 `maxChanges`). Without it a long-dormant mailbox hands
  /// back its entire backlog in one response, which then has to be fetched in
  /// one `Email/get` — see [_jmapGetBatchSize].
  static const _jmapMaxChanges = 200;

  /// Upper bound on how many ids go into a single `Email/get`.
  ///
  /// The incremental sweep asks for full bodies (`fetchHTMLBodyValues` /
  /// `fetchTextBodyValues`) plus attachment metadata, so one request for an
  /// unbounded id list makes the server serialize every body before it can
  /// answer. That blows past the client's request timeout, the cycle dies with
  /// a misleading "could not reach the mail server", and because no state is
  /// checkpointed the next cycle asks for the same oversized page again — the
  /// account never catches up (issue #967).
  static const _jmapGetBatchSize = 50;

  /// How many `Email/changes` pages one `syncEmails` call will drain.
  ///
  /// Checkpointing per page means stopping early costs nothing — the next
  /// cycle resumes from the stored token — so a huge backlog is drained over
  /// several cycles instead of one run long enough for a background job to be
  /// killed in the middle of. Also bounds the loop against a server that
  /// hands out a fresh token on every page while never clearing
  /// `hasMoreChanges`.
  static const _jmapMaxPagesPerSync = 20;

  /// Fetches [ids] in `Email/get` batches of [_jmapGetBatchSize], upserting
  /// each batch as it arrives. Returns how many emails were stored and how
  /// many bytes that was.
  ///
  /// Batched because the request also asks for full bodies: one `Email/get`
  /// for an unbounded id list makes the server read and serialize every
  /// message before it can answer, which is what blew past the request
  /// timeout in #967.
  /// Set [deleteMissing] false when the caller has its own, safer reconciler.
  /// The full sync finishes with [_pruneJmapMailboxToServerIds], which keeps
  /// everything `Email/query` listed and skips rows that are local-only
  /// (#545) or carry an unflushed optimistic move/snooze. Deleting here would
  /// pre-empt that with neither guard, so a pending offline move of a message
  /// another client had already destroyed would take the local row with it.
  Future<({int fetched, int bytes})> _fetchJmapEmailBatches(
    String accountId,
    JmapClient jmap,
    List<String> ids, {
    String? mailboxJmapId,
    bool deleteMissing = true,
  }) async {
    var fetched = 0;
    var bytes = 0;
    for (var i = 0; i < ids.length; i += _jmapGetBatchSize) {
      final batch = ids.sublist(
        i,
        math.min(i + _jmapGetBatchSize, ids.length),
      );
      final flagRead = await _startServerFlagRead(accountId);
      final Map<String, dynamic> result;
      final List<dynamic> list;
      try {
        final responses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': batch,
              'properties': _emailProperties,
              ..._emailGetBodyOptions,
            },
            '0',
          ],
        ]);
        result = _responseArgs(responses, 0, 'Email/get');
        list = result['list'] as List<dynamic>;
        bytes += await _upsertJmapEmails(
          accountId,
          list,
          currentMailboxJmapId: mailboxJmapId,
          flagRead: flagRead,
        );
      } finally {
        _endServerFlagRead();
      }
      fetched += list.length;

      if (!deleteMissing) continue;
      // RFC 8620 §5.1: the server names every requested id it does not have,
      // in `notFound`. Only ids it names there are deleted.
      //
      // This used to infer absence by subtracting the returned ids from the
      // batch, which read *any* short response as a deletion order — a
      // truncated list, or one object the server failed to serialize, and the
      // mail was gone locally. Verified against Stalwart 0.14.1, which
      // populates the field for absent and destroyed ids alike, including
      // alongside the body options this request sends.
      //
      // Parsed defensively on purpose: this field was inert before, and a
      // throw here would escape before the page's state is checkpointed,
      // stalling the mailbox permanently on the same page — the failure shape
      // [_jmapGetBatchSize] exists to prevent. Junk therefore means "delete
      // nothing".
      //
      // Keeping a row the server merely omitted costs a stale row rather than
      // costing mail: the periodic [_maybeReconcileJmapMailbox] prune clears
      // genuine ghosts. Not instantly and not unconditionally, though — the
      // interval is 15 minutes *per successful sync of that mailbox*, so on a
      // device syncing in the background the real window is longer, and a
      // mailbox the sync loop skips entirely (`isDuplicateOfOtherFolders`,
      // i.e. role `all`) is never reconciled at all. Worth it for a stale
      // row; it would not be worth it for lost mail, which is the trade.
      final rawNotFound = result['notFound'];
      final notFound = rawNotFound is List
          ? rawNotFound.whereType<String>().toSet()
          : const <String>{};

      final returnedIds = <String>{
        for (final e in list) (e as Map<String, dynamic>)['id'] as String,
      };

      // An id the server both returned and disclaimed is contradictory; keep
      // what it handed over. Without this the row would be upserted above and
      // deleted below, losing a message the server did supply — worse than
      // the subtraction this replaced.
      final missing = [
        for (final jmapId in batch)
          if (notFound.contains(jmapId) && !returnedIds.contains(jmapId))
            jmapId,
      ];

      // Computed for every batch, not just when nothing was disclaimed: a
      // response that names one id and silently drops another is exactly the
      // partial response this change is about, and it has a non-empty
      // `missing`.
      final unaccounted = [
        for (final jmapId in batch)
          if (!returnedIds.contains(jmapId) && !notFound.contains(jmapId))
            jmapId,
      ];
      if (unaccounted.isNotEmpty) {
        unawaited(
          _appLogger?.warn(
            'jmap_sync.email_get_incomplete',
            'Email/get neither returned nor disclaimed '
                '${unaccounted.length} of ${batch.length} requested ids — '
                'keeping those rows',
            accountId: accountId,
            data: {
              'mailbox': mailboxJmapId,
              'requested': batch.length,
              'returned': returnedIds.length,
              'notFound': notFound.length,
              'unaccounted': _briefIds(unaccounted),
            },
          ),
        );
      }

      if (missing.isEmpty) continue;
      // Guarded: a row carrying any unflushed user edit is held back, so a
      // queued change always has a row to apply to. Not a promise the mail
      // survives — the unguarded `destroyed` loop below deletes it once the
      // server reports it explicitly, and the periodic prune clears it
      // otherwise. It delays deletion until something else confirms it.
      //
      // The guard is "has an unflushed mutation of any kind", not the
      // move/snooze subset [_pruneJmapMailboxToServerIds] uses. That subset is
      // right for a *mailbox-scoped* walk, where an optimistic move has
      // already rewritten `mailboxPath` and makes the row look orphaned from
      // both folders. This path is keyed by id, so the only thing that matters
      // is whether the user has an edit in flight — an unflushed star counts
      // just as much as an unflushed move.
      //
      // Deliberately inside the loop: `_upsertJmapEmails` can enqueue changes
      // of its own via the #545 dissolve, so hoisting this lookup out would
      // read a stale set.
      final inFlight = await _inFlightFlagResourceIds(accountId);
      for (final jmapId in missing) {
        if (inFlight.contains('$accountId:$jmapId')) {
          log(
            'JMAP-sync: Email/get disclaimed $jmapId but an edit is still '
            'queued for it — keeping the row for now',
          );
          continue;
        }
        await _deleteJmapEmailById(accountId, jmapId);
      }
    }
    return (fetched: fetched, bytes: bytes);
  }

  /// Requests one page of `Email/changes`.
  ///
  /// [maxChanges] is nullable so the caller can retry unbounded: RFC 8620 §5.2
  /// allows a server to answer `cannotCalculateChanges` when it cannot produce
  /// an update to an intermediate state, which a bounded request is what asks
  /// it for. Retrying without the bound tells a server that merely dislikes
  /// windowing apart from one whose stored state is genuinely too old.
  Future<List<dynamic>> _jmapEmailChanges(
    JmapClient jmap,
    String sinceState, {
    required int? maxChanges,
  }) async {
    final responses = await jmap.call([
      [
        'Email/changes',
        {
          'accountId': jmap.accountId,
          'sinceState': sinceState,
          if (maxChanges != null) 'maxChanges': maxChanges,
        },
        '0',
      ],
    ]);
    return responses[0] as List<dynamic>;
  }

  Future<model.SyncEmailsResult> _jmapIncrementalEmailSync(
    String accountId,
    JmapClient jmap,
    String sinceState, {
    String? mailboxJmapId,
  }) async {
    var fetched = 0;
    var bytes = 0;
    var state = sinceState;

    // RFC 8620 §5.2: /changes is a paged API. Ask for a bounded window and
    // keep going while the server reports `hasMoreChanges`, so a backlog is
    // drained over several small requests that each finish well inside the
    // request timeout.
    for (var page = 0; page < _jmapMaxPagesPerSync; page++) {
      var triple = await _jmapEmailChanges(
        jmap,
        state,
        maxChanges: _jmapMaxChanges,
      );

      // RFC 8620 §5.2 lists cannotCalculateChanges both for a sinceState the
      // server can no longer resolve (GC after long inactivity) and for one it
      // cannot step to an intermediate state from. Only the bounded request
      // can provoke the second, so retry unbounded before concluding the
      // stored state is dead and forcing a full resync.
      if (triple[0] == 'error' &&
          (triple[1] as Map<String, dynamic>)['type'] ==
              'cannotCalculateChanges') {
        log(
          'JMAP-sync: Email/changes refused a bounded window for '
          'mailbox=$mailboxJmapId — retrying without maxChanges',
        );
        triple = await _jmapEmailChanges(jmap, state, maxChanges: null);
      }

      if (triple[0] == 'error') {
        final err = triple[1] as Map<String, dynamic>;
        final type = err['type'] as String?;
        log(
          'JMAP-sync: Email/changes error type=$type mailbox=$mailboxJmapId '
          'sinceState=$state — falling back to full sync',
        );
        if (type == 'cannotCalculateChanges') {
          await _clearJmapSyncState(accountId, mailboxJmapId);
          if (mailboxJmapId != null) {
            // Keep whatever earlier pages already stored: the full sync is
            // exhaustive, but its counters only cover what it fetched itself.
            final full =
                await _jmapFullEmailSync(accountId, jmap, mailboxJmapId);
            return model.SyncEmailsResult(
              fetched: fetched + full.fetched,
              skipped: full.skipped,
              bytesTransferred: bytes + full.bytesTransferred,
            );
          }
        }
        throw JmapException('Email/changes error: $type');
      }

      final changes = triple[1] as Map<String, dynamic>;
      final newState = changes['newState'] as String;
      final created = List<String>.from(changes['created'] as List? ?? []);
      final updated = List<String>.from(changes['updated'] as List? ?? []);
      final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);
      final hasMoreChanges = changes['hasMoreChanges'] as bool? ?? false;

      log(
        'JMAP-sync: incremental mailbox=$mailboxJmapId '
        '$state → $newState '
        'created=${_briefIds(created)} '
        'updated=${_briefIds(updated)} '
        'destroyed=${_briefIds(destroyed)} '
        'hasMoreChanges=$hasMoreChanges',
      );

      final batched = await _fetchJmapEmailBatches(
        accountId,
        jmap,
        [...created, ...updated],
        mailboxJmapId: mailboxJmapId,
      );
      fetched += batched.fetched;
      bytes += batched.bytes;

      for (final jmapId in destroyed) {
        await _deleteJmapEmailById(accountId, jmapId);
      }

      // Checkpoint every page. A failure in a later page then costs one page
      // on the next cycle instead of replaying the whole backlog — which is
      // the half of #967 that made the account never catch up.
      await _saveSyncState(accountId, 'Email', newState);
      if (mailboxJmapId != null) {
        await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', newState);
      }

      // Caught up.
      if (!hasMoreChanges) {
        return model.SyncEmailsResult(
          fetched: fetched,
          skipped: 0,
          bytesTransferred: bytes,
        );
      }

      // A server that reports more changes without advancing the state token
      // would spin this loop forever. Stop and let the next cycle retry.
      // (Verified against Stalwart 0.14, which always advances.)
      if (newState == state) {
        log(
          'JMAP-sync: Email/changes reported hasMoreChanges without advancing '
          'state ($state) for mailbox=$mailboxJmapId — stopping this run',
        );
        break;
      }
      state = newState;
    }

    // Out of pages. The state is checkpointed, so the next cycle resumes from
    // here rather than starting over; draining a large backlog over several
    // cycles beats one request run that a background job will be killed in
    // the middle of.
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  /// Deletes the row for a server-side id.
  ///
  /// Unlike [_pruneJmapMailboxToServerIds] this needs no `isLocal` guard: that
  /// one walks every row in a mailbox, where local self-sent "virtual" rows
  /// (#545) genuinely appear, whereas this is keyed by an id the server gave
  /// us and a virtual row's id is `<account>:__local__:<message-id>`, which no
  /// server can produce.
  Future<void> _deleteJmapEmailById(String accountId, String jmapId) async {
    final dbId = '$accountId:$jmapId';
    final email = await getEmail(dbId);
    if (email == null) return;
    final tid = email.threadId ?? dbId;
    final mailbox = email.mailboxPath;
    await (_db.delete(_db.emails)..where((t) => t.id.equals(dbId))).go();
    await _updateThread(accountId, mailbox, tid);
  }

  Future<void> _clearJmapSyncState(
    String accountId,
    String? mailboxJmapId,
  ) async {
    // Scoped to the one mailbox when we have it. Clearing every
    // `JMAP:Email:%` row would force a full resync of every folder in the
    // account over one folder's unresolvable state — and bounded
    // `Email/changes` requests make that error reachable where it was not
    // before (#967).
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (mailboxJmapId == null
                    ? (t.resourceType.equals('Email') |
                        t.resourceType.like('JMAP:Email:%') |
                        t.resourceType.like('JMAP:FullSync:%'))
                    : (t.resourceType.equals('Email') |
                        t.resourceType.equals('JMAP:Email:$mailboxJmapId') |
                        t.resourceType.equals('JMAP:FullSync:$mailboxJmapId'))),
          ))
        .go();
  }

  /// Row ids whose optimistic move, snooze or unsnooze has not been flushed
  /// yet, so a mailbox-scoped reconciler must not delete them mid-flight: the
  /// move has already rewritten `mailboxPath`, which makes the row look
  /// orphaned from the folder it left and the one it has not arrived in.
  ///
  /// For a guard that only needs "does the user have an edit in flight", use
  /// [_inFlightFlagResourceIds] — it covers flag edits and deletes too.
  /// A failed move or snooze is not counted: its row follows the server.
  Future<Set<String>> _rowsWithUnflushedMoveOrSnooze(String accountId) async {
    final ids = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.state.isIn(_liveStates) &
                _db.pendingChanges.changeType.isIn(
                  const ['move', 'snooze', 'unsnooze'],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    return ids.toSet();
  }

  /// Deletes local email rows for [mailboxJmapId] whose id isn't in the
  /// authoritative [serverIds] set. Returns the number of rows removed.
  ///
  /// Mirrors [_reconcileDeletedImap]: skips rows with a pending optimistic
  /// move/snooze so we don't wipe them mid-flight, and updates affected
  /// threads. `serverIds` are raw JMAP email ids (no `accountId:` prefix).
  Future<int> _pruneJmapMailboxToServerIds(
    String accountId,
    String mailboxJmapId,
    Set<String> serverIds,
  ) async {
    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();

    final inFlightSet = await _rowsWithUnflushedMoveOrSnooze(accountId);

    final affectedThreads = <String>{};
    var removed = 0;
    for (final row in localRows) {
      // Local self-sent "virtual" rows have no server counterpart and must
      // survive until the real message arrives and dissolves them (#545).
      if (row.isLocal) continue;
      final jmapId = row.id.substring('$accountId:'.length);
      if (serverIds.contains(jmapId)) continue;
      if (inFlightSet.contains(row.id)) continue;
      affectedThreads.add(row.threadId ?? row.id);
      await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      removed++;
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxJmapId, tid);
    }
    return removed;
  }

  static const _jmapReconcileInterval = Duration(minutes: 15);

  /// Periodic safety net: at most once per [_jmapReconcileInterval] per
  /// mailbox, list all server-side email ids in [mailboxJmapId] and prune
  /// local rows no longer present. Also refreshes `keywords` for every
  /// email still in the mailbox and rewrites `isSeen` / `isFlagged` from
  /// server truth. Catches ghosts and flag drift from Email/changes
  /// under-reporting — Stalwart's IMAP-triggered mailbox moves have surfaced
  /// this for existence (#262) and Stalwart 0.14.x similarly under-reports
  /// keyword changes to the paired IMAP account, causing "seen" drift on the
  /// compare view (#407).
  Future<void> _maybeReconcileJmapMailbox(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    final key = 'JMAP:Reconcile:$mailboxJmapId';
    final last = await _loadSyncState(accountId, key);
    final dueValue = await _loadSyncState(
      accountId,
      _flagReconcileDueKey(mailboxJmapId, jmap: true),
    );
    if (last != null && dueValue == null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _jmapReconcileInterval) {
        return;
      }
    }

    final serverIds = <String>{};
    int position = 0;
    var pages = 0;
    int? reportedTotal;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            // Same explicit sort as the full sync. Position paging over a
            // server-chosen default order is free to duplicate and skip ids
            // between pages, which this pass would then read as an incomplete
            // walk and decline to prune on.
            'sort': [
              {'property': 'receivedAt', 'isAscending': false},
            ],
            'limit': _jmapPageSize,
            'position': position,
            'calculateTotal': true,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      reportedTotal = (queryResult['total'] as int?) ?? reportedTotal;
      final seenBefore = serverIds.length;
      serverIds.addAll(ids);
      position += ids.length;
      pages++;
      if (ids.isEmpty) break;
      if (serverIds.length == seenBefore) break;
      if (reportedTotal != null) {
        if (position >= reportedTotal) break;
      } else if (ids.length < _jmapPageSize) {
        break;
      }
      if (pages >= _jmapMaxQueryPages) break;
    }

    // Only the prune is gated. An enumeration this pass cannot vouch for is
    // the most dangerous input in the file — it runs on every mailbox, so one
    // bad `Email/query` used to be enough to empty a folder — but the work
    // below it is safe on a partial set and must not be skipped with it:
    // `_reconcileJmapFlagsForMailbox` only touches rows the walk *did* see,
    // and `_sweepOrphanThreads` only removes threads with no emails left.
    // Skipping them would mean flag drift (#407) and phantom threads (#523)
    // were never corrected for exactly the mailboxes having trouble.
    if (_jmapEnumerationComplete(serverIds, reportedTotal)) {
      final removed = await _pruneJmapMailboxToServerIds(
        accountId,
        mailboxJmapId,
        serverIds,
      );
      if (removed > 0) {
        log(
          'JMAP-sync: reconcile mailbox=$mailboxJmapId pruned=$removed '
          '(server=${serverIds.length})',
        );
      }
    } else {
      log(
        'JMAP-sync: reconcile mailbox=$mailboxJmapId walked ${serverIds.length}'
        ' of ${reportedTotal ?? -1} after $pages page(s) — skipping the prune',
      );
    }
    await _reconcileJmapFlagsForMailbox(
      accountId,
      jmap,
      mailboxJmapId,
      serverIds,
    );
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
    await _settleFlagReconcileDue(
      accountId,
      mailboxJmapId,
      jmap: true,
      dueValue: dueValue,
    );
  }

  /// Fetches `keywords` for every local row in [mailboxJmapId] whose JMAP id
  /// is still on the server and rewrites `isSeen` / `isFlagged` from truth.
  /// Skips rows whose flag change is still queued in `pendingChanges` so an
  /// unflushed optimistic edit is not silently reverted.
  Future<void> _reconcileJmapFlagsForMailbox(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
    Set<String> serverIds,
  ) async {
    if (serverIds.isEmpty) return;

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxJmapId),
          ))
        .get();
    if (localRows.isEmpty) return;

    final localByJmapId = <String, Email>{
      for (final r in localRows) r.id.substring('$accountId:'.length): r,
    };

    final inFlightSet = await _inFlightFlagResourceIds(accountId);

    final toCheck = [
      for (final jmapId in localByJmapId.keys)
        if (serverIds.contains(jmapId) &&
            !inFlightSet.contains(localByJmapId[jmapId]!.id))
          jmapId,
    ];
    if (toCheck.isEmpty) return;

    final affectedThreads = <String>{};
    final sizeById = <String, int>{};
    var corrected = 0;
    for (var offset = 0; offset < toCheck.length; offset += _jmapPageSize) {
      final batch = toCheck.sublist(
        offset,
        math.min(offset + _jmapPageSize, toCheck.length),
      );
      final flagRead = await _startServerFlagRead(accountId);
      try {
        final responses = await jmap.call([
          [
            'Email/get',
            {
              'accountId': jmap.accountId,
              'ids': batch,
              // `size` backfills rows cached before schema v64.
              'properties': ['id', 'keywords', 'size'],
            },
            '0',
          ],
        ]);
        final getResult = _responseArgs(responses, 0, 'Email/get');
        final list = getResult['list'] as List<dynamic>;
        final queuedNow = await _inFlightFlagResourceIds(accountId);
        for (final e in list) {
          final m = e as Map<String, dynamic>;
          final jmapId = m['id'] as String;
          final row = localByJmapId[jmapId];
          if (row == null) continue;
          final size = m['size'];
          if (row.sizeBytes == null && size is int) sizeById[row.id] = size;
          final keywords = (m['keywords'] as Map<String, dynamic>?) ?? {};
          final serverSeen = keywords.containsKey(r'$seen');
          final serverFlagged = keywords.containsKey(r'$flagged');
          if (serverSeen == row.isSeen && serverFlagged == row.isFlagged) {
            continue;
          }
          // `row` was read before the first batch; a change made since is
          // newer than this answer.
          if (flagRead.protects(row.id, queuedNow)) continue;
          await (_db.update(_db.emails)..where((t) => t.id.equals(row.id)))
              .write(
            EmailsCompanion(
              isSeen: Value(serverSeen),
              isFlagged: Value(serverFlagged),
            ),
          );
          affectedThreads.add(row.threadId ?? row.id);
          corrected++;
        }
      } finally {
        _endServerFlagRead();
      }
    }

    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxJmapId, tid);
    }
    await _backfillSizes(sizeById);
    if (corrected > 0) {
      log(
        'JMAP-sync: flag-reconcile mailbox=$mailboxJmapId corrected=$corrected '
        '(checked=${toCheck.length}, local=${localRows.length})',
      );
    }
  }

  String _briefIds(List<String> ids, {int keep = 10}) {
    if (ids.length <= keep) return '${ids.length}:$ids';
    return '${ids.length}:${ids.take(keep).toList()}+${ids.length - keep} more';
  }

  // Returns total bytes transferred (sum of JMAP `size` fields).
  //
  // [currentMailboxJmapId], when provided, is the mailbox whose sync triggered
  // this fetch. It is used to pick a stable [mailboxPath] for messages that
  // are members of multiple mailboxes: we prefer the row's existing
  // `mailboxPath` when it's still a member, then [currentMailboxJmapId], and
  // finally any remaining membership. Without this, `Map.keys.firstOrNull`
  // picks an arbitrary mailbox and a message moved out of [currentMailboxJmapId]
  // may keep showing there indefinitely (#262).
  Future<int> _upsertJmapEmails(
    String accountId,
    List<dynamic> emails, {
    String? currentMailboxJmapId,
    required _ServerFlagRead flagRead,
  }) async {
    var bytes = 0;
    final queuedNow = await _inFlightFlagResourceIds(accountId);
    final affectedByMailbox = <String, Set<String>>{};
    // (mailboxPath, realEmailId, messageId) of each row we just wrote — checked
    // afterwards for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String, String?)>[];
    // (emailId, mailboxPath, subject, size) of each row stored for the first
    // time — logged so "Show Logs" starts with the fetch (#920).
    final newlyStored = <(String, String, String?, int?)>[];
    for (final e in emails) {
      final m = e as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      final dbId = '$accountId:$jmapId';
      bytes += (m['size'] as int?) ?? 0;

      final mailboxIds = m['mailboxIds'] as Map<String, dynamic>?;

      // If the mail is no longer in any mailbox, treat it as gone. This
      // shouldn't normally reach us via Email/get (destroyed mails end up in
      // Email/changes.destroyed) but is defensive against unusual server
      // states where mailboxIds is empty.
      if (mailboxIds == null || mailboxIds.isEmpty) {
        final existing = await getEmail(dbId);
        if (existing != null) {
          final tid = existing.threadId ?? dbId;
          final oldMailbox = existing.mailboxPath;
          await (_db.delete(_db.emails)..where((t) => t.id.equals(dbId))).go();
          affectedByMailbox.putIfAbsent(oldMailbox, () => {}).add(tid);
        }
        continue;
      }

      final existingRow = await (_db.select(_db.emails)
            ..where((t) => t.id.equals(dbId)))
          .getSingleOrNull();
      final String mailboxPath;
      if (existingRow != null &&
          mailboxIds.containsKey(existingRow.mailboxPath)) {
        // Stable: keep the mailbox we already display it under.
        mailboxPath = existingRow.mailboxPath;
      } else if (currentMailboxJmapId != null &&
          mailboxIds.containsKey(currentMailboxJmapId)) {
        mailboxPath = currentMailboxJmapId;
      } else {
        mailboxPath = mailboxIds.keys.first;
      }

      // Membership changed: the mail is no longer in the mailbox where the
      // local row lived (e.g. IMAP "move to Trash" via Thunderbird — #262).
      // Refresh the thread aggregate for the old mailbox so it no longer
      // lists this email; the new mailbox is refreshed below via
      // affectedByMailbox.
      if (existingRow != null && existingRow.mailboxPath != mailboxPath) {
        affectedByMailbox
            .putIfAbsent(existingRow.mailboxPath, () => {})
            .add(existingRow.threadId ?? dbId);
        log(
          'JMAP-sync: mailbox change id=$jmapId '
          '${existingRow.mailboxPath} → $mailboxPath',
        );
      }

      final keywords = m['keywords'] as Map<String, dynamic>? ?? {};
      DateTime? snoozedUntil;
      for (final String k in keywords.keys) {
        if (k.startsWith('snz:')) {
          final ts = k.substring(4);
          if (ts.length >= 15) {
            final formatted =
                '${ts.substring(0, 4)}-${ts.substring(4, 6)}-${ts.substring(6, 8)}T${ts.substring(9, 11)}:${ts.substring(11, 13)}:${ts.substring(13, 15)}Z';
            snoozedUntil = DateTime.tryParse(formatted);
          }
          break;
        }
      }

      final from = _encodeJmapAddresses(m['from'] as List<dynamic>?);
      final to = _encodeJmapAddresses(m['to'] as List<dynamic>?);
      final cc = _encodeJmapAddresses(m['cc'] as List<dynamic>?);
      final replyTo = _encodeJmapAddresses(m['replyTo'] as List<dynamic>?);
      final bcc = _encodeJmapAddresses(m['bcc'] as List<dynamic>?);
      final sentAt = _parseDate(m['sentAt'] as String?);
      final receivedAt =
          _parseDate(m['receivedAt'] as String?) ?? DateTime.now();

      final jmapThreadId = m['threadId'] as String? ?? dbId;
      affectedByMailbox.putIfAbsent(mailboxPath, () => {}).add(jmapThreadId);

      // JMAP messageId/inReplyTo/references are arrays; join to space-separated.
      final jmapMessageId = _joinJmapStringList(
        m['messageId'] as List<dynamic>?,
      );
      final jmapInReplyTo = _joinJmapStringList(
        m['inReplyTo'] as List<dynamic>?,
      );
      final jmapReferences = _joinJmapStringList(
        m['references'] as List<dynamic>?,
      );
      final jmapListUnsubscribe =
          (m['header:List-Unsubscribe:asText'] as String?)?.trim();
      // Re-decode Subject from the raw header when the server exposes it, so
      // we get the same defensive handling as the IMAP path (#418). Falls
      // back to the server-decoded `subject` property when the raw header is
      // absent (e.g. mail with no Subject at all, or servers that reject
      // `header:*:asRaw`).
      final rawSubjectHeader = m['header:Subject:asRaw'] as String?;
      final subject = rawSubjectHeader != null
          ? (decodeMailHeader(rawSubjectHeader) ?? m['subject'] as String?)
          : m['subject'] as String?;

      // An existing row the user just changed keeps its read/star state:
      // this answer may predate the change (or the change is still queued).
      final keepLocalFlags =
          existingRow != null && flagRead.protects(dbId, queuedNow);

      await _db.into(_db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: dbId,
              accountId: accountId,
              mailboxPath: mailboxPath,
              uid: 0, // not used for JMAP accounts
              subject: Value(subject),
              sentAt: Value(sentAt),
              receivedAt: receivedAt,
              fromJson: Value(from),
              toAddresses: Value(to),
              ccJson: Value(cc),
              replyToJson: Value(replyTo),
              bccJson: Value(bcc),
              sizeBytes: m['size'] is int
                  ? Value(m['size'] as int)
                  : const Value.absent(),
              preview: Value(m['preview'] as String?),
              // Absent leaves the stored value alone on conflict.
              isSeen: keepLocalFlags
                  ? const Value.absent()
                  : Value(keywords.containsKey(r'$seen')),
              isFlagged: keepLocalFlags
                  ? const Value.absent()
                  : Value(keywords.containsKey(r'$flagged')),
              // Server-defined (RFC 8621); IMAP instead counts
              // Content-Disposition: attachment parts.
              hasAttachment: Value((m['hasAttachment'] as bool?) ?? false),
              threadId: Value(jmapThreadId),
              messageId: Value(jmapMessageId),
              inReplyTo: Value(jmapInReplyTo),
              references: Value(jmapReferences),
              snoozedUntil: Value(snoozedUntil),
              listUnsubscribeHeader: Value(jmapListUnsubscribe),
            ),
          );

      // Cache body if the server included bodyValues in this response.
      if (m.containsKey('bodyValues')) {
        final (textBody, htmlBody, attachmentsJson) = _parseJmapBody(m);
        await _db.into(_db.emailBodies).insertOnConflictUpdate(
              EmailBodiesCompanion.insert(
                emailId: dbId,
                textBody: Value(textBody),
                htmlBody: Value(htmlBody),
                attachmentsJson: Value(attachmentsJson),
                cachedAt: Value(DateTime.now()),
                bodySize: Value(_bodySize(textBody, htmlBody)),
              ),
            );
      }
      dissolveCandidates.add((mailboxPath, dbId, jmapMessageId));
      if (existingRow == null) {
        newlyStored.add((dbId, mailboxPath, subject, m['size'] as int?));
      }
    }
    for (final (emailId, mailboxPath, subject, size) in newlyStored) {
      _logEmailFetched(
        emailId: emailId,
        accountId: accountId,
        mailboxPath: mailboxPath,
        protocol: 'jmap',
        subject: subject,
        bytes: size,
      );
    }

    for (final mailboxPath in affectedByMailbox.keys) {
      for (final tid in affectedByMailbox[mailboxPath]!) {
        await _updateThread(accountId, mailboxPath, tid);
      }
    }
    if (dissolveCandidates.isNotEmpty && await _hasLocalMessages(accountId)) {
      for (final (mailboxPath, emailId, msgId) in dissolveCandidates) {
        await _maybeDissolveLocalMessage(
          accountId,
          mailboxPath,
          emailId,
          msgId,
        );
      }
    }
    return bytes;
  }

  /// Extracts text body, HTML body, and attachments JSON from a JMAP Email object
  /// that was fetched with fetchHTMLBodyValues/fetchTextBodyValues.
  (String? textBody, String? htmlBody, String attachmentsJson) _parseJmapBody(
    Map<String, dynamic> m,
  ) {
    final bodyValues = m['bodyValues'] as Map<String, dynamic>? ?? {};
    final textBodyParts = m['textBody'] as List<dynamic>? ?? [];
    final htmlBodyParts = m['htmlBody'] as List<dynamic>? ?? [];
    final jmapAttachments = m['attachments'] as List<dynamic>? ?? [];

    // JMAP's `textBody`/`htmlBody` fall back to the other representation when
    // the message has only one part: an HTML-only mail lists its `text/html`
    // part in `textBody`, and a plain-only mail lists its `text/plain` part in
    // `htmlBody` (RFC 8621 §4.1.4). Storing those cross-typed parts would put
    // raw HTML into `textBody` (and vice versa), which the IMAP path never does
    // — `decodeTextPlainPart()`/`decodeTextHtmlPart()` are type-specific and
    // return null when the matching part is absent. Guard on the part's `type`
    // so both sync paths agree (#514).
    final textBody = _jmapBodyValueOfType(
      textBodyParts,
      bodyValues,
      'text/plain',
    );
    final htmlBody = _jmapBodyValueOfType(
      htmlBodyParts,
      bodyValues,
      'text/html',
    );

    final attachmentsJson = jsonEncode(
      jmapAttachments.map((a) {
        final att = a as Map<String, dynamic>;
        return {
          'filename': att['name'] ?? '',
          'contentType': att['type'] ?? '',
          'size': att['size'] ?? 0,
          'fetchPartId': att['blobId'] ?? '',
        };
      }).toList(),
    );

    return (textBody, htmlBody, attachmentsJson);
  }

  @visibleForTesting
  (String? textBody, String? htmlBody, String attachmentsJson)
      parseJmapBodyForTest(Map<String, dynamic> m) => _parseJmapBody(m);

  /// Resolves the decoded value of the first [bodyParts] entry, but only when
  /// its MIME `type` equals [expectedType]. Returns null otherwise, so a
  /// cross-typed fallback part (HTML listed under `textBody`, or plain text
  /// listed under `htmlBody`) is not stored as if it were the other kind.
  static String? _jmapBodyValueOfType(
    List<dynamic> bodyParts,
    Map<String, dynamic> bodyValues,
    String expectedType,
  ) {
    if (bodyParts.isEmpty) return null;
    final part = bodyParts.first as Map<String, dynamic>;
    final type = (part['type'] as String?)?.toLowerCase();
    if (type != expectedType) return null;
    final partId = part['partId'] as String?;
    if (partId == null) return null;
    return (bodyValues[partId] as Map<String, dynamic>?)?['value'] as String?;
  }

  // ── Pending-change helpers ────────────────────────────────────────────────

  /// Records a failure that may pass for [row]: increments the attempt
  /// count and stores the error message. From [_maxChangeAttempts] attempts
  /// on the row is [_stuckState]: still protecting the user's local value,
  /// retried after [_stuckBackoff]. A refusal that retrying cannot fix goes
  /// through [_markChangeFailed] instead.
  Future<void> _recordChangeError(PendingChangeRow row, Object error) async {
    final next = row.attempts + 1;
    final gaveUp = next >= _maxChangeAttempts;
    final nextTry = gaveUp ? _now().add(_stuckBackoff(next)) : null;
    var owned = false;
    await _db.transaction(() async {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(
        PendingChangesCompanion(
          attempts: Value(next),
          lastError: Value(error.toString()),
          state: Value(gaveUp ? _stuckState : _pendingState),
          leaseUntil: Value(nextTry),
          claimToken: const Value(null),
        ),
      );
      owned = count > 0;
    });
    if (!owned) {
      log('Pending change ${row.id}: claim lost meanwhile, outcome dropped');
      return;
    }

    // Mirror the failure into the App Log so a failed delete/move/flag is
    // discoverable in the per-message "Show Logs" view and in bug reports —
    // previously it was only written to `pending_changes.lastError` and stayed
    // silent (#579), unlike the outbox path (see [_outboxLogObserver]).
    final data = <String, Object?>{
      'changeType': row.changeType,
      'attempts': next,
      'maxAttempts': _maxChangeAttempts,
    };
    if (gaveUp) {
      unawaited(
        _appLogger?.warn(
          'pending_change.stuck',
          'Could not apply ${_describeChange(row)} after $next attempts; '
              'not synced yet, next try at ${_hhmm(nextTry!)}',
          accountId: row.accountId,
          emailId: row.resourceId,
          data: data,
          error: error,
        ),
      );
    } else {
      unawaited(
        _appLogger?.warn(
          'pending_change.retry',
          'Could not apply ${_describeChange(row)} — will retry '
              '(attempt $next of $_maxChangeAttempts)',
          accountId: row.accountId,
          emailId: row.resourceId,
          data: data,
          error: error,
        ),
      );
    }
  }

  /// Marks a claimed [row] [_failedState] at once, without further retries:
  /// the server refused it, or the message it names is gone. Keeps the row
  /// (with [error] and the claimed attempt) for the user to retry or discard.
  /// With [revert], a move's optimistic location is undone as well
  /// ([_revertFailedLocation]); pass false when the message is gone and there
  /// is nothing to go back to.
  Future<bool> _markChangeFailed(
    PendingChangeRow row,
    Object error, {
    bool revert = true,
  }) async {
    final dependents = await _db.transaction(
      () => _markChangeFailedInTransaction(row, error, revert: revert),
    );
    if (dependents == null) return false;
    _logDependentFailures(row, dependents);
    return true;
  }

  /// The database part of [_markChangeFailed], for a caller that runs it in
  /// its own transaction: returns the dependents, to log with
  /// [_logDependentFailures] once that transaction has committed, or null
  /// when the flush no longer owns the claim (nothing written then).
  Future<List<PendingChangeRow>?> _markChangeFailedInTransaction(
    PendingChangeRow row,
    Object error, {
    required bool revert,
  }) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where((t) => _ownsClaim(t, row)))
        .write(
      PendingChangesCompanion(
        attempts: Value(row.attempts + 1),
        lastError: Value(error.toString()),
        state: const Value(_failedState),
        leaseUntil: const Value(null),
        claimToken: const Value(null),
      ),
    );
    if (count == 0) {
      log('Pending change ${row.id}: claim lost meanwhile, outcome dropped');
      return null;
    }
    await _afterFlagFailure(row, revert: revert);
    return _afterLocationFailure(row, revert: revert);
  }

  /// Called (inside the transaction that marked [row] failed) when a read or
  /// star change just became failed: it no longer protects the optimistic
  /// value (#1264), but an unchanged mail is read again only by the
  /// 15-minute flag reconcile (with IMAP CONDSTORE, and always with JMAP),
  /// so the app would show the user's value as if it had applied (#1270).
  ///
  /// Makes the flag reconcile of the mail's folder due, so the next sync
  /// reads server truth, and with [revert] also puts the flag back at once
  /// to its value before the change: the opposite of the requested one,
  /// queued only when the shown value differed. That guess is skipped when
  /// another change of the same flag exists (see below) or something else
  /// already changed the flag; the reconcile sets it right then. A failure
  /// here is logged and rolled back on its own, never taking the failed
  /// state with it.
  Future<void> _afterFlagFailure(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    if (row.changeType != 'flag_seen' && row.changeType != 'flag_flagged') {
      return;
    }
    try {
      await _db.transaction(() => _revertFailedFlag(row, revert: revert));
    } catch (e) {
      log('Could not revert failed change ${row.id}: $e');
    }
  }

  Future<void> _revertFailedFlag(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    final key = row.changeType == 'flag_seen' ? 'seen' : 'flagged';
    final payload = _decodePayload(row);
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final account = await _accounts.getAccount(row.accountId);
    if (account == null) return;
    final jmap = account.type == account_model.AccountType.jmap;
    // The folder the mail is shown in, and for IMAP the one the change
    // addressed (they differ behind a queued move).
    final addressed = jmap ? null : payload?['mailboxPath'];
    for (final folder in {
      if (email != null) email.mailboxPath,
      if (addressed is String) addressed,
    }) {
      await _makeFlagReconcileDue(row.accountId, folder, jmap: jmap);
    }
    if (!revert || email == null || !_sameMessage(row, email.messageId)) {
      return;
    }
    final wanted = payload?[key];
    if (wanted is! bool) return;
    // The value before [row] is known only when no other change of this
    // flag is queued: a later pending one owns the local value, and after
    // an earlier one (pending or failed) the shown value was never server
    // truth.
    final other = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.resourceId) &
                t.id.equals(row.id).not() &
                t.changeType.equals(row.changeType) &
                (t.id.isSmallerThanValue(row.id) | t.state.isIn(_liveStates)),
          )
          ..limit(1))
        .getSingleOrNull();
    if (other != null) return;
    final current = key == 'seen' ? email.isSeen : email.isFlagged;
    if (current != wanted) return;
    await (_db.update(_db.emails)..where((t) => t.id.equals(email.id))).write(
      EmailsCompanion(
        isSeen: key == 'seen' ? Value(!wanted) : const Value.absent(),
        isFlagged: key == 'flagged' ? Value(!wanted) : const Value.absent(),
      ),
    );
    await _updateThread(
      email.accountId,
      email.mailboxPath,
      email.threadId ?? email.id,
    );
  }

  /// Sync-state key that makes the periodic flag reconcile of [folder] (an
  /// IMAP path, or a JMAP mailbox id) run at its next chance. Separate from
  /// the reconcile's own timestamp, so a reconcile already running cannot
  /// overwrite it; see [_settleFlagReconcileDue] for when it is cleared.
  static String _flagReconcileDueKey(String folder, {required bool jmap}) =>
      jmap ? 'JMAP:ReconcileDue:$folder' : 'IMAP:FlagReconcileDue:$folder';

  Future<void> _makeFlagReconcileDue(
    String accountId,
    String folder, {
    required bool jmap,
  }) =>
      _saveSyncState(
        accountId,
        _flagReconcileDueKey(folder, jmap: jmap),
        DateTime.now().toIso8601String(),
      );

  /// Called after a flag reconcile of [folder] that ran to the end, with
  /// [dueValue], the due marker as it was when the pass started. Clears the
  /// marker unless it was set again since (a change failed during the pass),
  /// or the pass had to skip a mail with a failed read/star change because
  /// another change of that mail is still queued: then the next sync tries
  /// again. A pass that throws leaves the marker alone.
  Future<void> _settleFlagReconcileDue(
    String accountId,
    String folder, {
    required bool jmap,
    required String? dueValue,
  }) async {
    if (dueValue == null) return;
    final inFlight = await _inFlightFlagResourceIds(accountId);
    if (inFlight.isNotEmpty) {
      final failedFlags = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.state.equals(_failedState) &
                  t.changeType.isIn(const ['flag_seen', 'flag_flagged']) &
                  t.resourceId.isIn(inFlight),
            ))
          .get();
      if (failedFlags.isNotEmpty) {
        final skipped = await (_db.select(_db.emails)
              ..where(
                (t) =>
                    t.id.isIn([for (final c in failedFlags) c.resourceId]) &
                    t.mailboxPath.equals(folder),
              )
              ..limit(1))
            .getSingleOrNull();
        if (skipped != null) return;
      }
    }
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType
                    .equals(_flagReconcileDueKey(folder, jmap: jmap)) &
                t.state.equals(dueValue),
          ))
        .go();
  }

  /// Change types that change where a mail is.
  static const _locationChangeTypes = ['move', 'snooze', 'unsnooze'];

  /// Change types that change where a mail is, or whether it exists: a later
  /// one of these depends on an earlier one for the same mail having applied.
  static const _placementChangeTypes = [..._locationChangeTypes, 'delete'];

  /// Called (inside the transaction that marked [row] failed) when a change
  /// just became failed. If [row] moves or deletes the mail, the mail's later
  /// queued moves/snoozes/unsnoozes/deletes depended on it — they address the
  /// mail where [row] would have put it — so they are marked failed too
  /// (`depends on failed change #id`, nothing reverted for them). Then, with
  /// [revert], [row]'s optimistic location is undone
  /// ([_revertFailedLocation]); a revert that throws is logged and rolled
  /// back on its own, never taking the failed state with it. Returns the
  /// dependents, for [_logDependentFailures] once the transaction is done.
  Future<List<PendingChangeRow>> _afterLocationFailure(
    PendingChangeRow row, {
    required bool revert,
  }) async {
    if (!_placementChangeTypes.contains(row.changeType)) return const [];
    final dependents = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.resourceId) &
                t.state.isIn(const [_pendingState, _stuckState]) &
                t.id.isBiggerThanValue(row.id) &
                t.changeType.isIn(_placementChangeTypes),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    for (final dependent in dependents) {
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(dependent.id)))
          .write(
        PendingChangesCompanion(
          lastError: Value('depends on failed change #${row.id}'),
          state: const Value(_failedState),
        ),
      );
    }
    if (!revert) return dependents;
    try {
      await _db.transaction(() => _revertFailedLocation(row, dependents));
    } catch (e) {
      log('Could not revert failed change ${row.id}: $e');
    }
    return dependents;
  }

  /// Drops the local row of [failed], a move whose message is in neither
  /// its source nor its destination folder (another client deleted it or
  /// moved it elsewhere), or whose source folder is gone. The row sits in the destination with its source
  /// UID, so there it would name whichever mail has that UID: sync would
  /// copy that mail's flags onto it, and the user's changes would act on
  /// it (#1268). If the mail is in a third folder, sync shows it there.
  /// The failed change itself stays on the Pending Changes screen; changes
  /// queued behind it find no mail and fail there too. Returns the dropped
  /// row, or null; the caller logs it with [_logGoneRowDropped] once the
  /// transaction has committed.
  Future<Email?> _dropGoneRow(PendingChangeRow failed) async {
    if (!_locationChangeTypes.contains(failed.changeType)) return null;
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(failed.resourceId)))
        .getSingleOrNull();
    if (email == null || !_sameMessage(failed, email.messageId)) return null;
    await (_db.delete(_db.emails)..where((t) => t.id.equals(email.id))).go();
    await _updateThread(
      email.accountId,
      email.mailboxPath,
      email.threadId ?? email.id,
    );
    return email;
  }

  /// App Log line for a row [_dropGoneRow] removed: the mail vanishes from
  /// the list, so the user must be able to find out why.
  /// [why] says what happened, e.g. "a failed move: the message is in
  /// neither its source nor its destination folder on the server".
  void _logGoneRowDropped(
    PendingChangeRow failed,
    Email? dropped, {
    required String why,
  }) {
    if (dropped == null) return;
    unawaited(
      _appLogger?.warn(
        'pending_change.local_row_removed',
        'Removed "${dropped.subject ?? '(no subject)'}" from '
            '${dropped.mailboxPath} on this device after $why; if another '
            'client moved it, it shows up there on the next sync',
        accountId: dropped.accountId,
        mailboxPath: dropped.mailboxPath,
        // The row is gone; a log row must not reference it.
        data: {
          'changeType': failed.changeType,
          'removedEmailId': dropped.id,
          'messageId': dropped.messageId,
        },
      ),
    );
  }

  /// App Log warnings for the [dependents] failed together with [row].
  void _logDependentFailures(
    PendingChangeRow row,
    List<PendingChangeRow> dependents,
  ) {
    for (final dependent in dependents) {
      unawaited(
        _appLogger?.warn(
          'pending_change.dependent_failed',
          'Could not apply ${_describeChange(dependent)} — it depends on a '
              'failed ${_describeChange(row)}; kept on the Pending Changes '
              'screen',
          accountId: dependent.accountId,
          emailId: dependent.resourceId,
          data: {'changeType': dependent.changeType, 'dependsOn': row.id},
        ),
      );
    }
  }

  /// Undoes the optimistic local part of [row], a move/snooze/unsnooze that
  /// just failed, together with its [dependents] (the later location changes
  /// for the mail that were failed with it): the mail goes back to [row]'s
  /// source folder with its earlier snooze state, so the app shows where it
  /// really is on the server. IMAP changes queued after it for the same mail
  /// that address it where those changes put it are pointed back at the
  /// source too ([_pointLaterChangesAtSource]).
  ///
  /// Does nothing when the mail is no longer where the last of these changes
  /// put it (e.g. a dependent delete removed the row), when the IMAP row does
  /// not name [row]'s source UID, or when the source folder was renumbered
  /// since [row] was queued.
  Future<void> _revertFailedLocation(
    PendingChangeRow row,
    List<PendingChangeRow> dependents,
  ) async {
    if (!_locationChangeTypes.contains(row.changeType)) return;
    final payload = _decodePayload(row);
    if (payload == null) return;
    final src = payload['mailboxPath'] ?? payload['src'];
    final dest = payload['dest'];
    if (src is! String || dest is! String) return;
    // Every place the mail was shown in along the way, the last one being
    // where it should be now.
    final shownIn = [dest];
    for (final dependent in dependents) {
      if (dependent.changeType == 'delete') return;
      final later = _decodePayload(dependent)?['dest'];
      if (later is String) shownIn.add(later);
    }
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    if (email == null) return;
    if (!await _isAtLocation(email, shownIn.last)) return;
    final account = await _accounts.getAccount(row.accountId);
    if (account == null) return;
    final isImap = account.type == account_model.AccountType.imap;
    final uid = payload['uid'];
    if (isImap &&
        (email.uid != uid || email.id != '${row.accountId}:$src:$uid')) {
      return;
    }
    if (isImap && !await _stampStillValid(row.accountId, src, payload)) return;

    // A snooze is undone to the snooze state from before it (none, or the
    // earlier one of a re-snooze); a move or unsnooze that ended a snooze
    // brings that snooze back.
    final prevUntil = DateTime.tryParse(
      payload['prevSnoozedUntil'] as String? ?? '',
    );
    final prevFrom = payload['prevSnoozedFrom'] as String?;
    final target = await _resolveSnoozedPlaceholder(row.accountId, src);
    await (_db.update(_db.emails)..where((t) => t.id.equals(email.id))).write(
      EmailsCompanion(
        mailboxPath: Value(target),
        snoozedUntil: Value(prevUntil),
        snoozedFromMailboxPath: Value(prevUntil == null ? null : prevFrom),
      ),
    );
    if (isImap) {
      await _pointLaterChangesAtSource(
        row,
        payload: payload,
        email: email,
        src: src,
        shownIn: shownIn,
      );
    }
    final threadId = email.threadId ?? email.id;
    await _reconcileSourceThreads(
      row.accountId,
      email.mailboxPath,
      email.id,
      threadId,
    );
    await _updateThread(row.accountId, target, threadId);
    // Read/star changes made while the mail was shown elsewhere may have
    // failed as well, and the reconcile they made due was for that folder.
    await _makeFlagReconcileDue(row.accountId, target, jmap: !isImap);
    log(
      'Pending change ${row.id} failed: ${email.id} back in $target '
      '(was shown in ${email.mailboxPath})',
    );
  }

  /// [row]'s JSON payload, or null when it is not a JSON object.
  static Map<String, dynamic>? _decodePayload(PendingChangeRow row) {
    try {
      return jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Whether the UIDVALIDITY stamped on an IMAP change [payload] for [src]
  /// still matches [src]'s sync checkpoint: only then does its UID still name
  /// the same message there. True when either is unknown.
  Future<bool> _stampStillValid(
    String accountId,
    String src,
    Map<String, dynamic> payload,
  ) async {
    final stamped = payload['uidValidity'];
    if (stamped is! int) return true;
    final checkpoint = await _loadImapCheckpoint(accountId, 'IMAP:$src');
    final current = checkpoint?['uidValidity'];
    if (current is! int || current == 0) return true;
    return current == stamped;
  }

  /// [path], with the `Snoozed` placeholder a snooze queued before the
  /// folder was known replaced by [accountId]'s real Snoozed folder.
  Future<String> _resolveSnoozedPlaceholder(
    String accountId,
    String path,
  ) async {
    if (path != _snoozedPlaceholder) return path;
    return _snoozedMailboxPath(accountId);
  }

  /// Whether [email] is in [mailboxPath], counting the Snoozed folder and the
  /// `Snoozed` placeholder a snooze queued before it was known as the same.
  Future<bool> _isAtLocation(Email email, String mailboxPath) async {
    if (email.mailboxPath == mailboxPath) return true;
    final snoozedPath = await _snoozedMailboxPath(email.accountId);
    return _isSnoozedPath(email.mailboxPath, snoozedPath) &&
        _isSnoozedPath(mailboxPath, snoozedPath);
  }

  /// Points the IMAP payloads of the other changes queued after [failed] for
  /// [email] that address it in one of the folders it was [shownIn] back at
  /// [src], after [failed] was undone. They get [failed]'s own UIDVALIDITY
  /// stamp and Message-ID ([payload]): its source UID is valid only under
  /// that stamp, so a change is left as it is when [src] was renumbered
  /// since ([_stampStillValid]; the caller checks this before reverting).
  Future<void> _pointLaterChangesAtSource(
    PendingChangeRow failed, {
    required Map<String, dynamic> payload,
    required Email email,
    required String src,
    required List<String> shownIn,
  }) async {
    final later = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(failed.resourceId) &
                t.state.isIn(_liveStates) &
                t.id.isBiggerThanValue(failed.id) &
                t.changeType.isNotIn(_placementChangeTypes),
          ))
        .get();
    final paths = {email.mailboxPath, ...shownIn};
    for (final row in later) {
      final changed = _decodePayload(row);
      if (changed == null) continue;
      if (!paths.contains(changed['mailboxPath'])) continue;
      if (changed['uid'] != email.uid) continue;
      // Back where its UID came from: the UID is right again.
      changed
        ..['mailboxPath'] = src
        ..remove('uidValidity')
        ..remove(_uidAfterMoveKey);
      if (payload['uidValidity'] case final int validity) {
        changed['uidValidity'] = validity;
      }
      if (payload['messageId'] case final String messageId) {
        changed['messageId'] = messageId;
      }
      await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(changed))));
    }
  }

  /// Short human-readable label for a queued change, used in App Log messages.
  String _describeChange(PendingChangeRow row) {
    switch (row.changeType) {
      case 'move':
        return 'move';
      case 'delete':
        return 'delete';
      case 'flag_seen':
        return 'read/unread change';
      case 'flag_flagged':
        return 'flag change';
      case 'add_keywords':
        return 'keyword change';
      case 'snooze':
        return 'snooze';
      case 'unsnooze':
        return 'unsnooze';
      case 'clear_snooze':
        return 'snooze cleanup';
      default:
        return '"${row.changeType}" change';
    }
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .getSingleOrNull();
    return row?.state;
  }

  /// Removes one sync-state row, so a checkpoint can be made due again (or a
  /// resume point retired) rather than merely left stale.
  Future<void> _clearSyncState(String accountId, String resourceType) async {
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals(resourceType),
          ))
        .go();
  }

  Future<void> _saveSyncState(
    String accountId,
    String resourceType,
    String state,
  ) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  // ── JMAP push ────────────────────────────────────────────────────────────

  /// Expands the RFC 8620 §7.3 `eventSourceUrl` URI template.
  ///
  /// Servers advertise a template such as
  /// `.../eventsource/?types={types}&closeafter={closeafter}&ping={ping}`.
  /// Sending it verbatim — with the literal `{…}` placeholders still in the
  /// query string — makes servers reject the request with HTTP 400, which
  /// silently drops the account back to the 30 s poll. We subscribe to all
  /// types, keep the stream open, and ask for a 30 s keep-alive ping to
  /// survive NAT/proxy idle timeouts (and so that silence means a dead
  /// connection — see [_sseSilenceTimeout]).
  static String _expandEventSourceUrl(String template) {
    return template
        .replaceAll('{types}', '*')
        .replaceAll('{closeafter}', 'no')
        .replaceAll('{ping}', '30');
  }

  /// How long the SSE stream may stay silent before it counts as dead. It is
  /// an inactivity timeout (reset by every chunk, pings included), not a cap
  /// on the stream's lifetime. A blackholed connection (open, but no bytes
  /// flow) never reports its loss, so this is what ends it; it used to be 25
  /// minutes, during which the account saw no push. Ten missed 30 s pings
  /// leaves room for a server that stretches the interval we ask for.
  static const _sseSilenceTimeout = Duration(minutes: 5);

  /// Strips any embedded `user:pass@` userinfo from [url] so it is safe to
  /// persist in the app log. JMAP SSE auth travels in the `Authorization`
  /// header rather than the URL, so this is belt-and-braces.
  static String _redactUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.userInfo.isEmpty) return url;
      return uri.replace(userInfo: '').toString();
    } catch (_) {
      return url;
    }
  }

  /// Drains a failed SSE [response] body into a short string for logging.
  /// Truncated so a chatty HTML error page can't bloat the app log.
  static Future<String> _readSseErrorBody(
    http.StreamedResponse response,
  ) async {
    try {
      final body = (await response.stream.bytesToString()).trim();
      return body.length > 500 ? '${body.substring(0, 500)}…' : body;
    } catch (_) {
      return '';
    }
  }

  /// Records the outcome of a `watchJmapPush` subscription as a
  /// `sync.jmap.push` app-log row. The `status` value is stable and used by
  /// the sync-state view to render a human-readable "Push" row — see
  /// `push_status.dart` for the enum of accepted values.
  Future<void> _logPushStatus(
    String accountId,
    String status,
    String message, {
    AppLogLevel level = AppLogLevel.info,
    Map<String, Object?>? data,
  }) async {
    final logger = _appLogger;
    if (logger == null) return;
    await logger.log(
      level: level,
      event: 'sync.jmap.push',
      message: message,
      accountId: accountId,
      data: {'push_status': status, ...?data},
    );
  }

  @override
  Stream<void> watchJmapPush(String accountId, String password) {
    final controller = StreamController<void>();
    StreamSubscription<String>? innerSub;

    controller.onCancel = () => innerSub?.cancel();

    unawaited(() async {
      try {
        final account = await _accounts.getAccount(accountId);
        if (account == null || account.type != account_model.AccountType.jmap) {
          await controller.close();
          return;
        }

        final jmapUrl = account.jmapUrl;
        if (jmapUrl == null || jmapUrl.isEmpty) {
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.unsupported.wireName,
              'JMAP push disabled: account has no JMAP URL',
            ),
          );
          await controller.close();
          return;
        }

        final JmapClient jmap;
        try {
          jmap = await JmapClient.connect(
            httpClient: _httpClient,
            jmapUrl: Uri.parse(jmapUrl),
            username: _effectiveUsername(account),
            password: password,
          );
        } catch (e) {
          log('JMAP push: connect failed: $e');
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.connectFailed.wireName,
              'JMAP push: session connect failed: $e',
              level: AppLogLevel.warn,
              data: {'error': e.toString()},
            ),
          );
          await controller.close();
          return;
        }

        final sseUrl = jmap.eventSourceUrl;
        if (sseUrl == null) {
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.unsupported.wireName,
              'JMAP push unavailable: server does not advertise '
              'an eventSourceUrl (falling back to poll)',
            ),
          );
          await controller.close();
          return;
        }

        // The advertised URL is an RFC 8620 §7.3 URI template — expand the
        // `{types}`/`{closeafter}`/`{ping}` placeholders before requesting it,
        // or the server rejects the literal `{…}` query with HTTP 400.
        final resolvedSseUrl = _expandEventSourceUrl(sseUrl);
        final redactedSseUrl = _redactUrl(resolvedSseUrl);

        final credentials = base64.encode(
          utf8.encode('${_effectiveUsername(account)}:$password'),
        );

        http.StreamedResponse response;
        try {
          final request = http.Request('GET', Uri.parse(resolvedSseUrl));
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Authorization'] = 'Basic $credentials';
          response = await _httpClient
              .send(request)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode != 200) {
            final body = await _readSseErrorBody(response);
            unawaited(
              _logPushStatus(
                accountId,
                '${JmapPushStatus.sseStatusPrefix.wireName}'
                    '${response.statusCode}',
                'JMAP push: SSE endpoint returned HTTP '
                    '${response.statusCode}',
                level: AppLogLevel.warn,
                data: {
                  'httpStatus': response.statusCode,
                  'sseUrl': redactedSseUrl,
                  if (body.isNotEmpty) 'responseBody': body,
                },
              ),
            );
            await controller.close();
            return;
          }
        } catch (e) {
          log('JMAP push: SSE request failed: $e');
          unawaited(
            _logPushStatus(
              accountId,
              JmapPushStatus.sseFailed.wireName,
              'JMAP push: SSE request failed: $e',
              level: AppLogLevel.warn,
              data: {'error': e.toString(), 'sseUrl': redactedSseUrl},
            ),
          );
          await controller.close();
          return;
        }

        unawaited(
          _logPushStatus(
            accountId,
            JmapPushStatus.connected.wireName,
            'JMAP push connected — waiting for StateChange events',
            data: {'sseUrl': redactedSseUrl},
          ),
        );

        var buffer = '';
        innerSub = response.stream
            .transform(utf8.decoder)
            .timeout(_sseSilenceTimeout)
            .listen(
          (chunk) {
            buffer += chunk;
            final lines = buffer.split('\n');
            buffer = lines.removeLast();
            for (final line in lines) {
              if (!line.startsWith('data:')) continue;
              final data = line.substring(5).trim();
              try {
                final decoded = jsonDecode(data) as Map<String, dynamic>;
                if (decoded['@type'] == 'StateChange') {
                  controller.add(null);
                }
              } catch (_) {
                // Malformed JSON — ignore line
              }
            }
          },
          onDone: () {
            unawaited(
              _logPushStatus(
                accountId,
                JmapPushStatus.closed.wireName,
                'JMAP push stream ended (server closed connection)',
              ),
            );
            unawaited(controller.close());
          },
          onError: (Object e) {
            unawaited(
              _logPushStatus(
                accountId,
                JmapPushStatus.errored.wireName,
                'JMAP push stream errored: $e',
                level: AppLogLevel.warn,
                data: {'error': e.toString()},
              ),
            );
            unawaited(controller.close());
          },
          cancelOnError: true,
        );
      } catch (e) {
        log('JMAP push: unexpected error: $e');
        unawaited(
          _logPushStatus(
            accountId,
            JmapPushStatus.errored.wireName,
            'JMAP push: unexpected error: $e',
            level: AppLogLevel.warn,
            data: {'error': e.toString()},
          ),
        );
        await controller.close();
      }
    }());

    return controller.stream;
  }

  // ── JMAP helpers ─────────────────────────────────────────────────────────

  Map<String, dynamic> _responseArgs(
    List<dynamic> responses,
    int index,
    String expectedMethod,
  ) {
    final triple = responses[index] as List<dynamic>;
    final method = triple[0] as String;
    if (method == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      throw JmapException('$expectedMethod error: ${err['type']}');
    }
    // [expectedMethod] used to be for the error message only, so a response
    // list that had slipped out of step returned another method's arguments
    // and surfaced as an opaque TypeError further down. Say what happened.
    if (method != expectedMethod) {
      throw JmapException(
        'JMAP response $index is $method, expected $expectedMethod',
      );
    }
    return triple[1] as Map<String, dynamic>;
  }

  String _encodeJmapAddresses(dynamic addressList) {
    if (addressList == null) return '[]';
    final list = addressList as List<dynamic>;
    return jsonEncode(
      list
          .map(
            (a) => {
              'name': (a as Map<String, dynamic>)['name'],
              'email': a['email'],
            },
          )
          .toList(),
    );
  }

  DateTime? _parseDate(String? iso) =>
      iso == null ? null : DateTime.tryParse(iso);

  // ── Mutations ──────────────────────────────────────────────────────────────

  @override
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) =>
      _setFlag(emailId, seen: seen, flagged: flagged);

  /// Tail of the in-flight [_setFlag] chain per email id. [_setFlag] reads the
  /// row, drops no-op flags, then writes; two overlapping calls for the same
  /// email could otherwise interleave, e.g. the unawaited auto-mark-read on
  /// open landing after the user's "Mark as unread", which read the still
  /// unread row, saw nothing to change and returned (#1186). Chaining makes
  /// each call see the previous call's write.
  final Map<String, Future<void>> _flagChains = {};

  /// [setFlag] with an optional [source] recorded in the `email.flag` log
  /// entry (e.g. `sieve` when a local filter set the flag). Calls for the
  /// same [emailId] run one after another, in call order. Never call this
  /// inside `_db.transaction`: a queued outside call for the same id would
  /// wait on the transaction lock while the inner call waits on it.
  Future<void> _setFlag(
    String emailId, {
    bool? seen,
    bool? flagged,
    String? source,
  }) {
    final previous = _flagChains[emailId];
    final run = previous == null
        ? _setFlagNow(emailId, seen: seen, flagged: flagged, source: source)
        : previous.then(
            (_) => _setFlagNow(
              emailId,
              seen: seen,
              flagged: flagged,
              source: source,
            ),
          );
    // The chain tail swallows errors so one failed call does not fail the
    // next; the caller still gets this call's own error via [run].
    // Fire-and-forget callers (the auto-mark-read on open) no longer surface
    // the error to the zone because this handler is attached, so log it.
    final tail = run.then<void>(
      (_) {},
      onError: (Object e, StackTrace st) {
        log('setFlag($emailId) failed: $e');
        unawaited(
          _appLogger?.warn(
            'email.flag_failed',
            'Changing the read/star state failed',
            emailId: emailId,
            error: e,
            stack: st,
          ),
        );
      },
    );
    _flagChains[emailId] = tail;
    unawaited(
      tail.whenComplete(() {
        _flagChains.removeWhere((k, v) => k == emailId && identical(v, tail));
      }),
    );
    return run;
  }

  Future<void> _setFlagNow(
    String emailId, {
    bool? seen,
    bool? flagged,
    String? source,
  }) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;

    // Reduce the request to only the flags that actually change. Callers such
    // as the detail-screen auto-mark-on-open (`lib/di.dart`) fire
    // `setFlag(id, seen: true)` on every open; without this guard an
    // already-read message would re-enqueue a `flag_seen` change (re-STORE on
    // the server) and re-emit an `email.flag` log entry on every open (#644).
    seen = (seen != null && seen != row.isSeen) ? seen : null;
    flagged = (flagged != null && flagged != row.isFlagged) ? flagged : null;
    if (seen == null && flagged == null) return;

    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      if (seen != null) {
        await _enqueueChange(
          account.id,
          emailId,
          'flag_seen',
          jsonEncode({'seen': seen}),
        );
      }
      if (flagged != null) {
        await _enqueueChange(
          account.id,
          emailId,
          'flag_flagged',
          jsonEncode({'flagged': flagged}),
        );
      }
      // Optimistic local update.
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          isSeen: seen != null ? Value(seen) : const Value.absent(),
          isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
        ),
      );
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? emailId,
      );
      _logFlag(row, account, seen: seen, flagged: flagged, source: source);
      return;
    }

    if (seen != null) {
      await _enqueueChange(
        account.id,
        emailId,
        'flag_seen',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'seen': seen,
        }),
      );
    }
    if (flagged != null) {
      await _enqueueChange(
        account.id,
        emailId,
        'flag_flagged',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'flagged': flagged,
        }),
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        isSeen: seen != null ? Value(seen) : const Value.absent(),
        isFlagged: flagged != null ? Value(flagged) : const Value.absent(),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    _logFlag(row, account, seen: seen, flagged: flagged, source: source);
  }

  /// Writes a per-message `email.flag` log row so the read/unread/star change
  /// is discoverable in that message's "Show Logs" view (#562). No-op when
  /// neither flag was touched.
  void _logFlag(
    Email row,
    account_model.Account account, {
    bool? seen,
    bool? flagged,
    String? source,
  }) {
    if (seen == null && flagged == null) return;
    final parts = <String>[
      if (seen != null) seen ? 'read' : 'unread',
      if (flagged != null) flagged ? 'starred' : 'unstarred',
    ];
    unawaited(
      _appLogger?.info(
        'email.flag',
        'Marked "${row.subject ?? '(no subject)'}" ${parts.join(', ')}',
        emailId: row.id,
        accountId: row.accountId,
        mailboxPath: row.mailboxPath,
        data: {
          if (seen != null) 'seen': seen,
          if (flagged != null) 'flagged': flagged,
          'protocol': account.type.name,
          if (source != null) 'source': source,
        },
      ),
    );
  }

  @override
  Future<void> markAllAsRead(String accountId, String mailboxPath) async {
    final account = (await _accounts.getAccount(accountId))!;
    final unread = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.isSeen.equals(false),
          ))
        .get();
    if (unread.isEmpty) return;

    await _db.transaction(() async {
      for (final row in unread) {
        if (account.type == account_model.AccountType.jmap) {
          await _enqueueChange(
            accountId,
            row.id,
            'flag_seen',
            jsonEncode({'seen': true}),
          );
        } else {
          await _enqueueChange(
            accountId,
            row.id,
            'flag_seen',
            jsonEncode({
              'uid': row.uid,
              'mailboxPath': row.mailboxPath,
              'seen': true,
            }),
          );
        }
      }

      // Bulk mark all unread emails in this mailbox as seen.
      await (_db.update(_db.emails)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath) &
                  t.isSeen.equals(false),
            ))
          .write(const EmailsCompanion(isSeen: Value(true)));

      // Update all threads in this mailbox to reflect no unread.
      await (_db.update(_db.threads)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.mailboxPath.equals(mailboxPath),
            ))
          .write(const ThreadsCompanion(hasUnread: Value(false)));
    });

    // Log per message (outside the transaction) so each affected mail shows the
    // read change in its own "Show Logs" view (#562).
    for (final row in unread) {
      unawaited(
        _appLogger?.info(
          'email.mark_read',
          'Marked "${row.subject ?? '(no subject)'}" read',
          emailId: row.id,
          accountId: accountId,
          mailboxPath: mailboxPath,
          data: {
            'seen': true,
            'bulk': true,
            'protocol': account.type.name,
          },
        ),
      );
    }
  }

  @override
  Future<void> moveEmail(String emailId, String destMailboxPath) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.mailboxPath == destMailboxPath) return;

    await _moveRow(row, destMailboxPath);
    await _mirrorMoveToCounterparts(
      row.accountId,
      row.messageId,
      destMailboxPath,
    );
  }

  /// Moves a single [row] to [destMailboxPath] on its own account: enqueues the
  /// protocol change and applies the optimistic local update. Does not mirror
  /// to counterpart accounts (see [_mirrorMoveToCounterparts]).
  Future<void> _moveRow(
    Email row,
    String destMailboxPath, {
    String event = 'email.move',
  }) async {
    if (row.mailboxPath == destMailboxPath) return;
    final emailId = row.id;
    final srcMailboxPath = row.mailboxPath;
    final account = (await _bulkAccount(row.accountId))!;
    // Filing a snoozed mail by hand ends the snooze: otherwise the wake-up
    // later pulls it back to the Inbox from wherever the user put it. The
    // flush also strips the server-side `snz:` keyword, which sync would
    // otherwise read back into `snoozedUntil`.
    final clearSnooze = row.snoozedUntil != null;

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({
          'src': srcMailboxPath,
          'dest': destMailboxPath,
          if (clearSnooze) 'clearSnooze': true,
          ..._prevSnooze(row),
        }),
      );
      // Optimistic: move the cached row so it disappears from the current
      // mailbox immediately and is visible in the destination mailbox.
      await _applyLocalMove(row, destMailboxPath);
    } else {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': srcMailboxPath,
          'dest': destMailboxPath,
          // Lets the flush re-resolve a stale UID (see
          // [_retryImapMoveByMessageId]) instead of silently no-op'ing (#1048).
          if (row.messageId != null) 'messageId': row.messageId,
          if (clearSnooze) 'clearSnooze': true,
          ..._prevSnooze(row),
        }),
      );
      // Optimistic: move the cached row locally instead of hard-deleting.
      await _applyLocalMove(row, destMailboxPath);
      // Destination UID will be updated when synced (IMAP move = delete + copy).
    }

    // Per-message log so the move (or trash/archive/spam, which are all moves)
    // shows up in this mail's "Show Logs" view (#562). The IMAP re-key on the
    // next sync carries this row along (see [_remapEmailAfterImapMove]).
    _logAfterBulk(
      () => _appLogger?.info(
        event,
        'Moved "${row.subject ?? '(no subject)'}" '
        'from $srcMailboxPath to $destMailboxPath',
        emailId: emailId,
        accountId: row.accountId,
        mailboxPath: destMailboxPath,
        data: {
          'src': srcMailboxPath,
          'dest': destMailboxPath,
          'protocol': account.type.name,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of a move of [row] to [destMailboxPath]: the
  /// row shows in the destination at once, its snooze ended. No change is
  /// queued here (see [_moveRow]).
  Future<void> _applyLocalMove(Email row, String destMailboxPath) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(destMailboxPath),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _reconcileSourceThreads(
      row.accountId,
      row.mailboxPath,
      row.id,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, destMailboxPath, row.threadId ?? row.id);
  }

  /// Payload keys recording [row]'s snooze before a move/snooze/unsnooze
  /// changes it, so [_revertFailedLocation] can bring it back if the change
  /// fails. Empty when [row] is not snoozed.
  static Map<String, Object> _prevSnooze(Email row) {
    final until = row.snoozedUntil;
    if (until == null) return const {};
    final from = row.snoozedFromMailboxPath;
    return {
      'prevSnoozedUntil': until.toIso8601String(),
      if (from != null) 'prevSnoozedFrom': from,
    };
  }

  @override
  Future<String?> deleteEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return null;

    final dest = await _deleteRow(row);
    await _mirrorDeleteToCounterparts(row.accountId, row.messageId);
    return dest;
  }

  @override
  Future<String?> deleteEmails(List<String> emailIds) async {
    if (emailIds.isEmpty) return null;
    final fetched =
        await (_db.select(_db.emails)..where((t) => t.id.isIn(emailIds))).get();
    final byId = {for (final r in fetched) r.id: r};
    final rows = [
      for (final id in emailIds)
        if (byId[id] case final row?) row,
    ];
    if (rows.isEmpty) return null;

    // Resolve the counterpart accounts once per source account instead of
    // opening an `observeAccounts()` stream per message. This also has to
    // happen outside the transaction below: a `.watch()` query started inside
    // it would wait for the transaction to finish.
    final counterparts = <String, List<account_model.Account>>{};
    if (rows.any((r) => normaliseMessageId(r.messageId) != null)) {
      final all = await _accounts.observeAccounts().first;
      for (final source in all) {
        if (!rows.any((r) => r.accountId == source.id)) continue;
        counterparts[source.id] = AccountComparison.counterpartsOf(source, all);
      }
    }

    // Deleting one message used to cost a dozen separate implicit write
    // transactions, a sync-loop kick and a re-run of every live query; times
    // 80 that kept a bulk delete busy for a long time with no feedback (#917).
    // One transaction collapses all of it into a single commit, while the
    // bulk scope defers the per-message App Log rows and the sync kick until
    // after it.
    // Per-email-id mailbox each message was selected from, when the caller
    // provides it. A row that has since moved out of that mailbox is a stale
    // (duplicate) delete — e.g. an accidental second delete of a selection the
    // first call already moved to Trash — so skip it rather than hard-delete
    // it from Trash (#1010).
    final expectedMailbox =
        Zone.current[deleteExpectedMailboxZoneKey] as Map<String, String>?;
    final scope = _BulkScope();
    String? dest;
    await runZoned(
      () => _db.transaction(() async {
        // Ids already deleted in this batch — a selection can contain both
        // twins of a counterpart pair, and the second must not be deleted
        // again from its (now stale) source folder.
        final handled = <String>{};
        for (final row in rows) {
          if (!handled.add(row.id)) continue;
          final expected = expectedMailbox?[row.id];
          if (expected != null && expected != row.mailboxPath) continue;
          dest = await _deleteRow(row);
          final mid = normaliseMessageId(row.messageId);
          if (mid == null) continue;
          for (final counterpart in counterparts[row.accountId] ??
              const <account_model.Account>[]) {
            final twin = await _findEmailRowByNormalisedMessageId(
              counterpart.id,
              mid,
            );
            if (twin == null || !handled.add(twin.id)) continue;
            await _deleteRow(twin);
          }
        }
      }),
      zoneValues: {_bulkScopeKey: scope},
    );
    for (final write in scope.logs) {
      unawaited(write());
    }
    scope.kickedAccounts.forEach(_changeCtrl.add);
    return dest;
  }

  /// The [_BulkScope] of the [deleteEmails] call currently running in this
  /// zone, or null outside a bulk operation.
  _BulkScope? get _bulkScope => Zone.current[_bulkScopeKey] as _BulkScope?;

  /// [AccountRepository.getAccount], memoised for the duration of a bulk
  /// operation so a batch looks each account up once, not once per message.
  Future<account_model.Account?> _bulkAccount(String accountId) async {
    final bulk = _bulkScope;
    if (bulk == null) return _accounts.getAccount(accountId);
    if (bulk.accounts.containsKey(accountId)) return bulk.accounts[accountId];
    return bulk.accounts[accountId] = await _accounts.getAccount(accountId);
  }

  /// Writes an App Log row now, or — inside a bulk operation — once its
  /// transaction has committed. The logger writes to the same database, so an
  /// unawaited insert issued inside the transaction could outlive it.
  void _logAfterBulk(Future<Object?>? Function() write) {
    final bulk = _bulkScope;
    if (bulk != null) {
      bulk.logs.add(write);
      return;
    }
    unawaited(write());
  }

  /// Deletes a single [row] on its own account: moves it to that account's
  /// Trash when one exists (so the user can recover it), otherwise hard-deletes.
  /// Returns the Trash path when moved, or null when hard-deleted. Does not
  /// mirror to counterpart accounts (see [_mirrorDeleteToCounterparts]).
  Future<String?> _deleteRow(Email row) async {
    final emailId = row.id;
    final account = (await _bulkAccount(row.accountId))!;

    // Move to Trash when possible so the user can recover the message.
    final trashRow = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();

    if (trashRow != null && trashRow.path != row.mailboxPath) {
      await _moveRow(row, trashRow.path, event: 'email.trash');
      return trashRow.path;
    }

    // Already in Trash or no Trash folder — hard delete. Record it so the
    // deletion still shows up in the global App Log even though the message
    // row (and any per-message view of it) is about to disappear (#562).
    _logAfterBulk(
      () => _appLogger?.info(
        'email.delete',
        'Permanently deleted "${row.subject ?? '(no subject)'}" '
            'from ${row.mailboxPath}',
        emailId: emailId,
        accountId: row.accountId,
        mailboxPath: row.mailboxPath,
        data: {
          'permanent': true,
          // The row's delete sets this entry's email_id to null (foreign
          // key), so keep which mail it was in the data.
          'emailId': emailId,
          'mailboxPath': row.mailboxPath,
          'protocol': account.type.name,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'delete',
        jsonEncode(<String, dynamic>{}),
      );
      await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
      await _updateThread(
        row.accountId,
        row.mailboxPath,
        row.threadId ?? emailId,
      );
      return null;
    }

    await _enqueueChange(
      account.id,
      emailId,
      'delete',
      jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
    );
    await (_db.delete(_db.emails)..where((t) => t.id.equals(emailId))).go();
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? emailId,
    );
    return null;
  }

  // ── pending_changes queue ──────────────────────────────────────────────────

  /// Zone key marking changes the app queues on its own (snooze wake-up,
  /// local Sieve filters, the #545 dissolve replay), not as a direct user
  /// action; see [_asAutomaticChange].
  static final _automaticChangeKey = Object();

  /// Runs [action] so that the changes it queues do not replace the user's
  /// failed changes ([_deleteSupersededFailures]): only the user's own action
  /// may settle one of their failures.
  Future<T> _asAutomaticChange<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_automaticChangeKey: true});

  /// Queues a change. A user action ([supersedeFailures], the default unless
  /// run via [_asAutomaticChange]) also deletes the failed changes it
  /// replaces.
  Future<void> _enqueueChange(
    String accountId,
    String resourceId,
    String changeType,
    String payload, {
    bool? supersedeFailures,
  }) async {
    _noteLocalEdit(resourceId);
    // Local self-sent "virtual" messages have no server counterpart yet, so an
    // outbound mutation would be rejected (`notFound`) and evicted. The state
    // is instead applied locally and carried over to the real message when it
    // arrives (see [_maybeDissolveLocalMessage]). Skip queuing here (#545).
    if (await _isLocalEmail(resourceId)) return;
    payload = await _stampUidValidity(accountId, resourceId, payload);
    payload = await _markUidAfterQueuedMove(resourceId, payload);
    if (supersedeFailures ?? Zone.current[_automaticChangeKey] != true) {
      await _deleteSupersededFailures(resourceId, changeType);
    }

    // Collapse redundant flag changes: if an un-attempted `flag_seen` /
    // `flag_flagged` / `clear_snooze` for this message with the same payload is
    // already queued, don't append a duplicate (the wake-up re-queues a
    // `clear_snooze` each time sync reads a stale snooze back). Only these are
    // de-duped — move / delete / snooze carry ordering semantics and must not
    // be collapsed here (#644).
    if (changeType == 'flag_seen' ||
        changeType == 'flag_flagged' ||
        changeType == 'add_keywords' ||
        changeType == 'clear_snooze') {
      // Compare against the latest queued change of this type only: with
      // `[seen:true, seen:false]` queued, a new `seen:true` is not redundant
      // and must be appended, or the server would end up unread (#1186).
      // A failed change is not queued work: the new one must be appended.
      final latest = await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.resourceId.equals(resourceId) &
                  t.state.equals(_pendingState) &
                  t.changeType.equals(changeType),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(1))
          .getSingleOrNull();
      if (latest != null && latest.payload == payload && latest.attempts == 0) {
        return;
      }
    }

    await _db.into(_db.pendingChanges).insert(
          PendingChangesCompanion.insert(
            accountId: accountId,
            resourceType: 'Email',
            resourceId: resourceId,
            changeType: changeType,
            payload: payload,
            createdAt: DateTime.now(),
          ),
        );
    // Again after the insert: a read that started during the awaits above
    // took its sequence after the first note and read the queue before this
    // row existed, so without this the change could flush unseen by it.
    _noteLocalEdit(resourceId);
    final bulk = _bulkScope;
    if (bulk != null) {
      bulk.kickedAccounts.add(accountId);
      return;
    }
    _changeCtrl.add(accountId);
  }

  /// Deletes failed changes of [resourceId] that a new [changeType] change
  /// replaces: the same flag change, or for a move/snooze/unsnooze/delete any
  /// failed location change. Redoing the action (or an Undo) clears the stale
  /// failure instead of piling up next to it.
  Future<void> _deleteSupersededFailures(
    String resourceId,
    String changeType,
  ) async {
    final superseded = _supersededBy(changeType);
    if (superseded.isEmpty) return;
    // A stuck read/star change is replaced too: the new one carries the
    // user's newer value. A stuck move/delete is not: later location
    // changes address the mail where it would put it.
    final flag = changeType == 'flag_seen' || changeType == 'flag_flagged';
    final failed = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(resourceId) &
                (flag
                    ? t.state.isIn(const [_failedState, _stuckState])
                    : t.state.equals(_failedState)) &
                t.changeType.isIn(superseded),
          ))
        .get();
    if (failed.isEmpty) return;
    final messageId = await _messageIdOf(resourceId);
    for (final row in failed) {
      // After a UIDVALIDITY reset the same row id can name another mail: a
      // failure stamped with a different Message-ID is not this mail's.
      if (!_sameMessage(row, messageId)) continue;
      // Not one a flush has claimed meanwhile: that one is being sent.
      await (_db.delete(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(row.id) &
                  t.state.isIn(const [_failedState, _stuckState]),
            ))
          .go();
    }
  }

  /// Whether [row] was queued for the mail with [messageId]: true unless its
  /// payload carries a different Message-ID stamp.
  static bool _sameMessage(PendingChangeRow row, String? messageId) {
    final stamped = _decodePayload(row)?['messageId'];
    if (stamped is! String) return true;
    return stamped == messageId;
  }

  static List<String> _supersededBy(String changeType) {
    if (changeType == 'flag_seen' || changeType == 'flag_flagged') {
      return [changeType];
    }
    if (_placementChangeTypes.contains(changeType)) {
      return _placementChangeTypes;
    }
    return const [];
  }

  /// Adds the source folder's UIDVALIDITY to an IMAP change [payload] (one
  /// with a `uid` and a `mailboxPath`/`src`), as known from that folder's
  /// sync checkpoint. A UID only names a message under one UIDVALIDITY: if
  /// the server resets it before the flush, the same UID can belong to a
  /// different message, and a queued delete would expunge the wrong mail.
  /// The flush compares the stamp with what SELECT reports
  /// ([_currentImapUid]). The row's Message-ID is stamped too, while
  /// [resourceId] still names this message: after a reset, sync re-inserts
  /// the folder under new UIDs and the same row id can then belong to
  /// another message. JMAP payloads and folders never synced (no
  /// checkpoint yet, e.g. during the first full sync) are left as they are.
  /// The stamp is the folder's UIDVALIDITY at enqueue time, not proof of
  /// where the UID was learned: an optimistically moved row still carries
  /// its source UID, as before.
  Future<String> _stampUidValidity(
    String accountId,
    String resourceId,
    String payload,
  ) async {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return payload;
    }
    if (map['uid'] is! int || map.containsKey('uidValidity')) return payload;
    final path = map['mailboxPath'] ?? map['src'];
    if (path is! String) return payload;
    final checkpoint = await _loadImapCheckpoint(accountId, 'IMAP:$path');
    final validity = checkpoint?['uidValidity'];
    // 0 is no valid UIDVALIDITY (RFC 3501): the checkpoint's fallback for a
    // server that reported none.
    if (validity is! int || validity == 0) return payload;
    map['uidValidity'] = validity;
    if (map['messageId'] == null) {
      final messageId = await _messageIdOf(resourceId);
      if (messageId != null) map['messageId'] = messageId;
    }
    return jsonEncode(map);
  }

  /// Marks an IMAP change [payload] whose UID is not the mail's UID in the
  /// payload's folder yet: a move of the same mail to that folder is still
  /// queued, so the local row and this UID are the pre-move ones (#1266).
  /// There the UID may name another mail. The move's answer replaces it
  /// ([_repointQueuedChanges]); a change still marked when it is applied
  /// finds its mail by Message-ID instead, or fails ([_currentImapUid]).
  Future<String> _markUidAfterQueuedMove(
    String resourceId,
    String payload,
  ) async {
    final Map<String, dynamic> map;
    try {
      map = jsonDecode(payload) as Map<String, dynamic>;
    } catch (_) {
      return payload;
    }
    if (map['uid'] is! int) return payload;
    final path = map['mailboxPath'] ?? map['src'];
    if (path is! String) return payload;
    final moves = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(resourceId) &
                t.state.isIn(_liveStates) &
                t.changeType.isIn(_locationChangeTypes),
          ))
        .get();
    if (!moves.any((m) => _decodePayload(m)?['dest'] == path)) return payload;
    map[_uidAfterMoveKey] = true;
    if (map['messageId'] == null) {
      final messageId = await _messageIdOf(resourceId);
      if (messageId != null) map['messageId'] = messageId;
    }
    return jsonEncode(map);
  }

  /// Payload key set by [_markUidAfterQueuedMove].
  static const _uidAfterMoveKey = 'uidAfterMove';

  /// Whether [emailId] refers to a local self-sent "virtual" row (#545).
  Future<bool> _isLocalEmail(String emailId) async {
    final row = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.isLocal])
          ..where(_db.emails.id.equals(emailId))
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.emails.isLocal) ?? false;
  }

  /// Atomically claims [snapshot] for a flush: `inflight` with a lease
  /// ([_leaseDuration]), so [cancelPendingChange] (which only removes
  /// `pending` rows nothing was sent for) can no longer delete a change that
  /// is being applied, and no other flush (another isolate or process on
  /// the same database) takes it. Otherwise an Undo racing the flush would
  /// "cancel" a MOVE that still lands on the server and skip its reverse
  /// move (#1048). Every outcome then settles the row: deleted when applied,
  /// back to `pending` ([_unclaimPendingChange], [_keepClaimWithoutCharge],
  /// [_recordChangeError]) or `failed`.
  ///
  /// Returns null when the row was cancelled, claimed by another flush or
  /// marked failed since the flush took its snapshot — the caller must then
  /// skip it.
  /// Otherwise returns the row as currently stored: an earlier change in the
  /// same flush may have re-keyed it ([_rekeyEmailRow] rewrites `resourceId`
  /// and the payload UID). Claiming charges no attempt; [_recordChangeError]
  /// does, from the row's attempts.
  Future<PendingChangeRow?> _claimPendingChange(
    PendingChangeRow snapshot,
  ) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where(
            (t) =>
                t.id.equals(snapshot.id) &
                t.state.equals(snapshot.state) &
                t.attempts.equals(snapshot.attempts) &
                (snapshot.state == _stuckState
                    ? t.leaseUntil.isSmallerOrEqualValue(_now())
                    : const Constant(true)),
          ))
        .write(
      PendingChangesCompanion(
        state: const Value(_inflightState),
        leaseUntil: Value(_now().add(_leaseDuration)),
        claimToken: Value(_flushToken()),
      ),
    );
    if (count == 0) return null;
    return (_db.select(_db.pendingChanges)
          ..where((t) => t.id.equals(snapshot.id)))
        .getSingleOrNull();
  }

  /// This flush's claim token (set by [flushPendingChanges] under
  /// [_flushTokenKey]); a fresh one outside a flush.
  static String _flushToken() =>
      Zone.current[_flushTokenKey] as String? ?? _newClaimToken();

  static final _claimRandom = math.Random.secure();

  static String _newClaimToken() => List.generate(
        16,
        (_) => _claimRandom.nextInt(16).toRadixString(16),
      ).join();

  /// Whether the stored row of [row], a change claimed by a flush, is still
  /// that flush's claim: `inflight` under the claim token [row] was claimed
  /// with. Every outcome write checks it, so a flush whose lease ran out
  /// (e.g. suspended by laptop sleep) and was taken over cannot overwrite
  /// the new claim.
  Expression<bool> _ownsClaim($PendingChangesTable t, PendingChangeRow row) {
    final token = row.claimToken;
    return t.id.equals(row.id) &
        t.state.equals(_inflightState) &
        (token == null ? t.claimToken.isNull() : t.claimToken.equals(token));
  }

  /// Extends the claim of [row] before a slow apply (the one-by-one
  /// fallback of a batch claimed up front). Null when the claim was lost.
  Future<PendingChangeRow?> _renewClaim(PendingChangeRow row) async {
    final count = await (_db.update(_db.pendingChanges)
          ..where((t) => _ownsClaim(t, row)))
        .write(
      PendingChangesCompanion(leaseUntil: Value(_now().add(_leaseDuration))),
    );
    if (count == 0) return null;
    return (_db.select(_db.pendingChanges)..where((t) => t.id.equals(row.id)))
        .getSingleOrNull();
  }

  /// Settles the changes this flush claimed (claim token [token]) but left
  /// `inflight` (an unexpected error between claim and outcome): back to
  /// `pending`, one attempt charged, since they may have reached the server.
  Future<void> _releaseUnsettledClaims(String accountId, String token) async {
    final left = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.equals(_inflightState) &
                t.claimToken.equals(token),
          ))
        .get();
    for (final row in left) {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(_requeued(row.attempts + 1));
      if (count > 0) {
        log('Pending change ${row.id} left in flight by its flush; released');
      }
    }
  }

  /// Changes of [accountId] still `inflight` after their lease ran out: the
  /// app (or a second process) died while sending them, so they may or may
  /// not have reached the server. Each goes back to `pending` with one
  /// attempt charged, as the old claim marker did, and is sent again; the
  /// retry limit is applied by that resend, not here, so a change that
  /// probably landed is not given up on unseen. Every apply path first
  /// checks whether the change is already done (a move finds the mail in its
  /// destination, a flag STORE is idempotent, a delete of a gone mail counts
  /// as applied). Compare-and-set, so two flushes recovering at once charge
  /// it once.
  Future<void> _recoverExpiredLeases(String accountId) async {
    final expired = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.state.equals(_inflightState) &
                (t.leaseUntil.isNull() |
                    t.leaseUntil.isSmallerOrEqualValue(_now())),
          ))
        .get();
    for (final row in expired) {
      final count = await (_db.update(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, row)))
          .write(
        _requeued(row.attempts + 1).copyWith(
          lastError: const Value('interrupted while sending (app closed?)'),
        ),
      );
      if (count > 0) {
        log('Pending change ${row.id}: lease expired, will be sent again');
      }
    }
  }

  /// Whether change [id] is still queued (pending or stuck), i.e. will be
  /// retried.
  Future<bool> _stillQueued(int id) async =>
      await (_db.select(_db.pendingChanges)
            ..where(
              (t) =>
                  t.id.equals(id) &
                  t.state.isIn(const [_pendingState, _stuckState]),
            ))
          .getSingleOrNull() !=
      null;

  /// Mails with a change some other flush is sending now, or a stuck change
  /// this flush did not select (not due when it took its snapshot of
  /// [selected] ids): this flush leaves all their changes alone, so a mail's
  /// changes reach the server in order.
  Future<Set<String>> _mailsInFlightElsewhere(
    String accountId, {
    required Set<int> selected,
  }) async {
    final ids = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                (_db.pendingChanges.state.equals(_inflightState) |
                    (_db.pendingChanges.state.equals(_stuckState) &
                        _db.pendingChanges.id.isNotIn(selected))),
          ))
        .map((r) => r.read(_db.pendingChanges.resourceId)!)
        .get();
    return ids.toSet();
  }

  @override
  Future<bool> cancelPendingChange(String emailId, String changeType) async {
    // Find the latest pending change for this email/type that no flush has
    // picked up yet (see [_claimPendingChange]).
    final query = _db.select(_db.pendingChanges)
      ..where(
        (t) =>
            t.resourceId.equals(emailId) &
            t.changeType.equals(changeType) &
            t.state.equals(_pendingState) &
            t.attempts.equals(0),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(1);

    final row = await query.getSingleOrNull();
    if (row == null) return false;
    final count = await (_db.delete(
      _db.pendingChanges,
    )..where((t) => t.id.equals(row.id)))
        .go();
    if (count == 0) return false;
    if (_locationChangeTypes.contains(changeType)) {
      await _unmarkAfterCancelledMove(row);
    }
    return true;
  }

  /// After [cancelled], a queued move, was cancelled (Undo), the changes
  /// queued behind it for the mail in its destination
  /// ([_markUidAfterQueuedMove]) act in its source again: the mail stays
  /// there, under the UID they carry. They stay marked when another move
  /// queued before them still brings the mail to that source.
  Future<void> _unmarkAfterCancelledMove(PendingChangeRow cancelled) async {
    final moved = _decodePayload(cancelled);
    final src = moved?['mailboxPath'] ?? moved?['src'];
    final dest = moved?['dest'];
    if (src is! String || dest is! String) return;
    final queued = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(cancelled.resourceId) &
                t.state.isIn(_liveStates),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    for (final change in queued) {
      if (change.id < cancelled.id) continue;
      final payload = _decodePayload(change);
      if (payload == null || payload[_uidAfterMoveKey] != true) continue;
      final key = payload.containsKey('mailboxPath') ? 'mailboxPath' : 'src';
      if (payload[key] != dest) continue;
      final stillMoved = queued.any(
        (m) =>
            m.id < change.id &&
            _locationChangeTypes.contains(m.changeType) &&
            _decodePayload(m)?['dest'] == src,
      );
      // The cancelled move's stamp is the source's UIDVALIDITY.
      payload
        ..[key] = src
        ..remove('uidValidity');
      if (moved?['uidValidity'] case final int validity) {
        payload['uidValidity'] = validity;
      }
      if (!stillMoved) payload.remove(_uidAfterMoveKey);
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(change.id)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
    }
  }

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) {
      // The row can disappear between opening the snooze picker and
      // confirming (concurrent sync move/delete, optimistic move that
      // reassigned the id). Degrade to a no-op instead of crashing.
      log('snoozeEmail: email $emailId no longer exists; skipping');
      return;
    }
    await _snoozeRow(row, until);
    await _mirrorSnoozeToCounterparts(
      row.accountId,
      row.messageId,
      until: until,
    );
  }

  /// Snoozes a single [row] on its own account: moves it to that account's
  /// Snoozed mailbox, records [until] locally and enqueues the protocol change.
  Future<void> _snoozeRow(Email row, DateTime until) async {
    final accountId = row.accountId;
    final destPath = await _snoozedMailboxPath(accountId);

    // A queued keyword cleanup from an earlier stale snooze would strip the
    // keyword this snooze is about to add.
    await (_db.delete(_db.pendingChanges)
          ..where(
            (t) =>
                t.resourceId.equals(row.id) &
                t.changeType.equals('clear_snooze'),
          ))
        .go();

    // Optimistic local update.
    await _applyLocalSnooze(row, destPath, until);

    await _enqueueChange(
      accountId,
      row.id,
      'snooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': destPath,
        'until': until.toIso8601String(),
        // Lets the IMAP flush re-find a stale UID by Message-ID, as a move
        // does (#1048).
        if (row.messageId != null) 'messageId': row.messageId,
        ..._prevSnooze(row),
      }),
    );

    unawaited(
      _appLogger?.info(
        'email.snooze',
        'Snoozed "${row.subject ?? '(no subject)'}" until '
            '${until.toIso8601String()}',
        emailId: row.id,
        accountId: accountId,
        mailboxPath: destPath,
        data: {
          'src': row.mailboxPath,
          'dest': destPath,
          'until': until.toIso8601String(),
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of snoozing [row] into [destPath] until
  /// [until]. No change is queued here (see [_snoozeRow]).
  Future<void> _applyLocalSnooze(
    Email row,
    String destPath,
    DateTime until,
  ) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(destPath),
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(row.mailboxPath),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, destPath, row.threadId ?? row.id);
  }

  /// The path of [accountId]'s Snoozed mailbox (by role, then by name), or
  /// the literal `Snoozed` when it is not known locally yet — the snooze flush
  /// creates it on the server.
  Future<String> _snoozedMailboxPath(String accountId) async {
    var snoozedMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    snoozedMailbox ??= await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.name.equals(_snoozedPlaceholder),
          )
          ..limit(1))
        .getSingleOrNull();

    return snoozedMailbox?.path ?? _snoozedPlaceholder;
  }

  /// The Snoozed mailbox's name, and the stand-in path a snooze uses while
  /// the folder is not known locally yet (the flush resolves or creates it).
  static const _snoozedPlaceholder = 'Snoozed';

  @override
  Future<bool> isSnoozedMailbox(String accountId, String mailboxPath) async =>
      _isSnoozedPath(mailboxPath, await _snoozedMailboxPath(accountId));

  /// Whether [mailboxPath] is the Snoozed folder at [snoozedPath], or the
  /// literal `Snoozed` a snooze queued before that folder was known uses.
  static bool _isSnoozedPath(String mailboxPath, String snoozedPath) =>
      mailboxPath == snoozedPath || mailboxPath == _snoozedPlaceholder;

  @override
  Future<int> wakeUpEmails(String accountId) =>
      _asAutomaticChange(() => _wakeUpEmails(accountId));

  Future<int> _wakeUpEmails(String accountId) async {
    final now = DateTime.now();
    final expired = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.snoozedUntil.isSmallerOrEqualValue(now),
          ))
        .get();

    if (expired.isEmpty) return 0;

    final snoozedPath = await _snoozedMailboxPath(accountId);
    // A mail whose move/snooze/unsnooze failed waits for the user's Retry or
    // Discard: waking it would queue a change that fails the same way on
    // every cycle.
    final failedIds = (await (_db.selectOnly(_db.pendingChanges)
              ..addColumns([_db.pendingChanges.resourceId])
              ..where(
                _db.pendingChanges.accountId.equals(accountId) &
                    _db.pendingChanges.state.equals(_failedState) &
                    _db.pendingChanges.changeType.isIn(_locationChangeTypes),
              ))
            .map((r) => r.read(_db.pendingChanges.resourceId)!)
            .get())
        .toSet();
    var woken = 0;
    for (final row in expired) {
      if (failedIds.contains(row.id)) continue;
      // Only a mail still waiting in the Snoozed folder goes back to the
      // Inbox. One the user (or another client) filed elsewhere since keeps
      // its place; its stale snooze is dropped, and so is the server-side
      // `snz:` keyword sync would otherwise keep reading back.
      if (!_isSnoozedPath(row.mailboxPath, snoozedPath)) {
        await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
          const EmailsCompanion(
            snoozedUntil: Value(null),
            snoozedFromMailboxPath: Value(null),
          ),
        );
        await _enqueueChange(
          accountId,
          row.id,
          'clear_snooze',
          jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
        );
        continue;
      }
      await _unsnoozeRow(row);
      await _mirrorSnoozeToCounterparts(
        row.accountId,
        row.messageId,
        until: null,
      );
      woken++;
    }
    return woken;
  }

  @override
  Future<void> restoreLocalSnooze(
    String emailId, {
    required DateTime until,
    String? fromMailboxPath,
  }) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(fromMailboxPath),
      ),
    );
  }

  /// Un-snoozes a single [row] on its own account: moves it back to that
  /// account's Inbox, clears the snooze columns and enqueues the change.
  Future<void> _unsnoozeRow(Email row) async {
    final accountId = row.accountId;

    // Per instructions: "get to inbox moved by app".
    final inbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    final dest = inbox?.path ?? 'INBOX';

    await _enqueueChange(
      accountId,
      row.id,
      'unsnooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': dest,
        ..._prevSnooze(row),
      }),
    );

    // Optimistic local update.
    await _applyLocalUnsnooze(row, dest);

    unawaited(
      _appLogger?.info(
        'email.unsnooze',
        'Un-snoozed "${row.subject ?? '(no subject)'}" back to $dest',
        emailId: row.id,
        accountId: accountId,
        mailboxPath: dest,
        data: {
          'src': row.mailboxPath,
          'dest': dest,
          if (row.messageId != null) 'messageId': row.messageId,
        },
      ),
    );
  }

  /// The optimistic local part of un-snoozing [row] back to [dest]. No change
  /// is queued here (see [_unsnoozeRow]).
  Future<void> _applyLocalUnsnooze(Email row, String dest) async {
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(dest),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _updateThread(
      row.accountId,
      row.mailboxPath,
      row.threadId ?? row.id,
    );
    await _updateThread(row.accountId, dest, row.threadId ?? row.id);
  }

  /// Mirrors a snooze (or an un-snooze when [until] is null) onto the matching
  /// message in every counterpart account — the same server mailbox connected
  /// via the other protocol (see [AccountComparison]).
  ///
  /// A user who connects to one server via both IMAP and JMAP has two
  /// independent [Account] rows, each with its own copy of every message, so
  /// snoozing on one account leaves the other untouched. This bridges them:
  /// messages are correlated by their normalised RFC 2822 Message-ID and the
  /// same optimistic update + pending change is applied to the counterpart,
  /// which then flushes through that account's own protocol path.
  ///
  /// Best-effort: counterparts that haven't synced the message yet are skipped
  /// (their next sync reconstructs the snooze from the shared server-side
  /// `snz:` keyword anyway), and rows already in the requested state are left
  /// alone so no redundant change is enqueued.
  Future<void> _mirrorSnoozeToCounterparts(
    String sourceAccountId,
    String? messageId, {
    required DateTime? until,
  }) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;

      if (until != null) {
        // Already snoozed to (about) the same time → nothing to mirror.
        final current = row.snoozedUntil;
        if (current != null &&
            current.difference(until).abs() < const Duration(seconds: 1)) {
          continue;
        }
        await _snoozeRow(row, until);
      } else {
        // Already awake → nothing to mirror.
        if (row.snoozedUntil == null) continue;
        await _unsnoozeRow(row);
      }
    }
  }

  /// Looks up a single email row in [accountId] whose Message-ID matches [mid]
  /// (already run through [normaliseMessageId]). Matches both the bracket-less
  /// JMAP form and the legacy `<...>` IMAP form stored in the column.
  Future<Email?> _findEmailRowByNormalisedMessageId(
    String accountId,
    String mid,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          )
          ..limit(1))
        .getSingleOrNull();
  }

  /// Dissolves a local self-sent "virtual" message once its real counterpart
  /// [realEmailId] arrives in [arrivalMailboxPath] via sync: transfers the
  /// star, read state and folder the user set on the virtual copy onto the
  /// real message, then removes the virtual row. Notes need no migration —
  /// they are keyed by Message-ID, which both rows share. No-op when there is
  /// no matching local row, so it is safe to call for every synced message
  /// and safe to replay. See #545.
  @visibleForTesting
  Future<void> maybeDissolveLocalMessageForTest(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _maybeDissolveLocalMessage(
        accountId,
        arrivalMailboxPath,
        realEmailId,
        messageId,
      );

  /// Replays the user's earlier actions on a virtual row onto the real
  /// message: queued as automatic changes ([_asAutomaticChange]).
  Future<void> _maybeDissolveLocalMessage(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) =>
      _asAutomaticChange(
        () => _dissolveLocalMessage(
          accountId,
          arrivalMailboxPath,
          realEmailId,
          messageId,
        ),
      );

  Future<void> _dissolveLocalMessage(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    // A send can leave two virtual rows behind: the self-send note in the
    // inbox (#545) and, when the server gave us no APPENDUID, the Sent copy
    // (#918). Pair each with the arrival it actually is, keyed off the row id's
    // marker rather than its current folder — the user may well have filed the
    // note into Trash, and that move is exactly what dissolving carries over.
    // Matching the wrong one would move an inbox arrival into Sent.
    final arrivalIsSent =
        await _mailboxRole(accountId, arrivalMailboxPath) == 'sent';
    final local = await _localRowFor(accountId, mid, sentCopy: arrivalIsSent);
    if (local == null || local.id == realEmailId) return;

    final targetMailbox = local.mailboxPath;
    final wantFlagged = local.isFlagged;
    final wantSeen = local.isSeen;
    final localThreadId = local.threadId ?? local.id;

    // Remove the virtual row first so thread aggregates count only the real
    // message from here on.
    await (_db.delete(_db.emails)..where((t) => t.id.equals(local.id))).go();
    await (_db.delete(_db.emailBodies)
          ..where((t) => t.emailId.equals(local.id)))
        .go();
    await _updateThread(accountId, local.mailboxPath, localThreadId);

    final real = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(realEmailId)))
        .getSingleOrNull();
    if (real == null) return;

    // Carry the user's star / read state onto the real message. setFlag also
    // enqueues the matching server mutation so the two converge.
    final seenArg = wantSeen != real.isSeen ? wantSeen : null;
    final flaggedArg = wantFlagged != real.isFlagged ? wantFlagged : null;
    if (seenArg != null || flaggedArg != null) {
      await setFlag(realEmailId, seen: seenArg, flagged: flaggedArg);
    }

    // Carry the folder the user filed the note into (e.g. Trash) onto the real
    // message. moveEmail enqueues the server move and refreshes threads.
    if (targetMailbox != real.mailboxPath) {
      await moveEmail(realEmailId, targetMailbox);
    }
  }

  /// The virtual row for Message-ID [mid] on [accountId] that is — or is not,
  /// per [sentCopy] — the Sent-folder copy of a message we sent (#918), as
  /// opposed to a self-send inbox note (#545). Null when there is none.
  Future<Email?> _localRowFor(
    String accountId,
    String mid, {
    required bool sentCopy,
  }) async {
    final rows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.isLocal.equals(true) &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          ))
        .get();
    for (final row in rows) {
      if (_isLocalSentCopyId(row.id) == sentCopy) return row;
    }
    return null;
  }

  /// The RFC 8621 / RFC 6154 role of the mailbox at [path] on [accountId], or
  /// null for a role-less custom folder.
  Future<String?> _mailboxRole(String accountId, String path) async {
    final row = await (_db.selectOnly(_db.mailboxes)
          ..addColumns([_db.mailboxes.role])
          ..where(
            _db.mailboxes.accountId.equals(accountId) &
                _db.mailboxes.path.equals(path),
          )
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.mailboxes.role);
  }

  /// Mirrors a move (Archive / Spam / plain move) onto the matching message in
  /// every counterpart account — the same server mailbox connected via the
  /// other protocol (see [AccountComparison]).
  ///
  /// The destination path cannot simply be copied across: the IMAP and JMAP
  /// copies of the same server mailbox live under different [Mailbox.path]s. So
  /// the source destination's semantic [Mailbox.role] (e.g. `archive`, `junk`,
  /// `trash`) is resolved on each counterpart and used to locate the equivalent
  /// mailbox there; role-less custom folders fall back to a case-insensitive
  /// name match.
  ///
  /// Best-effort: counterparts that haven't synced the message yet, that have
  /// no equivalent destination mailbox, or that already hold the message in the
  /// destination are skipped so no redundant change is enqueued.
  Future<void> _mirrorMoveToCounterparts(
    String sourceAccountId,
    String? messageId,
    String destMailboxPath,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

    // Resolve the destination's role/name on the source account so the same
    // logical mailbox can be found on each counterpart.
    final sourceDest = await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(sourceAccountId) &
                t.path.equals(destMailboxPath),
          )
          ..limit(1))
        .getSingleOrNull();
    final destRole = sourceDest?.role;
    final destName = sourceDest?.name ?? destMailboxPath;

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;

      final counterpartDest = await _resolveCounterpartMailboxPath(
        counterpart.id,
        role: destRole,
        name: destName,
      );
      if (counterpartDest == null) {
        // The counterpart has no equivalent destination mailbox yet — e.g. an
        // Archive folder the primary account just created but that the
        // counterpart discovers only on a later mailbox sync. Both accounts
        // point at the same server, so the primary's move relocates the shared
        // message there and the counterpart will observe it leave the inbox on
        // its next sync. Until then, drop the now-stale local copy so the
        // combined inbox doesn't re-surface it as a duplicate of the message
        // the user just acted on (see #478).
        await _dropStaleCounterpartRow(row);
        continue;
      }
      // Already in the destination → nothing to mirror.
      if (row.mailboxPath == counterpartDest) continue;

      await _moveRow(row, counterpartDest);
    }
  }

  /// Removes a stale local counterpart email [row] from the cache without
  /// enqueuing a protocol change (the primary account already performs the
  /// real server move on the shared message) and refreshes its thread so the
  /// row stops appearing in the combined inbox until the next sync reconciles
  /// it to its true server location. See [_mirrorMoveToCounterparts].
  Future<void> _dropStaleCounterpartRow(Email row) async {
    await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
    await _updateThread(row.accountId, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Mirrors a delete onto the matching message in every counterpart account.
  /// Each counterpart runs its own [_deleteRow], so it independently moves the
  /// message to its own Trash when it has one, or hard-deletes otherwise —
  /// robust when only one side of the pair has a Trash folder.
  Future<void> _mirrorDeleteToCounterparts(
    String sourceAccountId,
    String? messageId,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    final source = await _accounts.getAccount(sourceAccountId);
    if (source == null) return;
    final all = await _accounts.observeAccounts().first;
    final counterparts = AccountComparison.counterpartsOf(source, all);
    if (counterparts.isEmpty) return;

    for (final counterpart in counterparts) {
      final row = await _findEmailRowByNormalisedMessageId(counterpart.id, mid);
      if (row == null) continue;
      await _deleteRow(row);
    }
  }

  /// Finds the path of the mailbox on [accountId] that corresponds to a move
  /// whose source destination had the given [role] / [name]. Matches in the
  /// same order [AccountComparison] pairs the two protocol views of one server:
  /// exact (role, name) first, then role alone (roles are protocol-independent),
  /// then a case-insensitive name match for role-less custom folders. Returns
  /// null when the counterpart has no equivalent mailbox.
  ///
  /// The exact pass matters because a role is not unique: Stalwart ships
  /// "Deleted Items" as its trash folder, so a mailbox the user (or a test)
  /// creates as "Trash" carries role `trash` too. Matching on the role alone
  /// picked whichever of the two came first out of the DB, mirroring the move
  /// into the *sibling* trash folder — the shared server message then sat in
  /// both folders at once, which the single-folder local model cannot
  /// represent, and the two accounts diverged for good (#910).
  Future<String?> _resolveCounterpartMailboxPath(
    String accountId, {
    required String? role,
    required String name,
  }) async {
    final mailboxes = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final lowerName = name.toLowerCase();
    for (final m in mailboxes) {
      if (m.role == role && m.name.toLowerCase() == lowerName) return m.path;
    }
    if (role != null) {
      for (final m in mailboxes) {
        if (m.role == role) return m.path;
      }
    }
    for (final m in mailboxes) {
      if (m.name.toLowerCase() == lowerName) return m.path;
    }
    return null;
  }

  @override
  Future<model.Email?> findEmailByMessageId(
    String accountId,
    String messageId, {
    String? preferMailboxPath,
  }) async {
    final row = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          )
          ..orderBy([
            if (preferMailboxPath != null)
              (t) => OrderingTerm.desc(t.mailboxPath.equals(preferMailboxPath)),
          ])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<void> restoreEmails(List<model.Email> emails) async {
    for (final e in emails) {
      await _db.into(_db.emails).insertOnConflictUpdate(
            EmailsCompanion.insert(
              id: e.id,
              accountId: e.accountId,
              mailboxPath: e.mailboxPath,
              uid: e.uid,
              subject: Value(e.subject),
              sentAt: Value(e.sentAt),
              receivedAt: e.receivedAt,
              fromJson: Value(jsonEncode(e.from)),
              toAddresses: Value(jsonEncode(e.to)),
              ccJson: Value(jsonEncode(e.cc)),
              replyToJson: Value(jsonEncode(e.replyTo)),
              bccJson: Value(jsonEncode(e.bcc)),
              sizeBytes: Value(e.size),
              preview: Value(e.preview),
              isSeen: Value(e.isSeen),
              isFlagged: Value(e.isFlagged),
              hasAttachment: Value(e.hasAttachment),
              threadId: Value(e.threadId),
              messageId: Value(e.messageId),
              inReplyTo: Value(e.inReplyTo),
              references: Value(e.references),
              snoozedUntil: Value(e.snoozedUntil),
              snoozedFromMailboxPath: Value(e.snoozedFromMailboxPath),
            ),
          );
      await _updateThread(e.accountId, e.mailboxPath, e.threadId ?? e.id);
    }
  }

  /// Applies locally stored active Sieve rules to INBOX emails that have not
  /// been processed yet. See [EmailRepository.applySieveRules] for details.
  @override
  Future<int> applySieveRules(String accountId) async {
    final scriptRow = await (_db.select(_db.localSieveScripts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.isActive.equals(true),
          )
          ..limit(1))
        .getSingleOrNull();
    if (scriptRow == null) return 0;

    List<SieveRule> rules;
    try {
      rules = SieveParser().parse(scriptRow.content);
    } catch (e) {
      log('Sieve parse error for account $accountId: $e');
      return 0;
    }
    if (rules.isEmpty) return 0;

    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: true,
      countMode: _SieveCountMode.visibleEffect,
      enqueueActions: true,
    );
  }

  @override
  Future<int> previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) async {
    final rules = SieveParser().parse(scriptContent);
    if (rules.isEmpty) return 0;
    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: false,
      countMode: _SieveCountMode.anyMatch,
      enqueueActions: false,
    );
  }

  @override
  Future<int> applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) async {
    final rules = SieveParser().parse(scriptContent);
    if (rules.isEmpty) return 0;
    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: false,
      countMode: _SieveCountMode.anyMatch,
      enqueueActions: true,
    );
  }

  /// Shared driver used by [applySieveRules], [previewSieveRuleMatches] and
  /// [applySieveScriptToInbox]. Iterates INBOX messages, runs [rules] against
  /// each one and — depending on [enqueueActions] — enqueues the resulting
  /// moves/deletes/flag changes and records the message in LocalSieveApplied.
  Future<int> _runSieveOverInbox({
    required String accountId,
    required List<SieveRule> rules,
    required bool skipAlreadyApplied,
    required _SieveCountMode countMode,
    required bool enqueueActions,
  }) async {
    final inboxMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    final inboxPath = inboxMailbox?.path ?? 'INBOX';

    final Set<String> appliedIds;
    if (skipAlreadyApplied) {
      final alreadyApplied = await (_db.select(
        _db.localSieveApplied,
      )..where((t) => t.accountId.equals(accountId)))
          .get();
      appliedIds = alreadyApplied.map((r) => r.messageId).toSet();
    } else {
      appliedIds = const {};
    }

    // LocalSieveApplied is keyed on the Message-ID, which survives moves, so
    // the automatic run can only remember mail that has one and skips the
    // rest. The preview and the explicit "apply now" remember nothing, so
    // they take every inbox mail, with or without a Message-ID.
    final inboxEmails = await (_db.select(_db.emails)
          ..where(
            (t) {
              final inInbox = t.accountId.equals(accountId) &
                  t.mailboxPath.equals(inboxPath);
              return skipAlreadyApplied
                  ? inInbox & t.messageId.isNotNull()
                  : inInbox;
            },
          ))
        .get();

    final account = (await _accounts.getAccount(accountId))!;
    final interpreter = SieveInterpreter();
    var matched = 0;

    for (final row in inboxEmails) {
      final msgId = row.messageId;
      if (skipAlreadyApplied && appliedIds.contains(msgId)) continue;

      final emailCtx = _buildSieveContext(row);

      SieveExecutionContext result;
      try {
        result = interpreter.execute(rules, emailCtx);
      } catch (e) {
        log('Sieve interpreter error for message ${msgId ?? row.id}: $e');
        if (enqueueActions && msgId != null) {
          await _markSieveApplied(accountId, msgId);
        }
        continue;
      }

      final counts = switch (countMode) {
        _SieveCountMode.anyMatch => result.anyRuleMatched,
        _SieveCountMode.visibleEffect => result.isCancelled ||
            result.targetFolders.isNotEmpty ||
            result.flagsToAdd.isNotEmpty,
      };

      if (counts) matched++;

      if (!enqueueActions) continue;

      if (msgId != null) await _markSieveApplied(accountId, msgId);

      if (result.isCancelled) {
        await _enqueueSieveDelete(account, row);
        continue;
      }
      // Flags first: an IMAP move re-keys the row (new UID in the
      // destination), so a flag change queued after it would address the
      // vanished source UID. Queued before, it is flushed first and the
      // MOVE carries the flags along (RFC 6851 keeps them; JMAP ids are
      // stable anyway). This also matches RFC 5232, where `fileinto`
      // files the message with the flags set so far.
      if (result.flagsToAdd.isNotEmpty) {
        await _enqueueSieveFlags(account, row, result.flagsToAdd);
      }
      if (result.targetFolders.isNotEmpty) {
        // The local model holds a message in exactly one folder, so a
        // script with several `fileinto` targets (copies, in Sieve) is
        // applied as a move to the first one.
        if (result.targetFolders.length > 1) {
          log(
            'Sieve: message ${row.id} has ${result.targetFolders.length} '
            'fileinto targets; moving to the first only',
          );
        }
        await _enqueueSieveMove(account, row, result.targetFolders.first);
      }
    }
    return matched;
  }

  SieveEmailContext _buildSieveContext(Email row) {
    String formatAddrs(String json) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        return list.map((e) {
          final m = e as Map<String, dynamic>;
          final name = m['name'] as String? ?? '';
          final email = m['email'] as String? ?? '';
          return name.isEmpty ? email : '$name <$email>';
        }).join(', ');
      } catch (_) {
        return '';
      }
    }

    return SieveEmailContext(
      headers: {
        if (row.subject != null && row.subject!.isNotEmpty)
          'subject': [row.subject!],
        'from': [formatAddrs(row.fromJson)],
        'to': [formatAddrs(row.toAddresses)],
        'cc': [formatAddrs(row.ccJson)],
        if (row.messageId != null) 'message-id': [row.messageId!],
      },
      sizeBytes: row.sizeBytes,
    );
  }

  Future<void> _markSieveApplied(String accountId, String messageId) async {
    await _db.into(_db.localSieveApplied).insertOnConflictUpdate(
          LocalSieveAppliedCompanion.insert(
            accountId: accountId,
            messageId: messageId,
            appliedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _enqueueSieveMove(
    account_model.Account account,
    Email row,
    String folder,
  ) async {
    String destPath;
    if (account.type == account_model.AccountType.jmap) {
      final destMailbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(account.id) & t.name.equals(folder),
            )
            ..limit(1))
          .getSingleOrNull();
      if (destMailbox == null) {
        log(
          'Sieve: JMAP mailbox "$folder" not found for account ${account.id}',
        );
        return;
      }
      destPath = destMailbox.path;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({'src': row.mailboxPath, 'dest': destPath}),
        supersedeFailures: false,
      );
    } else {
      destPath = folder;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'dest': destPath,
        }),
        supersedeFailures: false,
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(mailboxPath: Value(destPath)),
    );
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
    await _updateThread(account.id, destPath, row.threadId ?? row.id);
  }

  Future<void> _enqueueSieveDelete(
    account_model.Account account,
    Email row,
  ) async {
    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        row.id,
        'delete',
        jsonEncode(<String, dynamic>{}),
        supersedeFailures: false,
      );
    } else {
      await _enqueueChange(
        account.id,
        row.id,
        'delete',
        jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
        supersedeFailures: false,
      );
    }
    await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Applies the Sieve `setflag` / `addflag` / mark / star actions in
  /// [flags] to [row]. `\Seen` and `\Flagged` go through [setFlag], the same
  /// path as the read/star buttons, so the local row, thread and push stay
  /// consistent. Any other flag or keyword is queued as an `add_keywords`
  /// change; the app has no local column for those, so it is server-only.
  /// Strings that are not valid IMAP flags are dropped (see
  /// [normalizeSieveFlags]) and logged.
  Future<void> _enqueueSieveFlags(
    account_model.Account account,
    Email row,
    Set<String> flags,
  ) async {
    final normalized = normalizeSieveFlags(flags);
    if (normalized.dropped.isNotEmpty) {
      log(
        'Sieve: ignoring invalid flags ${normalized.dropped} for message '
        '${row.id}',
      );
      unawaited(
        _appLogger?.warn(
          'sieve.flag_ignored',
          'Local filter flag(s) ignored: ${normalized.dropped.join(', ')}',
          accountId: account.id,
          emailId: row.id,
          mailboxPath: row.mailboxPath,
        ),
      );
    }
    final seen = normalized.flags.contains(r'\Seen');
    final flagged = normalized.flags.contains(r'\Flagged');
    if (seen || flagged) {
      await _asAutomaticChange(
        () => _setFlag(
          row.id,
          seen: seen ? true : null,
          flagged: flagged ? true : null,
          source: 'sieve',
        ),
      );
    }
    final keywords = normalized.flags
        .where((f) => f != r'\Seen' && f != r'\Flagged')
        .toList()
      ..sort();
    if (keywords.isEmpty) return;
    await _enqueueChange(
      account.id,
      row.id,
      'add_keywords',
      jsonEncode(
        account.type == account_model.AccountType.jmap
            ? {'keywords': keywords}
            : {
                'uid': row.uid,
                'mailboxPath': row.mailboxPath,
                'keywords': keywords,
              },
      ),
      supersedeFailures: false,
    );
  }

  /// Maps an IMAP flag or keyword from [normalizeSieveFlags] to its JMAP
  /// keyword (RFC 8621 §4.1.1): system flags become their `$` form, keywords
  /// are case-insensitive and lower-cased.
  static String _imapFlagToJmapKeyword(String flag) {
    final lower = flag.toLowerCase();
    return lower.startsWith(r'\') ? '\$${lower.substring(1)}' : lower;
  }

  /// Drains pending changes for [accountId] via the appropriate protocol.
  /// Called at the start of each sync cycle. Returns count of applied changes.
  @override
  Future<int> flushPendingChanges(String accountId, String password) async {
    await _recoverExpiredLeases(accountId);
    final now = _now();
    final rows = await (_db.select(_db.pendingChanges)
          // A failed change waits for the user's Retry or Discard; a stuck one
          // for its next try.
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.state.equals(_pendingState) |
                    (t.state.equals(_stuckState) &
                        t.leaseUntil.isSmallerOrEqualValue(now))),
          )
          // Flush in enqueue order. The autoincrement id gives that exactly;
          // `createdAt` can tie for changes queued together (a Sieve flag +
          // move) and would follow the wall clock if it steps back.
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();
    if (rows.isEmpty) return 0;

    final account = (await _accounts.getAccount(accountId))!;
    final token = _newClaimToken();
    try {
      return await runZoned(
        () async {
          switch (account.type) {
            case account_model.AccountType.imap:
              return _flushPendingChangesImap(account, password, rows);
            case account_model.AccountType.jmap:
              return _flushPendingChangesJmap(account, password, rows);
          }
        },
        zoneValues: {_flushTokenKey: token},
      );
    } finally {
      await _releaseUnsettledClaims(accountId, token);
    }
  }

  Future<int> _flushPendingChangesJmap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return 0;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    var applied = 0;
    // Mails whose move/snooze/unsnooze/delete did not apply in this flush:
    // their later changes address the mail where that change would have put
    // it, so they wait (unclaimed, uncharged) for the next flush.
    final blocked = await _mailsInFlightElsewhere(
      account.id,
      selected: {for (final r in rows) r.id},
    );

    for (final snapshot in rows) {
      if (blocked.contains(snapshot.resourceId)) continue;
      final row = await _claimPendingChange(snapshot);
      if (row == null) {
        // Cancelled, failed or claimed by another flush since the snapshot:
        // the mail's later changes wait for the next flush.
        blocked.add(snapshot.resourceId);
        continue;
      }
      final placement = _placementChangeTypes.contains(row.changeType);
      if (placement) {
        // Unblocked again below once it applied.
        blocked.add(row.resourceId);
      }
      try {
        // Pending-change `Email/set`s deliberately omit `ifInState`: each patch
        // targets a single email's own `mailboxIds`/`keywords`, so it is safe
        // to apply regardless of unrelated concurrent changes. Sending
        // `ifInState` made a routine move fail with `stateMismatch` whenever
        // the account's Email state had moved on (issue #746). We also leave
        // the Email checkpoint untouched — the next `Email/changes` sync
        // reconciles this mutation together with any concurrent server changes
        // (re-applying our own change is idempotent).
        await _applyPendingChangeJmap(jmap, row);
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.id.equals(row.id)))
            .go();
        applied++;
        blocked.remove(row.resourceId);
      } on JmapSetItemException catch (e) {
        if (e.type == 'notFound' && row.changeType == 'delete') {
          // The mail is already gone: the delete's intent is satisfied.
          blocked.remove(row.resourceId);
          await _deletePendingChange(row);
          log('JMAP change ${row.id} skipped: message already gone ($e)');
          unawaited(
            _appLogger?.info(
              'pending_change.skipped_gone',
              'Skipped ${_describeChange(row)} — message already gone on '
                  'the server',
              accountId: account.id,
              emailId: row.resourceId,
              data: {'changeType': row.changeType},
            ),
          );
          applied++;
          continue;
        }
        // Permanent per-item rejection (e.g. notFound, forbidden): retrying
        // cannot help, so mark it failed at once and keep it for the user.
        // `notFound`: the mail is gone, there is no place to go back to.
        if (!await _markChangeFailed(row, e, revert: e.type != 'notFound')) {
          continue;
        }
        log('JMAP permanent error for change ${row.id}: $e');
        unawaited(
          _appLogger?.error(
            'pending_change.rejected',
            'Server rejected ${_describeChange(row)}; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
      } catch (e) {
        if (isJmapNetworkError(e)) {
          // No answer from the server (offline, network switch, timeout):
          // no step towards giving up, like a failed IMAP connect (#1224).
          // The request may still have landed (a timeout does not cancel
          // it), so the claim stays: Undo must queue a reverse change, not
          // cancel this one (#1048). Sending it again is safe: a move sets
          // `mailboxIds`, flag patches are idempotent and a second destroy
          // answers `notFound`, which counts as applied. The rest of the
          // queue would fail the same way: stop and retry next sync.
          await _keepClaimWithoutCharge(row, e);
          log('JMAP flush for ${account.id} stopped: network error ($e)');
          break;
        }
        await _recordChangeError(row, e);
        // Retried later: the mail's later changes wait, so they keep their
        // order (a newer read/star change must not land before an older one
        // that is retried later).
        blocked.add(row.resourceId);
      }
    }
    return applied;
  }

  Future<int> _flushPendingChangesImap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    final imap.ImapClient client;
    try {
      client = await _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      );
    } catch (e) {
      // No change reached the server, so none is charged an attempt: a phone
      // offline for [_maxChangeAttempts] syncs must not silently drop the
      // user's queued actions. The next cycle retries; the sync's own connect
      // reports the failure (#1224).
      log('IMAP flush for ${account.id} skipped: connect failed ($e)');
      return 0;
    }
    var applied = 0;
    // Mails whose move/snooze/unsnooze/delete did not apply in this flush:
    // their later changes address the mail where that change would have put
    // it, so they wait (unclaimed, uncharged) for the next flush.
    final blocked = await _mailsInFlightElsewhere(
      account.id,
      selected: {for (final r in rows) r.id},
    );
    try {
      var next = 0;
      while (next < rows.length) {
        if (!client.isConnected) {
          // Lost between two changes: claim nothing more.
          log('IMAP flush for ${account.id} stopped: connection lost');
          break;
        }
        final batch = _imapMoveBatchAt(
          rows,
          next,
          batching: client.serverInfo.supportsUidPlus,
        );
        next += batch.length;
        final outcome = await _flushImapBatch(account, client, batch, blocked);
        applied += outcome.applied;
        if (outcome.connectionLost) break;
      }
    } finally {
      await closeImapClient(client);
    }
    return applied;
  }

  /// Upper bound on the UIDs sent in one batched `UID MOVE`.
  static const _maxImapMoveBatch = 50;

  /// The run of pending changes starting at [rows][[start]] that can share
  /// one `UID MOVE`: consecutive plain moves (no snooze cleanup) with the same
  /// source and destination and distinct UIDs. Any other change is a run of
  /// one. Order is preserved, so a batch never jumps over another change.
  ///
  /// Only with [batching] (the server supports UIDPLUS): without `COPYUID`
  /// every batched row would still need its own MOVE + search afterwards,
  /// costing more round trips than it saves.
  List<PendingChangeRow> _imapMoveBatchAt(
    List<PendingChangeRow> rows,
    int start, {
    required bool batching,
  }) {
    final first = rows[start];
    final head = _plainImapMove(first);
    if (!batching || head == null) return [first];
    final uids = <int>{};
    final batch = <PendingChangeRow>[];
    for (var i = start; i < rows.length; i++) {
      final row = rows[i];
      if (batch.length == _maxImapMoveBatch) break;
      final move = _plainImapMove(row);
      if (move == null || move.key != head.key) break;
      if (!uids.add(move.uid)) break;
      batch.add(row);
    }
    return batch;
  }

  /// Batch key (`'<source>\u0000<dest>'`) and UID of a plain IMAP move that
  /// can be batched; null for anything else, including an unreadable payload
  /// (which then fails on its own, as a run of one).
  ({String key, int uid})? _plainImapMove(PendingChangeRow row) {
    if (row.changeType != 'move') return null;
    try {
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      if (payload['clearSnooze'] == true) return null;
      // Its UID is not known yet: looked up on its own ([_currentImapUid]).
      if (payload[_uidAfterMoveKey] == true) return null;
      final src = payload['mailboxPath'];
      final dest = payload['dest'];
      final uid = payload['uid'];
      if (src is! String || dest is! String || uid is! int) return null;
      // Rows stamped with different UIDVALIDITYs never share a MOVE.
      return (
        key: '$src\u0000$dest\u0000${payload['uidValidity']}',
        uid: uid,
      );
    } catch (_) {
      return null;
    }
  }

  /// Applies [snapshots] — one change, or a batch from [_imapMoveBatchAt].
  ///
  /// A batch is claimed row by row, then moved with a single `UID MOVE`
  /// (#1224): one round trip instead of a SELECT + MOVE per message. Every
  /// row whose new UID the `COPYUID` reports is re-keyed and done; the rest
  /// (no UIDPLUS, a stale UID, a failed batch command) go through the
  /// one-by-one path, which re-checks where the message is.
  ///
  /// Skips the changes of mails in [blocked], and adds a mail to it when its
  /// move/snooze/unsnooze/delete does not apply (see
  /// [_flushPendingChangesImap]).
  Future<({int applied, bool connectionLost})> _flushImapBatch(
    account_model.Account account,
    imap.ImapClient client,
    List<PendingChangeRow> snapshots,
    Set<String> blocked,
  ) async {
    final claimed = <PendingChangeRow>[];
    for (final snapshot in snapshots) {
      if (blocked.contains(snapshot.resourceId)) continue;
      final row = await _claimPendingChange(snapshot);
      if (row == null) {
        // Cancelled, failed or claimed by another flush since the snapshot:
        // the mail's later changes wait for the next flush.
        blocked.add(snapshot.resourceId);
        continue;
      }
      claimed.add(row);
    }
    if (claimed.isEmpty) return (applied: 0, connectionLost: false);

    var applied = 0;
    var pending = claimed;
    if (claimed.length > 1) {
      final batch = await _batchImapMove(client, claimed);
      if (batch.error case final e?) {
        if (_isImapConnectionLost(client, e)) {
          if (batch.moveSent) {
            // The MOVE may have reached the server: charge every row.
            for (final row in claimed) {
              await _recordChangeError(row, e);
            }
          } else {
            // Nothing reached the server: undo the claims, so a dropped
            // connection costs no attempts (and Undo can still cancel).
            for (final row in claimed) {
              await _unclaimPendingChange(row);
            }
          }
          log('IMAP flush for ${account.id} stopped: connection lost ($e)');
          return (applied: 0, connectionLost: true);
        }
        // E.g. `NO` for the whole set: let each row get its own outcome.
        log('IMAP batch move failed, applying one by one: $e');
      }
      for (final row in batch.moved) {
        await _deletePendingChange(row);
        applied++;
      }
      pending = [
        for (final row in claimed)
          if (!batch.moved.contains(row)) row,
      ];
    }

    for (var i = 0; i < pending.length; i++) {
      var row = pending[i];
      if (blocked.contains(row.resourceId)) {
        await _unclaimPendingChange(row);
        continue;
      }
      if (claimed.length > 1) {
        // Claimed with the whole batch: the one-by-one applies before this
        // one may have taken a while.
        final renewed = await _renewClaim(row);
        if (renewed == null) {
          blocked.add(row.resourceId);
          continue;
        }
        row = renewed;
      }
      final outcome = await _settleImapChange(account, client, row);
      if (outcome.connectionLost != null) {
        // Rows of this batch claimed but not reached: give the claim back.
        for (final rest in pending.skip(i + 1)) {
          await _unclaimPendingChange(rest);
        }
        return (applied: applied, connectionLost: true);
      }
      applied += outcome.applied;
      // A move/delete that did not apply holds back the mail's later
      // changes (they address it where it would have put it); so does any
      // change that is retried later, so the mail's changes keep their order
      // (a newer read/star change must not land before an older one). A
      // change that failed for good does not.
      if (outcome.applied == 0 &&
          (_placementChangeTypes.contains(row.changeType) ||
              await _stillQueued(row.id))) {
        blocked.add(row.resourceId);
      }
    }
    return (applied: applied, connectionLost: false);
  }

  /// Settles a claimed [row] whose request got no answer: back to
  /// `pending`, marked as maybe sent (attempts at least 1, so
  /// [cancelPendingChange] leaves it alone) but charged nothing beyond
  /// that, with [error] recorded.
  Future<void> _keepClaimWithoutCharge(PendingChangeRow row, Object error) =>
      (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, row))).write(
        _requeued(math.max(row.attempts, 1))
            .copyWith(lastError: Value(error.toString())),
      );

  /// Returns a row claimed by [_claimPendingChange] to `pending`, for a
  /// change the flush never sent: no attempt charged, so Undo can still
  /// cancel it.
  Future<void> _unclaimPendingChange(PendingChangeRow claimed) =>
      (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, claimed)))
          .write(_requeued(claimed.attempts, dueNow: true));

  /// Sends one `UID MOVE` for all [rows] (same source and destination) and
  /// re-keys every row the `COPYUID` response maps. Returns those rows, the
  /// error that ended the attempt (if any), and whether the MOVE was sent.
  Future<({Set<PendingChangeRow> moved, Object? error, bool moveSent})>
      _batchImapMove(
    imap.ImapClient client,
    List<PendingChangeRow> rows,
  ) async {
    final payload = jsonDecode(rows.first.payload) as Map<String, dynamic>;
    final src = payload['mailboxPath'] as String;
    final dest = payload['dest'] as String;
    final uidOf = {
      for (final row in rows)
        row: (jsonDecode(row.payload) as Map<String, dynamic>)['uid'] as int,
    };
    try {
      final selected = await client.selectUnicodeMailboxByPath(src);
      final stamped = payload['uidValidity'];
      if (stamped is int &&
          selected.uidValidity != null &&
          selected.uidValidity != stamped) {
        // The UIDs may name other messages now: let the one-by-one path
        // look each up again by Message-ID ([_currentImapUid]).
        return (
          moved: <PendingChangeRow>{},
          error: StateError('UIDVALIDITY of $src changed'),
          moveSent: false,
        );
      }
    } catch (e) {
      return (moved: <PendingChangeRow>{}, error: e, moveSent: false);
    }
    final imap.GenericImapResult result;
    try {
      result = await client.uidMove(
        imap.MessageSequence.fromIds(uidOf.values.toList(), isUid: true),
        targetMailboxPath: dest,
      );
    } catch (e) {
      return (moved: <PendingChangeRow>{}, error: e, moveSent: true);
    }
    final moved = <PendingChangeRow>{};
    for (final MapEntry(key: row, value: uid) in uidOf.entries) {
      final newUid = _resolveCopyUid(result, uid);
      if (newUid == null) continue;
      // COPYUID maps it, so this only re-keys the local row (no command).
      await _remapEmailAfterImapMove(
        client,
        oldId: row.resourceId,
        sourceUid: uid,
        destMailboxPath: dest,
        moveResult: result,
      );
      moved.add(row);
    }
    return (moved: moved, error: null, moveSent: true);
  }

  /// The UID [row]'s change must act on in the selected [mailboxPath]. That
  /// is the payload's UID unless the folder's UIDVALIDITY changed since the
  /// change was queued ([_stampUidValidity]): the old UID may then name a
  /// different message, so the message is looked up again by Message-ID and
  /// acted on only when exactly one copy matches. Otherwise the change is
  /// moot ([_ImapMessageGoneException]): acting on the stale UID could flag,
  /// move or expunge someone else's mail.
  Future<int> _currentImapUid(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload, {
    required String mailboxPath,
    required int? selectedUidValidity,
  }) async {
    final uid = payload['uid'] as int;
    if (payload[_uidAfterMoveKey] == true) {
      return _uidAfterUnansweredMove(client, row, payload, mailboxPath);
    }
    final stamped = payload['uidValidity'];
    if (stamped is! int || selectedUidValidity == null) return uid;
    if (stamped == selectedUidValidity) return uid;
    // Only the Message-ID stamped at enqueue time: the local row behind
    // [row.resourceId] may be a different message since the reset.
    final messageId = payload['messageId'] as String?;
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      messageId,
      throwOnFailure: true,
      select: false,
    );
    if (uids.length != 1) {
      throw _ImapUidValidityChangedException(
        'UIDVALIDITY of $mailboxPath changed ($stamped → '
        '$selectedUidValidity) and ${uids.isEmpty ? 'no' : 'more than one'} '
        'message matches its Message-ID',
        // Only after a real search: none is made without a Message-ID.
        noMatch: uids.isEmpty && messageId != null && messageId.isNotEmpty,
      );
    }
    log(
      'IMAP change ${row.id}: UIDVALIDITY of $mailboxPath changed, '
      'UID $uid → ${uids.single} by Message-ID',
    );
    return uids.single;
  }

  /// The UID of [row]'s mail in the selected [mailboxPath] when the move
  /// queued before it reported none ([_markUidAfterQueuedMove]): its UID is
  /// the one from before that move, so the mail is looked up by Message-ID
  /// and acted on only when exactly one copy matches (#1266).
  Future<int> _uidAfterUnansweredMove(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload,
    String mailboxPath,
  ) async {
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      payload['messageId'] as String?,
      throwOnFailure: true,
      select: false,
    );
    if (uids.length != 1) {
      throw _ImapMessageGoneException(
        'the move queued before this change reported no new UID, and '
        '${uids.isEmpty ? 'no' : 'more than one'} message in $mailboxPath '
        'matches its Message-ID',
      );
    }
    return uids.single;
  }

  /// Applies a marked move ([_markUidAfterQueuedMove]) from the selected
  /// [mailboxPath]: its UID is not known, so the mail is found by Message-ID
  /// there, or in the destination when an earlier attempt already moved it
  /// and the answer was lost ([_retryImapMoveByMessageId]).
  Future<void> _applyMoveAfterUnansweredMove(
    imap.ImapClient client,
    PendingChangeRow row,
    Map<String, dynamic> payload,
    String mailboxPath,
  ) async {
    final messageId = payload['messageId'] as String?;
    if (messageId == null || messageId.isEmpty) {
      throw _ImapMessageGoneException(
        'the move queued before this one reported no new UID, and the mail '
        'has no Message-ID to find it by',
      );
    }
    await _retryImapMoveByMessageId(
      client,
      row: row,
      // No UID of this folder: none may count as "still in the source".
      staleUid: -1,
      mailboxPath: mailboxPath,
      destMailboxPath: payload['dest'] as String,
      messageId: messageId,
      // The source is selected; look in the destination before moving.
      movedNothing: true,
      beforeMove: payload['clearSnooze'] == true
          ? (s) => _removeImapSnoozeFlags(client, s)
          : null,
    );
  }

  /// The Message-ID of local email row [emailId], or null.
  Future<String?> _messageIdOf(String emailId) async {
    final row = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.messageId])
          ..where(_db.emails.id.equals(emailId))
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.emails.messageId);
  }

  /// True when [error] means [client]'s connection is gone, whatever the
  /// error's wording: a recognised connection error, or enough_mail reporting
  /// the socket closed.
  bool _isImapConnectionLost(imap.ImapClient client, Object error) =>
      isImapConnectionLost(error) || !client.isConnected;

  Future<void> _deletePendingChange(PendingChangeRow row) =>
      (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(row.id))).go();

  /// Applies one claimed [row] and settles it: deleted when applied, marked
  /// failed when it can never apply, error recorded otherwise.
  /// `connectionLost` carries the error when the connection died, so the
  /// caller stops the flush.
  Future<({int applied, Object? connectionLost})> _settleImapChange(
    account_model.Account account,
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    try {
      await _applyPendingChangeImap(client, row);
      await _deletePendingChange(row);
      return (applied: 1, connectionLost: null);
    } catch (e) {
      if (_isImapConnectionLost(client, e)) {
        // The connection is dead (e.g. network switch on mobile): every
        // further command would fail too. Count this attempt and leave the
        // remaining, unclaimed changes untouched for the next sync's fresh
        // connection. A command that merely timed out stops the flush too;
        // if one change keeps timing out, it is stuck after
        // [_maxChangeAttempts] and then tried only after its backoff.
        await _recordChangeError(row, e);
        log('IMAP flush for ${account.id} stopped: connection lost ($e)');
        return (applied: 0, connectionLost: e);
      }
      if (e is _ImapUidValidityChangedException &&
          e.noMatch &&
          row.changeType == 'delete') {
        // A delete for good of a mail that is not in the renumbered folder
        // any more: its intent is satisfied (SYNC-REDESIGN.md §5). The stale
        // UID was not touched.
        final owned = await (_db.delete(_db.pendingChanges)
                  ..where((t) => _ownsClaim(t, row)))
                .go() >
            0;
        if (!owned) return (applied: 0, connectionLost: null);
        log('IMAP change ${row.id} skipped: message already gone ($e)');
        unawaited(
          _appLogger?.info(
            'pending_change.skipped_gone',
            'Skipped ${_describeChange(row)} — message already gone on '
                'the server',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
          ),
        );
        return (applied: 1, connectionLost: null);
      }
      if (e is _ImapUidValidityChangedException) {
        // The folder was renumbered and the message cannot be identified
        // safely: mark the change failed rather than act on someone else's
        // mail. Nothing to go back to: the mail is not known there.
        if (!await _markChangeFailed(row, e, revert: false)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} failed: $e');
        unawaited(
          _appLogger?.warn(
            'pending_change.uidvalidity_changed',
            'Could not apply ${_describeChange(row)} — the server renumbered '
                'the folder and the message could not be found again; kept '
                'on the Pending Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      if (e is _ImapMessageGoneException) {
        // Retrying cannot bring the message back, but the user's move
        // (e.g. an Undo's reverse move, #1048) did not happen: mark the
        // change failed and say so in the App Log at warn level.
        // One transaction: a phantom row must not outlive a crash here.
        final (:dependents, :dropped) = await _db.transaction(() async {
          final dependents =
              await _markChangeFailedInTransaction(row, e, revert: false);
          // A lost claim's outcome is not ours to act on.
          if (dependents == null) return (dependents: null, dropped: null);
          final dropped = e.inNeitherMailbox ? await _dropGoneRow(row) : null;
          return (dependents: dependents, dropped: dropped);
        });
        if (dependents == null) return (applied: 0, connectionLost: null);
        log('IMAP change ${row.id} failed: $e');
        unawaited(
          _appLogger?.warn(
            'pending_change.message_gone',
            'Could not apply ${_describeChange(row)} — the message is no '
                'longer on the server (deleted or moved by another client); '
                'kept on the Pending Changes screen',
            accountId: account.id,
            // A log row must not reference the email row just dropped.
            emailId: dropped != null ? null : row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        _logDependentFailures(row, dependents);
        _logGoneRowDropped(
          row,
          dropped,
          why: 'a failed ${_describeChange(row)}: the message is in neither '
              'its source nor its destination folder on the server',
        );
        return (applied: 0, connectionLost: null);
      }
      final sourceGone = e is _ImapSourceMailboxGoneException;
      if (!sourceGone &&
          isImapMailboxNotFound(e) &&
          _locationChangeTypes.contains(row.changeType)) {
        // The source folder was selected, so the mail is still there: a
        // missing destination (`NO [TRYCREATE]` from the MOVE) means the
        // move did not happen. Mark it failed and show the mail where it is.
        if (!await _markChangeFailed(row, e)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} failed: destination missing ($e)');
        unawaited(
          _appLogger?.warn(
            'pending_change.dest_missing',
            'Could not apply ${_describeChange(row)} — the destination '
                'folder does not exist on the server; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      if (sourceGone || isImapMailboxNotFound(e)) {
        // The mail's folder is gone on the server, and the mail with it
        // (or, for a flag change or delete, the target is gone): treat as
        // success so the change doesn't accumulate or block future changes.
        final (:owned, :dropped) = await _db.transaction(() async {
          final owned = await (_db.delete(_db.pendingChanges)
                    ..where((t) => _ownsClaim(t, row)))
                  .go() >
              0;
          // A moved row sits in its destination with the deleted folder's
          // UID, naming whichever mail has that UID there (#1268). Only
          // while this flush still owns the change.
          final dropped = owned && sourceGone ? await _dropGoneRow(row) : null;
          return (owned: owned, dropped: dropped);
        });
        if (!owned) return (applied: 0, connectionLost: null);
        log('IMAP change ${row.id} skipped: message already gone ($e)');
        unawaited(
          _appLogger?.info(
            'pending_change.skipped_gone',
            'Skipped ${_describeChange(row)} — message already gone on '
                'the server',
            accountId: account.id,
            emailId: dropped != null ? null : row.resourceId,
            data: {'changeType': row.changeType},
          ),
        );
        _logGoneRowDropped(
          row,
          dropped,
          why: 'a skipped ${_describeChange(row)}: its source folder no '
              'longer exists on the server',
        );
        return (applied: 1, connectionLost: null);
      }
      if (isImapPermanentRefusal(e) || e is FormatException || e is TypeError) {
        // `NO [CANNOT]`, `[NOPERM]`, …, or a payload this app cannot read:
        // retrying cannot help. Failed at once, and the mail shows the
        // server's state again.
        if (!await _markChangeFailed(row, e)) {
          return (applied: 0, connectionLost: null);
        }
        log('IMAP change ${row.id} refused: $e');
        unawaited(
          _appLogger?.error(
            'pending_change.rejected',
            'Server rejected ${_describeChange(row)}; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
        return (applied: 0, connectionLost: null);
      }
      await _recordChangeError(row, e);
      return (applied: 0, connectionLost: null);
    }
  }

  Future<void> _applyPendingChangeImap(
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // snooze/unsnooze payloads use 'src' for the source folder; all others use 'mailboxPath'.
    final mailboxPath = (payload['mailboxPath'] ?? payload['src']) as String;
    final imap.Mailbox selected;
    try {
      selected = await client.selectUnicodeMailboxByPath(mailboxPath);
    } catch (e) {
      if (!isImapMailboxNotFound(e)) rethrow;
      throw _ImapSourceMailboxGoneException(e);
    }
    if (row.changeType == 'move' && payload[_uidAfterMoveKey] == true) {
      await _applyMoveAfterUnansweredMove(client, row, payload, mailboxPath);
      return;
    }
    final uid = await _currentImapUid(
      client,
      row,
      payload,
      mailboxPath: mailboxPath,
      selectedUidValidity: selected.uidValidity,
    );
    final seq = imap.MessageSequence.fromId(uid, isUid: true);

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        seen ? await client.uidMarkSeen(seq) : await client.uidMarkUnseen(seq);
      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        flagged
            ? await client.uidMarkFlagged(seq)
            : await client.uidMarkUnflagged(seq);
      case 'add_keywords':
        final keywords = (payload['keywords'] as List<dynamic>).cast<String>();
        await client.uidStore(seq, keywords, action: imap.StoreAction.add);
      case 'move':
        final dest = payload['dest'] as String;
        if (payload['clearSnooze'] == true) {
          await _removeImapSnoozeFlags(client, seq);
        }
        final result = await client.uidMove(seq, targetMailboxPath: dest);
        final movedNothing = _imapMoveMovedNothing(client, result);
        if (!movedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: result,
            )) {
          return;
        }
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          movedNothing: movedNothing,
          beforeMove: payload['clearSnooze'] == true
              ? (s) => _removeImapSnoozeFlags(client, s)
              : null,
        );
      case 'delete':
        await deleteAndExpungeUids(client, [uid]);
      case 'snooze':
        final until = payload['until'] as String;
        // ISO8601 with colons is fine for IMAP atoms, but we use a cleaner
        // format just in case.
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        final dest = payload['dest'] as String;
        try {
          await client.createMailbox(dest);
        } catch (_) {}
        Future<void> tag(imap.MessageSequence s) async {
          await client.uidStore(s, [keyword], action: imap.StoreAction.add);
        }

        await tag(seq);
        final snoozeResult = await client.uidMove(seq, targetMailboxPath: dest);
        final movedNothing = _imapMoveMovedNothing(client, snoozeResult);
        if (!movedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: snoozeResult,
            )) {
          return;
        }
        // A stale UID (e.g. Undo re-snoozing a row rebuilt from its snapshot)
        // makes STORE + MOVE silent no-ops: re-find the message like a move.
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          beforeMove: tag,
          movedNothing: movedNothing,
        );
      case 'unsnooze':
        final dest = payload['dest'] as String;
        try {
          await client.createMailbox(dest);
        } catch (_) {}
        await _removeImapSnoozeFlags(client, seq);
        final unsnoozeResult =
            await client.uidMove(seq, targetMailboxPath: dest);
        final unsnoozedNothing = _imapMoveMovedNothing(client, unsnoozeResult);
        if (!unsnoozedNothing &&
            await _remapEmailAfterImapMove(
              client,
              oldId: row.resourceId,
              sourceUid: uid,
              destMailboxPath: dest,
              moveResult: unsnoozeResult,
            )) {
          return;
        }
        // E.g. another device woke the mail first: find it like a move, so
        // the row is re-keyed where it is, or dropped when it is gone,
        // instead of keeping the Snoozed folder's UID in [dest] (#1268).
        await _retryImapMoveByMessageId(
          client,
          row: row,
          staleUid: uid,
          mailboxPath: mailboxPath,
          destMailboxPath: dest,
          messageId: payload['messageId'] as String?,
          beforeMove: (s) => _removeImapSnoozeFlags(client, s),
          movedNothing: unsnoozedNothing,
        );
      case 'clear_snooze':
        await _clearImapSnoozeFlags(
          client,
          row: row,
          uid: uid,
          mailboxPath: mailboxPath,
        );
    }
  }

  /// Removes every `snz:` snooze keyword from the message at [seq] in the
  /// selected mailbox, so a later sync does not read the snooze back.
  /// Returns false when no message exists at [seq] (a stale UID).
  Future<bool> _removeImapSnoozeFlags(
    imap.ImapClient client,
    imap.MessageSequence seq,
  ) async {
    final fetch = await client.uidFetchMessages(seq, 'FLAGS');
    if (fetch.messages.isEmpty) return false;
    final flags = fetch.messages.first.flags ?? [];
    final snzFlags = flags.where((f) => f.startsWith('snz:')).toList();
    if (snzFlags.isEmpty) return true;
    await client.uidStore(seq, snzFlags, action: imap.StoreAction.remove);
    return true;
  }

  /// IMAP `clear_snooze`: strips the `snz:` flags at the queued UID or, when
  /// that UID went stale, at the message re-found by Message-ID. Logs a
  /// warning when it cannot be found at all; the change is not retried since
  /// a missing message has no keyword to keep reading back.
  Future<void> _clearImapSnoozeFlags(
    imap.ImapClient client, {
    required PendingChangeRow row,
    required int uid,
    required String mailboxPath,
  }) async {
    if (await _removeImapSnoozeFlags(
      client,
      imap.MessageSequence.fromId(uid, isUid: true),
    )) {
      return;
    }
    final local = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final found =
        await _searchUidByMessageId(client, mailboxPath, local?.messageId);
    if (found != null &&
        found != uid &&
        await _removeImapSnoozeFlags(
          client,
          imap.MessageSequence.fromId(found, isUid: true),
        )) {
      return;
    }
    unawaited(
      _appLogger?.warn(
        'email.snooze_cleanup_missed',
        'Could not clear the snooze keyword: UID $uid is gone from '
            '$mailboxPath and the message was not found by Message-ID',
        accountId: row.accountId,
        emailId: row.resourceId,
        mailboxPath: mailboxPath,
      ),
    );
  }

  /// Handles a `UID MOVE` that reported OK but whose message could not be
  /// found in [destMailboxPath] afterwards — or, with [movedNothing], that
  /// visibly moved nothing: then the source, still selected, is searched
  /// without another SELECT (#1224). Servers accept a MOVE of a UID that
  /// does not exist as a no-op, so a stale [staleUid] (e.g. Undo's reverse move
  /// queued before the original move re-keyed the row) would otherwise be
  /// dropped as "applied" while the message stays put (#1048).
  ///
  /// Re-resolves the UID in [mailboxPath] by Message-ID and moves that one,
  /// running [beforeMove] on it first (snooze flag edits ride along).
  /// Shared by `move` and `snooze`.
  /// When the message is no longer in [mailboxPath] but already sits in
  /// [destMailboxPath] (an earlier attempt moved it, but the remap missed it,
  /// e.g. a lagging search index), the move is treated as applied: [beforeMove]
  /// runs there and the row is re-keyed (#1201).
  /// Throws [_ImapMessageGoneException] when the message is in neither
  /// mailbox (deleted or moved elsewhere by another client), so the flush
  /// drops the change and logs it as already gone. Throws [StateError] when
  /// the MOVE had no effect although the message is still there, so the
  /// change is retried and the failure lands in the App Log.
  /// Without any Message-ID to verify against, keeps the old behaviour and
  /// treats the MOVE as applied.
  Future<void> _retryImapMoveByMessageId(
    imap.ImapClient client, {
    required PendingChangeRow row,
    required int staleUid,
    required String mailboxPath,
    required String destMailboxPath,
    required String? messageId,
    Future<void> Function(imap.MessageSequence seq)? beforeMove,
    bool movedNothing = false,
  }) async {
    final local = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    final mid = messageId ?? local?.messageId;
    if (mid == null || mid.isEmpty) return;

    // After a MOVE that moved nothing, the source is still selected.
    final resolvedUid = await _searchUidByMessageId(
      client,
      mailboxPath,
      mid,
      throwOnFailure: true,
      select: !movedNothing,
    );
    // True when the message already sits in the destination: then the move
    // happened (an earlier attempt, or a remap that missed it because the
    // server's index lags, e.g. Exchange), so it is finished there.
    // With [sourceEmpty] (no copy left in the source), a row sync already
    // fetched at the destination UID is this very mail and may be merged.
    Future<bool> finishedInDestination({required bool sourceEmpty}) async {
      final destUid = await _searchUidByMessageId(
        client,
        destMailboxPath,
        mid,
        throwOnFailure: true,
      );
      if (destUid == null) return false;
      await client.selectUnicodeMailboxByPath(destMailboxPath);
      await beforeMove?.call(imap.MessageSequence.fromId(destUid, isUid: true));
      await _rekeyEmailAfterImapMove(
        oldId: row.resourceId,
        destMailboxPath: destMailboxPath,
        newUid: destUid,
        mergeDuplicate: sourceEmpty,
      );
      // Possibly moved there by another client, after read/star changes of
      // ours went to the UID it had left: the flags it has there are not
      // known locally, and CONDSTORE need not report it again.
      await _makeFlagReconcileDue(row.accountId, destMailboxPath, jmap: false);
      return true;
    }

    if (resolvedUid == null) {
      if (await finishedInDestination(sourceEmpty: true)) return;
      // In neither mailbox and both searches succeeded: another client already
      // deleted or moved it. Retrying can never succeed, so the flush drops
      // the change as "already gone". A failed search throws instead (see
      // `throwOnFailure`), so it is retried rather than mistaken for "gone".
      throw _ImapMessageGoneException(
        'MOVE of UID $staleUid from $mailboxPath to $destMailboxPath had no '
        'effect: message $mid is in neither mailbox',
        inNeitherMailbox: true,
      );
    }
    if (resolvedUid == staleUid) {
      // Wording must not match [isImapMailboxNotFound], which would treat
      // the change as applied.
      throw StateError(
        'MOVE of UID $staleUid from $mailboxPath to $destMailboxPath had no '
        'effect: message $mid is still in $mailboxPath',
      );
    }
    // The destination was not checked yet after a MOVE that moved nothing:
    // if ours is there, the match in the source is another copy with the
    // same Message-ID (e.g. cross-posted list mail), not to be moved.
    if (movedNothing && await finishedInDestination(sourceEmpty: false)) {
      return;
    }
    await client.selectUnicodeMailboxByPath(mailboxPath);
    final resolvedSeq = imap.MessageSequence.fromId(resolvedUid, isUid: true);
    await beforeMove?.call(resolvedSeq);
    final result = await client.uidMove(
      resolvedSeq,
      targetMailboxPath: destMailboxPath,
    );
    final located = await _remapEmailAfterImapMove(
      client,
      oldId: row.resourceId,
      sourceUid: resolvedUid,
      destMailboxPath: destMailboxPath,
      moveResult: result,
    );
    if (located) return;
    throw StateError(
      'MOVE of UID $resolvedUid from $mailboxPath to $destMailboxPath had no '
      'effect: message $mid is missing from $destMailboxPath',
    );
  }

  /// Rewrites the local row identity after an IMAP MOVE so the cache keeps
  /// tracking the same physical message under its new (mailbox, UID).
  ///
  /// The new UID is taken from the RFC 4315 `COPYUID` response code first
  /// (every modern server advertises `UIDPLUS`). If that's missing we fall
  /// back to `UID SEARCH HEADER Message-ID …` in the destination mailbox.
  /// When neither yields a UID we leave the row in place; the next sync
  /// cycle will re-fetch it as a new message and reconciliation will drop
  /// the stale source-side row.
  ///
  /// Returns false only when the moved message could not be located in
  /// [destMailboxPath]; true when it was (or there is no local row to remap).
  Future<bool> _remapEmailAfterImapMove(
    imap.ImapClient client, {
    required String oldId,
    required int sourceUid,
    required String destMailboxPath,
    required imap.GenericImapResult moveResult,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(oldId)))
        .getSingleOrNull();
    if (row == null) {
      // Deleted for good meanwhile: its queued delete still needs the UID.
      final newUid = _resolveCopyUid(moveResult, sourceUid) ??
          await _uniqueUidOfQueued(client, oldId, destMailboxPath);
      if (newUid != null) {
        await _repointQueuedChanges(
          oldId: oldId,
          destMailboxPath: destMailboxPath,
          newUid: newUid,
        );
      }
      return true;
    }

    final newUid = _resolveCopyUid(moveResult, sourceUid) ??
        await _searchUidByMessageId(
          client,
          destMailboxPath,
          row.messageId,
        );
    if (newUid == null) {
      log(
        '_remapEmailAfterImapMove: could not resolve new UID for $oldId '
        'after move to $destMailboxPath (no COPYUID, '
        'messageId=${row.messageId}); row will be re-fetched on next sync',
      );
      return false;
    }

    await _rekeyEmailAfterImapMove(
      oldId: oldId,
      destMailboxPath: destMailboxPath,
      newUid: newUid,
    );
    return true;
  }

  /// Re-keys the local row [oldId] to [newUid] in [destMailboxPath] after an
  /// IMAP MOVE and rebuilds the thread aggregates in both mailboxes.
  /// No-op when the row is gone or already carries that identity.
  Future<void> _rekeyEmailAfterImapMove({
    required String oldId,
    required String destMailboxPath,
    required int newUid,
    bool mergeDuplicate = true,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(oldId)))
        .getSingleOrNull();
    if (row == null) {
      await _repointQueuedChanges(
        oldId: oldId,
        destMailboxPath: destMailboxPath,
        newUid: newUid,
      );
      return;
    }
    final newId = '${row.accountId}:$destMailboxPath:$newUid';
    if (newId == oldId) return;

    await _rekeyEmailRow(
      oldId: oldId,
      newId: newId,
      newUid: newUid,
      newMailboxPath: destMailboxPath,
      keepShownWhileMovedOn: true,
      mergeDuplicate: mergeDuplicate,
    );

    // Rebuild thread aggregates in both mailboxes from the now-updated emails.
    final threadId = row.threadId ?? newId;
    await _updateThread(row.accountId, row.mailboxPath, threadId);
    await _updateThread(row.accountId, destMailboxPath, threadId);
  }

  /// Points the changes still queued for [oldId], whose local row is gone
  /// (deleted for good while its move was queued), at the mail's [newUid] in
  /// [destMailboxPath], as [_rekeyEmailRow] does for a row that still
  /// exists. Otherwise a queued delete for good would expunge whatever
  /// mail has the pre-move UID there (#1266).
  Future<void> _repointQueuedChanges({
    required String oldId,
    required String destMailboxPath,
    required int newUid,
  }) async {
    final queued = await (_db.select(_db.pendingChanges)
          ..where((t) => t.resourceId.equals(oldId))
          ..limit(1))
        .getSingleOrNull();
    if (queued == null) return;
    final newId = '${queued.accountId}:$destMailboxPath:$newUid';
    await _db.transaction(() async {
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldId)))
          .write(PendingChangesCompanion(resourceId: Value(newId)));
      await _rewritePendingChangeUids(
        resourceId: newId,
        mailboxPath: destMailboxPath,
        newUid: newUid,
      );
      // Undo of the delete for good cancels its queued change by id.
      await _db.customStatement(
        'UPDATE undo_actions SET data_json = '
        'REPLACE(data_json, ?1, ?2) '
        'WHERE data_json LIKE ?3',
        ['"$oldId"', '"$newId"', '%"$oldId"%'],
      );
      await _db.customStatement(
        'UPDATE app_logs SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );
    });
  }

  /// The UID in [destMailboxPath] of the mail whose local row [oldId] is
  /// gone, found by the Message-ID stamped on its queued changes, when
  /// exactly one message matches; null otherwise, or when nothing besides
  /// the move itself is queued for it. A wrong guess here would point a
  /// queued delete for good at another copy, so an ambiguous match leaves
  /// the changes marked ([_uidAfterUnansweredMove] then fails them).
  Future<int?> _uniqueUidOfQueued(
    imap.ImapClient client,
    String oldId,
    String destMailboxPath,
  ) async {
    final queued = await (_db.select(_db.pendingChanges)
          ..where((t) => t.resourceId.equals(oldId)))
        .get();
    if (queued.length < 2) return null;
    String? messageId;
    for (final change in queued) {
      if (_decodePayload(change)?['messageId'] case final String id) {
        messageId = id;
        break;
      }
    }
    final uids = await _searchUidsByMessageId(
      client,
      destMailboxPath,
      messageId,
    );
    return uids.length == 1 ? uids.single : null;
  }

  /// True when a `UID MOVE` probably moved nothing: the server supports
  /// UIDPLUS, which should answer a MOVE with `COPYUID` (RFC 6851 §4.3), and
  /// this one did not — most likely the UID no longer exists in the source.
  /// Only a hint: the callers still look in the destination before giving
  /// up or moving another copy. Without UIDPLUS the missing code says
  /// nothing.
  bool _imapMoveMovedNothing(
    imap.ImapClient client,
    imap.GenericImapResult result,
  ) {
    if (!client.serverInfo.supportsUidPlus) return false;
    try {
      return result.responseCodeCopyUid == null;
    } catch (_) {
      // A malformed COPYUID still means something was moved.
      return false;
    }
  }

  /// Extracts the destination UID for [sourceUid] from a MOVE/COPY result's
  /// `COPYUID` response code (RFC 4315). Returns null when the server did not
  /// advertise UIDPLUS or the response code is malformed.
  int? _resolveCopyUid(imap.GenericImapResult result, int sourceUid) {
    final code = result.responseCodeCopyUid;
    if (code == null) return null;
    try {
      final sources = code.originalSequence?.toList();
      final targets = code.targetSequence.toList();
      if (sources == null) {
        // Some servers omit the source set when only one message moved.
        return targets.length == 1 ? targets.first : null;
      }
      final idx = sources.indexOf(sourceUid);
      if (idx < 0 || idx >= targets.length) return null;
      return targets[idx];
    } catch (_) {
      return null;
    }
  }

  /// Looks up the UID of a message in [mailboxPath] by its RFC 2822
  /// `Message-ID` header. Used as a fallback when the server doesn't
  /// support UIDPLUS so we can still relink the local row after a move.
  /// Returns null when nothing matches. Rethrows when the connection is lost
  /// ([isImapConnectionLost]). Any other failure returns null too, unless
  /// [throwOnFailure] is set: then it throws a [StateError] so a caller that
  /// treats "no match" as "the message is gone" can tell the two apart.
  Future<int?> _searchUidByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId, {
    bool throwOnFailure = false,
    bool select = true,
  }) async {
    final uids = await _searchUidsByMessageId(
      client,
      mailboxPath,
      messageId,
      throwOnFailure: throwOnFailure,
      select: select,
    );
    if (uids.isEmpty) return null;
    return uids.reduce((a, b) => a > b ? a : b);
  }

  /// Every UID in [mailboxPath] whose Message-ID header is [messageId]; empty
  /// when none matches, or when the search fails and [throwOnFailure] is
  /// false.
  Future<List<int>> _searchUidsByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId, {
    bool throwOnFailure = false,
    bool select = true,
  }) async {
    if (messageId == null || messageId.isEmpty) return const [];
    try {
      if (select) await client.selectUnicodeMailboxByPath(mailboxPath);
      // Some servers (e.g. Exchange) only match the exact header token, so a
      // bare id is retried in its angle-bracketed form (and vice versa).
      final bare = messageId.startsWith('<') && messageId.endsWith('>')
          ? messageId.substring(1, messageId.length - 1)
          : messageId;
      for (final candidate in {messageId, bare, '<$bare>'}) {
        // RFC 3501 SEARCH HEADER uses an astring for the value; quoting is
        // safe for typical Message-ID syntax (no embedded quotes or
        // backslashes).
        final escaped =
            candidate.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
        final result = await client.uidSearchMessages(
          searchCriteria: 'HEADER Message-ID "$escaped"',
        );
        final uids = result.matchingSequence?.toList() ?? const <int>[];
        if (uids.isEmpty) continue;
        return uids;
      }
      return const [];
    } catch (e) {
      // A dead connection is not "no match": let it reach the caller so a
      // batch (e.g. the pending-change flush) stops instead of carrying on.
      if (isImapConnectionLost(e)) rethrow;
      log('_searchUidsByMessageId failed for $messageId in $mailboxPath: $e');
      if (!throwOnFailure) return const [];
      // Wording must not match [isImapMailboxNotFound], which would treat
      // the change as applied.
      throw StateError('Message-ID search in $mailboxPath failed: $e');
    }
  }

  /// The JMAP id of [accountId]'s Snoozed mailbox, or null when neither the
  /// local cache nor the server has one and [create] is false. With [create]
  /// a missing mailbox is made on the server — the case on every fresh JMAP
  /// account. A snooze queued while the folder was unknown targets
  /// [_snoozedPlaceholder]; resolving it here, at flush time, keeps snoozing
  /// usable offline. Whenever an id is found, every row still parked under
  /// the placeholder is moved onto it, so the list, [isSnoozedMailbox] and the
  /// wake-up all see one Snoozed folder.
  ///
  /// The `snoozed` role is not in the IANA registry and servers such as
  /// Stalwart reject it (`invalidProperties`), so creation retries without a
  /// role; the folder is then found by name, as [_snoozedMailboxPath] does.
  ///
  /// Throws when creation fails, so the change stays queued and is retried
  /// (up to [_maxChangeAttempts]) rather than dropped as a per-email reject.
  Future<String?> _resolveJmapSnoozedMailbox(
    JmapClient jmap,
    String accountId, {
    required bool create,
  }) async {
    final known = await _snoozedMailboxPath(accountId);
    if (known != _snoozedPlaceholder) {
      await _repointSnoozedPlaceholder(accountId, known);
      return known;
    }

    final getResponses = await jmap.call([
      [
        'Mailbox/get',
        {
          'accountId': jmap.accountId,
          'properties': ['name', 'role', 'parentId'],
        },
        '0',
      ],
    ]);
    final list =
        (_responseArgs(getResponses, 0, 'Mailbox/get')['list'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    final existing = list.where((m) => m['role'] == 'snoozed').firstOrNull ??
        list
            .where(
              (m) => m['name'] == _snoozedPlaceholder && m['parentId'] == null,
            )
            .firstOrNull;
    var id = existing?['id'] as String?;
    var role = existing?['role'] as String?;

    if (id == null) {
      if (!create) return null;
      for (final withRole in const [true, false]) {
        final setResponses = await jmap.call([
          [
            'Mailbox/set',
            {
              'accountId': jmap.accountId,
              'create': {
                'snoozed': {
                  'name': _snoozedPlaceholder,
                  if (withRole) 'role': 'snoozed',
                },
              },
            },
            '0',
          ],
        ]);
        final result = _responseArgs(setResponses, 0, 'Mailbox/set');
        final created = (result['created'] as Map<String, dynamic>?)?['snoozed']
            as Map<String, dynamic>?;
        id = created?['id'] as String?;
        if (id != null) {
          role = withRole ? 'snoozed' : null;
          break;
        }
      }
    }
    if (id == null) {
      // Not a per-email rejection: keep the snooze queued and retry later.
      throw StateError('Could not create the Snoozed mailbox on the server');
    }

    await _repointSnoozedPlaceholder(
      accountId,
      id,
      mailbox: MailboxesCompanion.insert(
        id: '$accountId:$id',
        accountId: accountId,
        path: id,
        name: _snoozedPlaceholder,
        role: Value(role),
        displayPath: const Value(_snoozedPlaceholder),
      ),
    );
    return id;
  }

  /// Records [mailbox] (when given) and moves every email and thread row of
  /// [accountId] still under [_snoozedPlaceholder] onto [snoozedId], in one
  /// transaction. Threads are rebuilt rather than renamed: the same thread
  /// can already have a row under [snoozedId], and the key would collide.
  Future<void> _repointSnoozedPlaceholder(
    String accountId,
    String snoozedId, {
    MailboxesCompanion? mailbox,
  }) =>
      _db.transaction(() async {
        if (mailbox != null) {
          await _db.into(_db.mailboxes).insertOnConflictUpdate(mailbox);
        }
        await (_db.update(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(_snoozedPlaceholder),
              ))
            .write(EmailsCompanion(mailboxPath: Value(snoozedId)));
        await (_db.update(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.snoozedFromMailboxPath.equals(_snoozedPlaceholder),
              ))
            .write(EmailsCompanion(snoozedFromMailboxPath: Value(snoozedId)));
        final placeholderThreads = _db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(_snoozedPlaceholder),
          );
        final threadIds =
            (await placeholderThreads.get()).map((t) => t.id).toSet();
        if (threadIds.isEmpty) return;
        await (_db.delete(_db.threads)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(_snoozedPlaceholder),
              ))
            .go();
        for (final threadId in threadIds) {
          await _updateThread(accountId, snoozedId, threadId);
        }
      });

  /// `Email/set` patch entries (`keywords/snz:…: null`) that remove every
  /// snooze keyword [jmapEmailId] currently carries on the server.
  Future<Map<String, dynamic>> _jmapSnoozeKeywordRemovals(
    JmapClient jmap,
    String jmapEmailId,
  ) async {
    final getResponses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapEmailId],
          'properties': ['keywords'],
        },
        '0',
      ],
    ]);
    final getResult = _responseArgs(getResponses, 0, 'Email/get');
    final email = (getResult['list'] as List).firstOrNull as Map?;
    final keywords = (email?['keywords'] as Map?) ?? {};
    return {
      for (final k in keywords.keys)
        if (k.toString().startsWith('snz:')) 'keywords/$k': null,
    };
  }

  /// Applies a single pending change to the JMAP server.
  ///
  /// The `Email/set` calls intentionally omit `ifInState`: each is a targeted
  /// patch to one email's own `mailboxIds`/`keywords`, safe to apply without an
  /// optimistic-concurrency precondition, so a routine move never fails with
  /// `stateMismatch` because the account state moved on (issue #746). The
  /// caller does not advance the local checkpoint from the result — the next
  /// `Email/changes` sync reconciles this mutation with any concurrent changes.
  ///
  /// Throws [JmapSetItemException] on a permanent per-item rejection
  /// (`notUpdated`/`notDestroyed`), or [JmapException] on any other error.
  Future<void> _applyPendingChangeJmap(
    JmapClient jmap,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // Extract the JMAP email ID from the DB id (format: "accountId:jmapId").
    final jmapEmailId = row.resourceId.contains(':')
        ? row.resourceId.substring(row.resourceId.indexOf(':') + 1)
        : row.resourceId;

    Map<String, dynamic> setArgs(Map<String, dynamic> extra) => {
          'accountId': jmap.accountId,
          ...extra,
        };

    List<dynamic> responses;
    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$seen': seen},
              },
            }),
            '0',
          ],
        ]);

      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$flagged': flagged},
              },
            }),
            '0',
          ],
        ]);

      case 'add_keywords':
        final update = <String, dynamic>{
          for (final k in (payload['keywords'] as List<dynamic>).cast<String>())
            'keywords/${_imapFlagToJmapKeyword(k)}': true,
        };
        if (update.isEmpty) return;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      case 'move':
        final destMailboxId = payload['dest'] as String;
        final moveUpdate = <String, dynamic>{
          'mailboxIds': {destMailboxId: true},
          if (payload['clearSnooze'] == true)
            ...await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId),
        };
        // Set `mailboxIds` outright rather than patching `dest: true` plus
        // `src: null`. `src` is the folder the row sat in when the move was
        // queued; by flush time the server can hold the message elsewhere
        // (another client moved it, or an earlier queued move of ours landed
        // first). Dropping only the stale `src` then leaves it filed in two
        // folders at once, which the single-folder local model cannot
        // represent, so the mail sticks in a folder the local cache never
        // shows and the account diverges permanently (#910). A replacement is
        // also what a move means here: the mail is now in the destination and
        // nowhere else.
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: moveUpdate},
            }),
            '0',
          ],
        ]);

      case 'delete':
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'destroy': [jmapEmailId],
            }),
            '0',
          ],
        ]);

      case 'snooze':
        final until = payload['until'] as String;
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        var destMailboxId = payload['dest'] as String;
        var srcMailboxId = payload['src'] as String;
        // When the Snoozed folder didn't exist at enqueue time, 'dest' holds
        // the literal name 'Snoozed' rather than a JMAP mailbox ID — and so
        // does 'src' for a re-snooze of a mail parked under that placeholder.
        if (destMailboxId == _snoozedPlaceholder) {
          destMailboxId = (await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: true,
          ))!;
        }
        if (srcMailboxId == _snoozedPlaceholder) {
          srcMailboxId = (await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: true,
          ))!;
        }
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  'keywords/$keyword': true,
                  // A re-snooze from the Snoozed folder only re-tags: patching
                  // the same id to true and null is a conflicting update.
                  if (srcMailboxId != destMailboxId) ...{
                    'mailboxIds/$destMailboxId': true,
                    'mailboxIds/$srcMailboxId': null,
                  },
                },
              },
            }),
            '0',
          ],
        ]);

      case 'unsnooze':
        final destMailboxId = payload['dest'] as String;
        String? srcMailboxId = payload['src'] as String;
        // An unsnooze queued before its snooze reached the server still names
        // the placeholder. Look the folder up, but never create one just to
        // leave it: with no Snoozed mailbox the mail cannot be in it.
        if (srcMailboxId == _snoozedPlaceholder) {
          srcMailboxId = await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: false,
          );
        }
        final update = <String, dynamic>{
          'mailboxIds/$destMailboxId': true,
          if (srcMailboxId != null && srcMailboxId != destMailboxId)
            'mailboxIds/$srcMailboxId': null,
          ...await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId),
        };

        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      case 'clear_snooze':
        final removals = await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId);
        if (removals.isEmpty) return;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: removals},
            }),
            '0',
          ],
        ]);

      default:
        return;
    }

    final result = _responseArgs(responses, 0, 'Email/set');

    // Check for per-item rejection (notUpdated / notDestroyed).
    final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
    if (notUpdated != null && notUpdated.containsKey(jmapEmailId)) {
      final err = notUpdated[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }
    final notDestroyed = result['notDestroyed'] as Map<String, dynamic>?;
    if (notDestroyed != null && notDestroyed.containsKey(jmapEmailId)) {
      final err = notDestroyed[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }
  }

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        // Direct (non-queued) send: nothing waited in the outbox, so timing is
        // collected only to satisfy the phase instrumentation and discarded.
        await _sendEmailImap(
          account,
          password,
          draft,
          SendTiming(queuedFor: Duration.zero),
        );
      case account_model.AccountType.jmap:
        await _sendEmailJmap(account, password, draft);
    }
  }

  @override
  Future<int> enqueueSend(String accountId, model.EmailDraft draft) async {
    // Stamp a deterministic Message-ID so a self-send's local inbox note and
    // the real message that arrives later share the same id (#545). enough_mail
    // would otherwise generate a random one at send time.
    final host = draft.from.email.contains('@')
        ? draft.from.email.split('@').last
        : 'localhost';
    final stampedDraft = draft.messageId != null
        ? draft
        : draft.copyWith(messageId: imap.MessageBuilder.createMessageId(host));
    // The self-send inbox note (#545) is NOT created here: until SMTP accepts
    // the message it may still be rejected (unknown recipient, 5xx) or be
    // discarded from the Sent Queue, and a note in the inbox would then look
    // like mail that arrived although nothing was delivered. It is created by
    // the outbox sender once the send has succeeded (see [_flushOutbox]).
    return _outbox.enqueue(accountId, stampedDraft);
  }

  /// Marker inserted into a local (virtual) email row's `id` so it never
  /// collides with a real server row id (`accountId:mailboxPath:uid` for IMAP
  /// or `accountId:jmapId` for JMAP).
  static const _localIdMarker = '__local__';

  /// Marker for the virtual Sent-folder copy of a message we just sent (#918).
  /// Kept distinct from [_localIdMarker] because a mail sent to yourself
  /// produces both rows — the inbox note and the Sent copy — and they must not
  /// share an id, nor dissolve against each other's arrival.
  static const _localSentIdMarker = '__local_sent__';

  /// Whether [id] belongs to a virtual Sent-folder copy ([_localSentIdMarker])
  /// rather than a self-send inbox note ([_localIdMarker]).
  static bool _isLocalSentCopyId(String id) =>
      id.contains(':$_localSentIdMarker:');

  /// Mirrors a message we just sent into the local `emails` table so it shows
  /// up in Sent immediately, instead of only once the background sync next
  /// visits that folder (#918).
  ///
  /// With a [uid] (IMAP UIDPLUS `APPENDUID`) or a [jmapId] the row carries the
  /// very id a sync of [mailboxPath] would give it, so that sync updates this
  /// row in place rather than inserting a duplicate. With neither, the row is
  /// inserted as a virtual `isLocal` one that [_maybeDissolveLocalMessage]
  /// folds into the real message later — the same machinery self-send notes
  /// use (#545) — which needs a [messageId] to match on, so a message without
  /// one is skipped rather than left as a permanent duplicate.
  Future<void> _storeSentCopyLocally({
    required String accountId,
    required String mailboxPath,
    required model.EmailDraft draft,
    required String? messageId,
    int? uid,
    String? jmapId,
  }) async {
    final mid = normaliseMessageId(messageId);
    // Prefer the server's own id for the copy, so the next sync of this folder
    // updates this row instead of adding a second one.
    final serverId = uid != null
        ? '$accountId:$mailboxPath:$uid'
        : (jmapId != null ? '$accountId:$jmapId' : null);
    if (serverId == null && mid == null) return;
    final emailId = serverId ?? '$accountId:$_localSentIdMarker:$mid';
    final isLocal = serverId == null;

    final now = DateTime.now();
    final threadId =
        _computeThreadId(messageId: mid, inReplyTo: null, references: null) ??
            emailId;
    final body = draft.body;
    final preview = body.length > 200 ? body.substring(0, 200) : body;

    await _db.into(_db.emails).insertOnConflictUpdate(
          EmailsCompanion.insert(
            id: emailId,
            accountId: accountId,
            mailboxPath: mailboxPath,
            uid: uid ?? 0,
            subject: Value(draft.subject),
            sentAt: Value(now),
            receivedAt: now,
            fromJson: Value(_encodeModelAddresses([draft.from])),
            toAddresses: Value(_encodeModelAddresses(draft.to)),
            ccJson: Value(_encodeModelAddresses(draft.cc)),
            bccJson: Value(_encodeModelAddresses(draft.bcc)),
            preview: Value(preview),
            // You wrote it — mirrors the \Seen flag the APPEND sets, and never
            // nags with an unread badge on your own mail.
            isSeen: const Value(true),
            isFlagged: const Value(false),
            hasAttachment: Value(draft.attachmentFilePaths.isNotEmpty),
            threadId: Value(threadId),
            messageId: Value(mid),
            isLocal: Value(isLocal),
          ),
        );
    await _db.into(_db.emailBodies).insertOnConflictUpdate(
          EmailBodiesCompanion.insert(
            emailId: emailId,
            textBody: Value(body),
            cachedAt: Value(now),
            bodySize: Value(_bodySize(body, null)),
          ),
        );
    await _updateThread(accountId, mailboxPath, threadId);
  }

  /// For every configured account whose address is among [draft]'s recipients,
  /// insert a local "virtual" copy of the message into that account's inbox so
  /// it shows up right after sending for note-taking (#545), instead of only
  /// once the next sync of the inbox fetches it. Dissolved into the real
  /// message by [_maybeDissolveLocalMessage] once it arrives via sync.
  ///
  /// Only call this after the server accepted the message: a note for a mail
  /// that was rejected or discarded would be a phantom inbox message.
  Future<void> _createLocalSelfMessages(model.EmailDraft draft) async {
    final mid = normaliseMessageId(draft.messageId);
    if (mid == null) return;
    final recipients = <String>{
      for (final a in draft.to) a.email.toLowerCase().trim(),
      for (final a in draft.cc) a.email.toLowerCase().trim(),
      for (final a in draft.bcc) a.email.toLowerCase().trim(),
    };
    if (recipients.isEmpty) return;

    final accounts = await _accounts.observeAccounts().first;
    for (final account in accounts) {
      if (account.email.isEmpty) continue;
      if (!recipients.contains(account.email.toLowerCase().trim())) continue;

      // The inbox is where a mail-to-self lands; the local copy mirrors it.
      final inbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(account.id) & t.role.equals('inbox'),
            )
            ..limit(1))
          .getSingleOrNull();
      if (inbox == null) continue;

      final now = DateTime.now();
      final emailId = '${account.id}:$_localIdMarker:$mid';
      final threadId =
          _computeThreadId(messageId: mid, inReplyTo: null, references: null) ??
              emailId;
      final body = draft.body;
      final preview = body.length > 200 ? body.substring(0, 200) : body;

      // One transaction: the arrival check and the insert must not interleave
      // with a sync storing the real message, and a note must never be left
      // half-written (row without body or thread aggregate).
      await _db.transaction(() async {
        // A fast server can deliver the real message, and a sync can store
        // it, before we get here. Its arrival found no note to dissolve, so a
        // note inserted now would stay behind as a permanent duplicate.
        if (await _hasArrivedOutsideSent(account.id, mid)) return;

        // insertOrIgnore: a second successful send of the same draft (or a
        // replay) must not reset the star / read state / folder the user has
        // already set on the note.
        await _db.into(_db.emails).insert(
              EmailsCompanion.insert(
                id: emailId,
                accountId: account.id,
                mailboxPath: inbox.path,
                uid: 0,
                subject: Value(draft.subject),
                sentAt: Value(now),
                receivedAt: now,
                fromJson: Value(_encodeModelAddresses([draft.from])),
                toAddresses: Value(_encodeModelAddresses(draft.to)),
                ccJson: Value(_encodeModelAddresses(draft.cc)),
                preview: Value(preview),
                // Self-sent: you wrote it, so don't nag with an unread badge.
                isSeen: const Value(true),
                isFlagged: const Value(false),
                hasAttachment: Value(draft.attachmentFilePaths.isNotEmpty),
                threadId: Value(threadId),
                messageId: Value(mid),
                isLocal: const Value(true),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await _db.into(_db.emailBodies).insert(
              EmailBodiesCompanion.insert(
                emailId: emailId,
                textBody: Value(body),
                cachedAt: Value(now),
                bodySize: Value(_bodySize(body, null)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        await _updateThread(account.id, inbox.path, threadId);
      });
    }
  }

  /// Whether the real (synced, non-local) message with Message-ID [mid] is
  /// already stored on [accountId] in any folder but Sent. Mirrors which
  /// arrivals [_maybeDissolveLocalMessage] dissolves an inbox note against: a
  /// Sent-folder row is the copy of what we sent, not the delivered message,
  /// and a server rule may have filed the delivery somewhere other than INBOX.
  ///
  /// Only folders the mailbox list knows count: a sync only ever stores
  /// messages of such a folder, whereas the Sent copy we just appended may sit
  /// in a folder not synced yet (e.g. a freshly created "Sent"), whose missing
  /// role must not pass it off as the delivered message.
  Future<bool> _hasArrivedOutsideSent(String accountId, String mid) async {
    final rows = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.mailboxPath])
          ..where(
            _db.emails.accountId.equals(accountId) &
                _db.emails.isLocal.equals(false) &
                (_db.emails.messageId.equals(mid) |
                    _db.emails.messageId.equals('<$mid>')),
          ))
        .get();
    for (final row in rows) {
      final mailbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) =>
                  t.accountId.equals(accountId) &
                  t.path.equals(row.read(_db.emails.mailboxPath)!),
            )
            ..limit(1))
          .getSingleOrNull();
      if (mailbox != null && mailbox.role != 'sent') return true;
    }
    return false;
  }

  String _encodeModelAddresses(List<model.EmailAddress> addresses) =>
      jsonEncode(
        addresses.map((a) => {'name': a.name, 'email': a.email}).toList(),
      );

  @override
  Future<int> flushOutbox(String accountId, String password) =>
      _flushOutbox(accountId, password);

  /// Shared flush machinery for [flushOutbox] (background sync loop) and
  /// [sendNow] (UI-initiated). [extraObserver], when supplied, is notified of
  /// every row outcome alongside the app-log observer, letting a caller capture
  /// the fate of a specific row without duplicating the sender/timing wiring.
  /// [warnings], when supplied, receives a row's [_sendEmailJmap] warning
  /// (keyed by row id) before its `onOk` fires.
  Future<int> _flushOutbox(
    String accountId,
    String password, {
    OutboxFlushObserver? extraObserver,
    Map<int, String>? warnings,
  }) async {
    final account = (await _accounts.getAccount(accountId))!;
    // Per-row timing breakdowns, keyed by outbox row id, so the log observer
    // can report *why* each send took as long as it did (#801). Scoped to this
    // flush call rather than an instance field so concurrent per-account
    // flushes never clobber each other's numbers.
    final timings = <int, SendTiming>{};
    return _outbox.flush(
      accountId,
      (job) async {
        // Re-validate any attachment file paths before touching the network so
        // an obviously-broken queue entry is failed-out fast.
        for (final filePath in job.draft.attachmentFilePaths) {
          if (!await File(filePath).exists()) {
            throw PermanentSendException(
              'Attachment file no longer exists: $filePath',
            );
          }
        }
        final timing = SendTiming(
          queuedFor: DateTime.now().difference(job.createdAt),
        );
        timings[job.id] = timing;
        final stopwatch = Stopwatch()..start();
        try {
          switch (account.type) {
            case account_model.AccountType.imap:
              await _sendEmailImap(account, password, job.draft, timing);
            case account_model.AccountType.jmap:
              final warning =
                  await _sendEmailJmap(account, password, job.draft);
              if (warning != null) warnings?[job.id] = warning;
          }
          // Accepted by the server: only now may a mail to one of our own
          // accounts show up in that inbox (#545). Best-effort, like the Sent
          // copy — rethrowing would re-send an already-sent message.
          try {
            await _createLocalSelfMessages(job.draft);
          } catch (e, stack) {
            unawaited(
              _appLogger?.warn(
                'outbox.send.self_note_failed',
                'Message sent, but adding the local inbox copy failed: $e',
                accountId: accountId,
                error: e,
                stack: stack,
              ),
            );
          }
        } on SmtpRecipientsRejectedException catch (e) {
          // Nothing was sent. A permanently refused address fails the
          // row so the user can fix it via Edit; an all-4xx refusal retries.
          if (e.isPermanent) throw PermanentSendException(e.toString());
          rethrow;
        } on imap.SmtpException catch (e) {
          // Permanent SMTP rejections come back as 5xx response codes — those
          // will fail the same way on every retry, so fail the row out.
          if (_isPermanentSmtpError(e)) {
            throw PermanentSendException('SMTP rejected: ${e.message}');
          }
          rethrow;
        } on JmapException catch (e) {
          // EmailSubmission errors that won't recover on retry (invalid
          // recipient, forbidden identity, missing mailbox).
          if (_isPermanentJmapError(e)) {
            throw PermanentSendException('JMAP rejected: ${e.message}');
          }
          rethrow;
        } finally {
          timing.total = stopwatch.elapsed;
        }
      },
      observer: _combineObservers(
        extraObserver,
        _outboxLogObserver(accountId, timings),
      ),
    );
  }

  @override
  Future<SendNowResult> sendNow(String accountId, {int? outboxRowId}) async {
    final password = await _accounts.getPassword(accountId);
    // Capture the target row's outcome as the guarded flush processes it, so we
    // can report the concrete result to the user (#755). Runs alongside the
    // app-log observer via [_combineObservers].
    SendNowResult? captured;
    final warnings = <int, String>{};
    final observer = outboxRowId == null
        ? null
        : OutboxFlushObserver(
            onOk: (job) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.sent,
                  warning: warnings[job.id],
                );
              }
            },
            onTransient: (job, error, stack, nextAttemptAt) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.transientFailed,
                  message: error.toString(),
                );
              }
            },
            onPermanent: (job, error) {
              if (job.id == outboxRowId) {
                captured = SendNowResult(
                  SendNowOutcome.permanentlyFailed,
                  message: error.message,
                );
              }
            },
          );
    final sentCount = await _flushOutbox(
      accountId,
      password,
      extraObserver: observer,
      warnings: warnings,
    );
    if (captured != null) return captured!;
    if (outboxRowId == null) {
      // No row targeted, so report what the flush actually did, per the
      // interface contract ("otherwise it reports whether anything was sent").
      // Claiming `sent` unconditionally would report delivery even when the
      // queue was empty or every row failed.
      return SendNowResult(
        sentCount > 0 ? SendNowOutcome.sent : SendNowOutcome.queued,
      );
    }
    // The row was not processed by this flush — either a concurrent flush had
    // already sent it (the per-account lock serialises the two, so it was gone
    // by the time we ran) or it is not eligible yet. Derive the outcome from
    // its current persisted state.
    final row = await (_db.select(_db.outbox)
          ..where((t) => t.id.equals(outboxRowId))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      // Gone from the queue. Usually that means a concurrent flush delivered it,
      // and reporting `sent` is right. It is NOT proof of delivery though: the
      // Discard action stays enabled while a retry is in flight, so a user who
      // discards mid-send also lands here. Distinguishing the two needs a
      // durable per-row terminal state, which is the dedup follow-up's job.
      return const SendNowResult(SendNowOutcome.sent);
    }
    if (row.status == 'failed') {
      return SendNowResult(
        SendNowOutcome.permanentlyFailed,
        message: row.lastError,
      );
    }
    return SendNowResult(SendNowOutcome.queued, message: row.lastError);
  }

  /// Fans a single flush's row-outcome callbacks out to two observers. Each
  /// side is best-effort — the outbox's own `_safeNotify` already guards the
  /// combined callback — and [first] runs before [second] so a capturing
  /// observer records its result even if the log observer later throws.
  OutboxFlushObserver? _combineObservers(
    OutboxFlushObserver? first,
    OutboxFlushObserver? second,
  ) {
    if (first == null) return second;
    if (second == null) return first;
    return OutboxFlushObserver(
      onAttempt: (job) {
        first.onAttempt?.call(job);
        second.onAttempt?.call(job);
      },
      onOk: (job) {
        first.onOk?.call(job);
        second.onOk?.call(job);
      },
      onTransient: (job, error, stack, nextAttemptAt) {
        first.onTransient?.call(job, error, stack, nextAttemptAt);
        second.onTransient?.call(job, error, stack, nextAttemptAt);
      },
      onPermanent: (job, error) {
        first.onPermanent?.call(job, error);
        second.onPermanent?.call(job, error);
      },
    );
  }

  // Mirrors every outbox row outcome into the application log so a user who
  // hits Retry on a queued message actually sees why it did or did not send
  // (previously the failure was only stored in `outbox.lastError` and the
  // log stayed silent — see #323).
  OutboxFlushObserver? _outboxLogObserver(
    String accountId,
    Map<int, SendTiming> timings,
  ) {
    final logger = _appLogger;
    if (logger == null) return null;
    String describe(OutboxJob job) {
      final subject = job.draft.subject.isEmpty
          ? '(no subject)'
          : (job.draft.subject.length > 60
              ? '${job.draft.subject.substring(0, 60)}…'
              : job.draft.subject);
      final recipients = job.draft.allRecipients.length;
      return '"$subject" ($recipients recipient${recipients == 1 ? '' : 's'})';
    }

    return OutboxFlushObserver(
      onAttempt: (job) {
        unawaited(
          // `info`, not `debug`: the default app-log filter hides debug, so a
          // send in progress used to leave no visible trace at all (#501). One
          // entry per eligible row per cycle, and backoff spaces retries out,
          // so this stays quiet in steady state.
          logger.info(
            'outbox.send.attempt',
            'Sending queued message ${describe(job)} (attempt ${job.attempts + 1})',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts,
              'subject': job.draft.subject,
              'to': job.draft.to.map((a) => a.email).toList(),
            },
          ),
        );
      },
      onOk: (job) {
        // Attach the timing breakdown so a user asking "why did sending take so
        // long?" can read the answer straight off the log entry (#801): how
        // long the message waited in the queue vs. how long each network leg
        // took.
        final timing = timings.remove(job.id);
        unawaited(
          logger.info(
            'outbox.send.ok',
            'Queued message ${describe(job)} sent'
                '${timing == null ? '' : ' — ${timing.summary}'}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              if (timing != null) ...timing.toLogData(),
            },
          ),
        );
      },
      onTransient: (job, error, stack, nextAttemptAt) {
        // Report the timing even on failure — a phase that timed out is exactly
        // the slow leg the user is hunting for.
        final timing = timings.remove(job.id);
        unawaited(
          logger.warn(
            'outbox.send.transient_error',
            'Send failed for ${describe(job)}; retrying at '
                '${nextAttemptAt.toIso8601String()}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              'nextAttemptAt': nextAttemptAt.toIso8601String(),
              if (timing != null) ...timing.toLogData(),
            },
            error: error,
            stack: stack,
          ),
        );
      },
      onPermanent: (job, error) {
        final timing = timings.remove(job.id);
        unawaited(
          logger.error(
            'outbox.send.permanent_error',
            'Send permanently failed for ${describe(job)}: ${error.message}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
              if (timing != null) ...timing.toLogData(),
            },
            error: error,
          ),
        );
      },
    );
  }

  bool _isPermanentSmtpError(imap.SmtpException e) {
    final code = e.response.code ?? 0;
    return code >= 500 && code < 600;
  }

  bool _isPermanentJmapError(JmapException e) {
    final m = e.message.toLowerCase();
    return m.contains('forbidden') ||
        m.contains('invalidemail') ||
        m.contains('noidentity') ||
        m.contains('no jmap identity') ||
        m.contains('cannotsend');
  }

  Future<void> _sendEmailImap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
    SendTiming timing,
  ) async {
    final builder = imap.MessageBuilder()
      ..from = [HeaderMailAddress(draft.from.name, draft.from.email)]
      ..to = draft.to.map((a) => HeaderMailAddress(a.name, a.email)).toList()
      ..cc = draft.cc.map((a) => HeaderMailAddress(a.name, a.email)).toList()
      ..subject = encodeUnstructuredHeader(draft.subject)
      ..subjectEncoding = imap.HeaderEncoding.none
      ..messageId = draft.messageId
      ..text = draft.body;
    addReplyHeaders(builder, draft);
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final mediaType = imap.MediaType.guessFromFileName(filePath);
      await builder.addFile(file, mediaType);
    }
    // Built without Bcc, so the transmitted message cannot carry it: Bcc
    // recipients only go into the SMTP envelope (RCPT TO) below (#1126).
    // enough_mail would strip a Bcc header itself, but only its first line,
    // so a long, folded one would leak its continuation lines.
    final mimeMessage = builder.buildMimeMessage();
    final envelopeRecipients = [
      for (final a in draft.allRecipients) HeaderMailAddress(a.name, a.email),
    ];
    final smtpEndpoint = '${account.smtpHost}:${account.smtpPort}';
    final imapEndpoint = '${account.imapHost}:${account.imapPort}';
    final smtpClient = await _withPhase(
      'SMTP connect/auth',
      smtpEndpoint,
      () => _smtpConnect(
        account,
        _effectiveUsername(account),
        password,
      ).timeout(_sendOperationTimeout),
      timing: timing,
    );
    try {
      await _withPhase(
        'SMTP send message',
        smtpEndpoint,
        () => smtpClient
            .sendMessage(mimeMessage, recipients: envelopeRecipients)
            .timeout(_sendOperationTimeout),
        timing: timing,
      );
    } finally {
      // Quit is a one-liner over the wire — bound it tightly so a wedged
      // server doesn't keep the caller hanging after the message is sent.
      try {
        await smtpClient.quit().timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Best-effort: the message is already sent.
      }
    }
    // The SMTP send above is the commit point (#755): once sendMessage returns,
    // the message is on its way and must never be re-sent. Saving a copy to the
    // IMAP Sent folder is best-effort from here on — swallow and log any failure
    // rather than rethrow. If it rethrew, the outbox would treat this
    // already-sent row as a transient failure and re-send it on the next retry,
    // delivering the message twice and leaving the row lingering in the Sent
    // Queue until a later attempt finally completed the append.
    try {
      // The Sent copy is the sender's own record, so it keeps Bcc, as other
      // clients' copies do.
      if (draft.bcc.isNotEmpty) {
        mimeMessage.setHeader(
          'Bcc',
          draft.bcc
              .map((a) => HeaderMailAddress(a.name, a.email).encode())
              .join(
                ', ',
              ),
        );
      }
      final appended = await _appendSentCopy(
        account,
        password,
        mimeMessage,
        imapEndpoint,
        timing,
      );
      // UIDPLUS (RFC 4315) tells us the UID the copy got, which is all we need
      // to write the very row a later sync of that folder would write. Without
      // it we insert a virtual row instead, so Sent is never empty right after
      // sending (#918).
      final uidList =
          appended.result.responseCodeAppendUid?.targetSequence.toList();
      final appendUid =
          (uidList != null && uidList.isNotEmpty) ? uidList.first : null;
      // The draft's own id first: it is what `enqueueSend` stamped and what the
      // self-send inbox note (#545), created once this send returns, is keyed
      // on, so both rows agree. The
      // header is only a fallback for a direct send that never went through the
      // outbox, and MessageBuilder can hand it back double-bracketed (#859),
      // which `normaliseMessageId` only half-strips.
      final sentMessageId = normaliseMessageId(
        draft.messageId ?? mimeMessage.getHeaderValue('message-id'),
      );
      await _storeSentCopyLocally(
        accountId: account.id,
        mailboxPath: appended.path,
        draft: draft,
        messageId: sentMessageId,
        uid: appendUid,
      );
    } catch (e, stack) {
      final logger = _appLogger;
      if (logger != null) {
        unawaited(
          logger.warn(
            'outbox.send.sent_copy_failed',
            'Message sent, but saving a copy to the Sent folder failed: $e',
            accountId: account.id,
            error: e,
            stack: stack,
          ),
        );
      }
    }
  }

  /// Folder to APPEND the Sent copy to when the account has no `role = 'sent'`
  /// mailbox at all — a fresh account whose folder list has never synced, or a
  /// server that advertises no SPECIAL-USE flags. Only in that case do we fall
  /// back to the RFC 6154 conventional name and create it.
  static const _fallbackSentFolder = 'Sent';

  /// The mailbox the server itself designates as its Sent folder, as recorded
  /// by the mailbox sync from the SPECIAL-USE / XLIST flags. Null when the
  /// account has no sent-role mailbox.
  Future<MailboxRow?> _sentMailboxRow(String accountId) =>
      (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(accountId) & t.role.equals('sent'),
            )
            ..limit(1))
          .getSingleOrNull();

  /// Connects over IMAP and APPENDs [mimeMessage] to the Sent folder, creating
  /// the folder first when the server does not pre-create it. Extracted from
  /// [_sendEmailImap] so the caller can treat the whole Sent-copy step as one
  /// best-effort unit that never undoes an already-completed SMTP send (#755).
  ///
  /// Returns the folder the copy went into plus the server's APPEND result, so
  /// the caller can mirror it into the local DB.
  Future<({String path, imap.GenericImapResult result})> _appendSentCopy(
    account_model.Account account,
    String password,
    imap.MimeMessage mimeMessage,
    String imapEndpoint,
    SendTiming timing,
  ) async {
    // Append to the folder this server actually calls Sent. The path used to be
    // the literal 'Sent', which on every server that names it something else
    // (INBOX.Sent, Sent Items, Sent Messages, [Gmail]/Sent Mail, or anything
    // under a namespace prefix) CREATEd a second, top-level folder and filed
    // the copy there — so the Sent folder the app displays, resolved by
    // `role = 'sent'`, stayed empty (#918).
    final sentRow = await _sentMailboxRow(account.id);
    final sentPath = sentRow?.path ?? _fallbackSentFolder;
    final imapClient = await _withPhase(
      'IMAP connect/login (to append Sent copy)',
      imapEndpoint,
      () => _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      ).timeout(_sendOperationTimeout),
      timing: timing,
    );
    try {
      // Only create when we are guessing the name: a folder the server already
      // listed needs no CREATE, and issuing one just to swallow the inevitable
      // "already exists" would keep hiding real errors on every single send.
      if (sentRow == null) {
        final createStopwatch = Stopwatch()..start();
        try {
          await imapClient
              .createMailbox(sentPath)
              .timeout(_sendOperationTimeout);
        } on TimeoutException catch (e) {
          throw _wrapPhaseError(
            'IMAP create Sent folder',
            imapEndpoint,
            e,
          );
        } catch (_) {
          // Already exists — that's fine.
        } finally {
          timing.record('IMAP create Sent folder', createStopwatch.elapsed);
        }
      }
      final result = await _withPhase(
        'IMAP append to Sent folder',
        imapEndpoint,
        () => imapClient.appendMessage(
          mimeMessage,
          targetMailboxPath: sentPath,
          flags: [r'\Seen'],
          responseTimeout: _sendOperationTimeout,
        ),
        timing: timing,
      );
      return (path: sentPath, result: result);
    } finally {
      // Best-effort and bounded: the message is already appended to Sent, so
      // a lost connection or wedged server must not fail (and re-queue) the
      // send.
      await closeImapClient(imapClient);
    }
  }

  /// Runs [action] and, if it throws a [TimeoutException], rewraps the error
  /// so the message carries the phase name and endpoint. This turns opaque
  /// entries like "TimeoutException after 0:00:50.000000: null" into
  /// user-legible ones like "SMTP connect/auth timed out after 50s (host:
  /// smtp.example.com:587)" — the difference between the sent-queue row
  /// showing "nothing" and showing the actual root cause the user asked for
  /// in #323.
  Future<T> _withPhase<T>(
    String phase,
    String endpoint,
    Future<T> Function() action, {
    SendTiming? timing,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await action();
    } on TimeoutException catch (e) {
      throw _wrapPhaseError(phase, endpoint, e);
    } finally {
      // Record even on timeout/error: a phase that hung is the slow leg the
      // user is looking for (#801).
      timing?.record(phase, stopwatch.elapsed);
    }
  }

  Exception _wrapPhaseError(
    String phase,
    String endpoint,
    TimeoutException e,
  ) {
    final seconds = (e.duration ?? _sendOperationTimeout).inSeconds;
    return TimeoutException(
      '$phase timed out after ${seconds}s (host: $endpoint)',
      e.duration,
    );
  }

  /// Returns a warning for the user when the message went out but the server
  /// refused some of its recipients, otherwise null.
  Future<String?> _sendEmailJmap(
    account_model.Account account,
    String password,
    model.EmailDraft draft,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }
    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    // Upload any file attachments and collect their blobIds.
    final attachments = <Map<String, dynamic>>[];
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final contentType = imap.MediaType.guessFromFileName(filePath).text;
      final blobId = await jmap.uploadBlob(bytes, contentType);
      attachments.add({
        'blobId': blobId,
        'type': contentType,
        'name': p.basename(filePath),
        'size': bytes.length,
        'disposition': 'attachment',
      });
    }

    // Look up the Sent mailbox JMAP ID from the local DB. For JMAP accounts a
    // mailbox row's `path` *is* its JMAP id.
    final sentMailbox = await _sentMailboxRow(account.id);
    final sentJmapId = sentMailbox?.path;
    if (sentJmapId == null) {
      // Without it the create below omits `mailboxIds`, which strict servers
      // reject and lenient ones file into no folder at all — either way the
      // message never shows up in Sent (#918). Nothing we can do but say so.
      unawaited(
        _appLogger?.warn(
          'outbox.send.sent_mailbox_unknown',
          'No sent-role mailbox known for this account; the sent copy may not '
              'be filed into Sent. Sync the folder list and try again.',
          accountId: account.id,
        ),
      );
    }

    // Build the email body.
    const bodyPartId = '1';
    final emailCreate = {
      'from': [
        {'name': draft.from.name, 'email': draft.from.email},
      ],
      'to': draft.to.map((a) => {'name': a.name, 'email': a.email}).toList(),
      if (draft.cc.isNotEmpty)
        'cc': draft.cc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      // This Email is also the Sent copy, so it keeps Bcc. RFC 8621 §7.5:
      // "The server MUST remove any Bcc header field present on the message
      // during delivery." The Bcc recipients get the message through the
      // envelope's rcptTo below (#1126).
      if (draft.bcc.isNotEmpty)
        'bcc':
            draft.bcc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      'subject': draft.subject,
      // JMAP messageId is an array of bracket-less ids (RFC 8621 §4.1.2.3).
      if (draft.messageId != null)
        'messageId': [normaliseMessageId(draft.messageId)],
      // Same bracket-less array form for the reply headers (RFC 8621 §4.1.2.3).
      if (normaliseMessageId(draft.inReplyTo) case final inReplyTo?)
        'inReplyTo': [inReplyTo],
      if (normaliseDraftReferences(draft.references) case final refs
          when refs.isNotEmpty)
        'references': refs,
      'bodyValues': {
        bodyPartId: {
          'value': draft.body,
          'isEncodingProblem': false,
          'isTruncated': false,
        },
      },
      'textBody': [
        {'partId': bodyPartId, 'type': 'text/plain'},
      ],
      if (attachments.isNotEmpty) 'attachments': attachments,
      'keywords': {r'$seen': true},
      if (sentJmapId != null) 'mailboxIds': {sentJmapId: true},
    };

    // Build the recipient envelope for EmailSubmission.
    final allRecipients = [
      for (final a in draft.allRecipients) {'email': a.email},
    ];

    // Fail fast if the server can't submit mail at all, rather than issuing an
    // Identity/get that would only come back as `unknownMethod`.
    if (!jmap.supportsSubmission) {
      throw JmapException('JMAP server does not support message submission');
    }

    // Fetch identities to get the required identityId for EmailSubmission.
    // Identity/get belongs to the submission capability (RFC 8621 §6), so the
    // request must declare it via withSubmission or a strict server rejects the
    // call with `unknownMethod`.
    final identityResponses = await jmap.call(
      [
        [
          'Identity/get',
          {'accountId': jmap.accountId, 'ids': null},
          'i',
        ],
      ],
      withSubmission: true,
    );
    final identityResult = _responseArgs(identityResponses, 0, 'Identity/get');
    final identityList = identityResult['list'] as List<dynamic>?;
    if (identityList == null || identityList.isEmpty) {
      throw JmapException('No identities found for JMAP account');
    }
    // Pick the identity whose address matches the draft's From, not whatever
    // Identity/get happens to list first: a mailbox with aliases returns one
    // identity per address, and a server that enforces RFC 8621 §7.5 rejects
    // the submission with `forbiddenFrom` when the envelope mailFrom is not an
    // address the chosen identity may send from (see #564).
    final wantFrom = draft.from.email.toLowerCase();
    final identities = identityList.cast<Map<String, dynamic>>();
    final identity = identities.firstWhere(
      (i) => (i['email'] as String?)?.toLowerCase() == wantFrom,
      // Don't silently guess: an identity that can't send as the From address
      // would just fail with forbiddenFrom, so surface the mismatch instead.
      orElse: () => throw JmapException(
        'No JMAP identity matches sender ${draft.from.email}; '
        'available identities: '
        '${identities.map((i) => i['email'] ?? '?').join(', ')}',
      ),
    );
    final identityId = identity['id'] as String;
    final identityEmail = identity['email'] as String?;

    // Create the email first.
    final createResponses = await jmap.call([
      [
        'Email/set',
        {
          'accountId': jmap.accountId,
          'create': {'em1': emailCreate},
        },
        '0',
      ],
    ]);

    // Check Email/set for creation errors.
    final setResult = _responseArgs(createResponses, 0, 'Email/set');
    final notCreated = setResult['notCreated'] as Map<String, dynamic>?;
    if (notCreated != null && notCreated.containsKey('em1')) {
      final err = notCreated['em1'] as Map<String, dynamic>;
      throw JmapException('Email/set create failed: ${err['type']}');
    }

    final created = setResult['created'] as Map<String, dynamic>?;
    final createdEmail = created?['em1'] as Map<String, dynamic>?;
    final emailId = createdEmail?['id'] as String?;
    if (emailId == null || emailId.isEmpty) {
      throw JmapException('Email/set create failed: missing created email id');
    }

    // Then submit the created email. If submission fails for any reason, the
    // email was already created in the Sent mailbox above; destroy it so a
    // message that was never actually sent doesn't linger in Sent and make the
    // user think it went out.
    String? warning;
    try {
      final submissionResponses = await jmap.call(
        [
          [
            'EmailSubmission/set',
            {
              'accountId': jmap.accountId,
              'create': {
                'sub1': {
                  'emailId': emailId,
                  'identityId': identityId,
                  'envelope': {
                    'mailFrom': {'email': draft.from.email},
                    'rcptTo': allRecipients,
                  },
                },
              },
            },
            '1',
          ],
        ],
        withSubmission: true,
      );

      // Check EmailSubmission/set for submission errors.
      final subResult = _responseArgs(
        submissionResponses,
        0,
        'EmailSubmission/set',
      );
      final notSubmitted = subResult['notCreated'] as Map<String, dynamic>?;
      if (notSubmitted != null && notSubmitted.containsKey('sub1')) {
        final err = notSubmitted['sub1'] as Map<String, dynamic>;
        throw JmapException(
          'EmailSubmission/set failed: ${err['type']} '
          '${err['description'] ?? ''} '
          '${err['properties'] ?? ''} '
          '(envelope mailFrom: ${draft.from.email}, '
          'identity email: ${identityEmail ?? 'unknown'})',
        );
      }
      // A created submission is no proof of delivery: Stalwart creates it even
      // when it refused every recipient, and reports the refusals only in the
      // submission's deliveryStatus.
      final submissionId =
          ((subResult['created'] as Map<String, dynamic>?)?['sub1']
              as Map<String, dynamic>?)?['id'] as String?;
      final rejected = submissionId == null
          ? const <RejectedRecipient>[]
          : await _jmapRejectedRecipients(jmap, submissionId);
      if (rejected.isNotEmpty) {
        final description = describeRejectedRecipients(rejected);
        final refused = {for (final r in rejected) r.email.toLowerCase()};
        if (draft.allRecipients
            .every((a) => refused.contains(a.email.toLowerCase()))) {
          // Nobody gets it: fail the row (and drop the Sent copy below), so
          // the user can fix the address via Edit.
          throw PermanentSendException(description);
        }
        // The others already have it and a submission cannot be recalled, so
        // failing the row would only re-send it to them. Say who missed out,
        // to the user (via the caller) and in the app log.
        warning = 'Not delivered to ${rejected.join('; ')}';
        unawaited(
          _appLogger?.error(
            'outbox.send.recipient_rejected',
            'Message sent, but not to everyone. $description',
            accountId: account.id,
            data: {
              'rejected': [for (final r in rejected) r.email],
            },
          ),
        );
      }
    } catch (_) {
      await _destroyJmapEmail(jmap, emailId);
      rethrow;
    }

    // The message is away and the server already filed it into Sent above —
    // mirror it locally so Sent shows it now rather than after the next sync
    // of that folder (#918). Best-effort in its own right: a DB hiccup here
    // must not look like a failed send and get the message delivered twice.
    if (sentMailbox == null) return warning;
    try {
      await _storeSentCopyLocally(
        accountId: account.id,
        mailboxPath: sentMailbox.path,
        draft: draft,
        messageId: draft.messageId,
        jmapId: emailId,
      );
    } catch (e, stack) {
      unawaited(
        _appLogger?.warn(
          'outbox.send.sent_copy_failed',
          'Message sent, but recording the Sent copy locally failed: $e',
          accountId: account.id,
          error: e,
          stack: stack,
        ),
      );
    }
    return warning;
  }

  /// The recipients [jmap] already reports as undeliverable
  /// (`delivered: "no"`, RFC 8621 §7) for the submission [submissionId].
  /// Best-effort: a failed lookup must not turn a sent message into a failed
  /// send, so it reports nobody.
  Future<List<RejectedRecipient>> _jmapRejectedRecipients(
    JmapClient jmap,
    String submissionId,
  ) async {
    try {
      final responses = await jmap.call(
        [
          [
            'EmailSubmission/get',
            {
              'accountId': jmap.accountId,
              'ids': [submissionId],
              'properties': ['deliveryStatus'],
            },
            'g',
          ],
        ],
        withSubmission: true,
      );
      final list = _responseArgs(responses, 0, 'EmailSubmission/get')['list']
          as List<dynamic>?;
      final status = (list == null || list.isEmpty)
          ? null
          : (list.first as Map<String, dynamic>)['deliveryStatus']
              as Map<String, dynamic>?;
      return [
        for (final MapEntry(key: email, value: s) in (status ?? {}).entries)
          if (s is Map<String, dynamic> && s['delivered'] == 'no')
            RejectedRecipient.fromReply(email, s['smtpReply']?.toString()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Best-effort removal of a locally-created JMAP email (e.g. the Sent copy
  /// created before a failed submission). Swallows errors: the original send
  /// failure is what matters to the caller, and a failed cleanup must not mask
  /// it.
  Future<void> _destroyJmapEmail(JmapClient jmap, String emailId) async {
    try {
      await jmap.call([
        [
          'Email/set',
          {
            'accountId': jmap.accountId,
            'destroy': [emailId],
          },
          '0',
        ],
      ]);
    } catch (_) {
      // Ignore — the send already failed and that error is being rethrown.
    }
  }

  @override
  Future<String> downloadAttachment(
    String emailId,
    model.EmailAttachment attachment,
  ) async {
    final cacheDir = await _getCacheDir();
    final emailDir = p.join(
      cacheDir.path,
      'sharedinbox',
      'attachments',
      emailId.replaceAll(':', '_'),
    );
    final name = safeFileName(attachment.filename);
    // One folder per part, so two parts with the same file name stay apart
    // and each keeps its real name. Without a part id only the old layout
    // (`<email>/<name>`) can hold it.
    final partDir = 'part-${safeFileName(attachment.fetchPartId)}';
    final file = File(
      attachment.fetchPartId.isEmpty
          ? p.join(emailDir, name)
          : p.join(emailDir, partDir, name),
    );
    if (await file.exists()) {
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    }

    if (attachment.fetchPartId.isEmpty) {
      throw StateError(
        'Cannot download ${attachment.filename}: missing part ID. '
        'Open the email again to refresh.',
      );
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final bytes = await jmap.downloadBlob(
        attachment.fetchPartId,
        name: attachment.filename,
        type: attachment.contentType,
      );
      await _writeCachedAttachment(file, bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectUnicodeMailboxByPath(emailRow.mailboxPath);
      // Fetch the full message so enough_mail has MIME headers (including
      // Content-Transfer-Encoding) and getPart() can decode the part correctly.
      // A partial BODY.PEEK[n] fetch omits those headers, causing
      // decodeContentBinary() to return raw base64 instead of decoded bytes.
      final fetch = await client.uidFetchMessage(emailRow.uid, 'BODY.PEEK[]');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      // Resolve the specific MIME part. Never fall back to `msg` itself: if the
      // stored fetchPartId no longer resolves, decoding the whole multipart
      // message and presenting its raw bytes as the attachment yields garbage
      // (e.g. an "image" that renders as colour-noise, #830). Surface an error
      // so the caller can offer a Retry / download instead.
      final part = msg.getPart(attachment.fetchPartId);
      if (part == null) {
        throw StateError(
          'Could not locate part ${attachment.fetchPartId} for '
          '${attachment.filename}. Open the email again to refresh.',
        );
      }
      final bytes = part.decodeContentBinary();
      if (bytes == null) {
        throw StateError('Failed to decode attachment ${attachment.filename}.');
      }
      await _writeCachedAttachment(file, bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    } finally {
      await closeImapClient(client);
    }
  }

  /// Writes [bytes] to [file] through a temp file renamed into place, so an
  /// interrupted download never leaves a truncated file that later counts
  /// as cached.
  Future<void> _writeCachedAttachment(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.download');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  /// Upserts an [AttachmentFiles] row after the attachment has been flushed
  /// to disk. Used by the Sync state screen to bucket mails as fully / partly
  /// offline without stat()ing every attachment on every render.
  Future<void> _recordAttachmentFile(
    String emailId,
    String filename,
    File file,
  ) async {
    final size = await file.length();
    try {
      await _db.into(_db.attachmentFiles).insertOnConflictUpdate(
            AttachmentFilesCompanion.insert(
              emailId: emailId,
              filename: filename,
              size: size,
              downloadedAt: DateTime.now(),
            ),
          );
    } catch (e) {
      // The email was deleted while the download ran.
      if (!isForeignKeyViolation(e)) rethrow;
    }
  }

  @override
  Future<String> fetchRawRfc822(String emailId) async {
    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      final jmap = await JmapClient.connect(
        httpClient: _httpClient,
        jmapUrl: Uri.parse(account.jmapUrl!),
        username: _effectiveUsername(account),
        password: password,
      );
      final jmapEmailId = emailId.contains(':')
          ? emailId.substring(emailId.indexOf(':') + 1)
          : emailId;
      final responses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': [jmapEmailId],
            'properties': ['id', 'blobId'],
          },
          '0',
        ],
      ]);
      final result = _responseArgs(responses, 0, 'Email/get');
      final list = result['list'] as List<dynamic>;
      final emailData = list.firstOrNull as Map<String, dynamic>?;
      if (emailData == null) {
        throw StateError(
          'JMAP server returned no message for id $jmapEmailId.',
        );
      }
      final blobId = emailData['blobId'] as String?;
      if (blobId == null || blobId.isEmpty) {
        throw StateError(
          'JMAP server returned no blobId for id $jmapEmailId.',
        );
      }
      final bytes = await jmap.downloadBlob(
        blobId,
        name: 'email.eml',
        type: 'message/rfc822',
      );
      return utf8.decode(bytes, allowMalformed: true);
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectUnicodeMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, 'BODY.PEEK[]');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      return msg.renderMessage();
    } finally {
      await closeImapClient(client);
    }
  }

  @override
  Future<List<model.Email>> searchEmailsGlobal(
    String? accountId,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsLocal(
        accountId: accountId,
        mailboxPath: null,
        query: query,
        limit: limit,
      );

  /// Shared body of [searchEmails] and [searchEmailsGlobal]: the subject/
  /// preview/From FTS hits merged with the note and body hits, deduplicated,
  /// flagged then newest first, capped at [limit].
  ///
  /// Each source returns its own first [limit] rows in that same order, so
  /// the first [limit] of the merge are exactly the first [limit] of the full
  /// union — growing [limit] (the UI's "Load more") extends the list without
  /// reordering what is already shown.
  Future<List<model.Email>> _searchEmailsLocal({
    required String? accountId,
    required String? mailboxPath,
    required String query,
    required int limit,
  }) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty || limit <= 0) return [];

    final subjectRows = await _searchEmailsByFts(
      fromJoin: 'FROM email_fts f JOIN emails e ON e.rowid = f.rowid',
      ftsTable: 'email_fts',
      readsFrom: {_db.emails},
      accountId: accountId,
      mailboxPath: mailboxPath,
      query: query,
      limit: limit,
      // email_fts maps 1:1 onto emails by rowid: no duplicates to collapse.
      distinct: false,
    );
    final noteRows =
        await _searchEmailsByNotes(accountId, mailboxPath, query, limit);
    final bodyRows =
        await _searchEmailsByBody(accountId, mailboxPath, query, limit);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...subjectRows, ...noteRows, ...bodyRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort(model.compareFlaggedThenNewest);
    return merged.length > limit ? merged.sublist(0, limit) : merged;
  }

  /// Returns emails whose plaintext body matches [query] via the
  /// `email_body_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByBody(
    String? accountId,
    String? mailboxPath,
    String query,
    int limit,
  ) =>
      _searchEmailsByFts(
        fromJoin: 'FROM email_body_fts f'
            ' JOIN email_bodies b ON b.rowid = f.rowid'
            ' JOIN emails e ON e.id = b.email_id',
        ftsTable: 'email_body_fts',
        readsFrom: {_db.emails, _db.emailBodies},
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
        limit: limit,
      );

  /// Returns emails whose associated notes match [query] via the
  /// `email_notes_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByNotes(
    String? accountId,
    String? mailboxPath,
    String query,
    int limit,
  ) =>
      _searchEmailsByFts(
        fromJoin: 'FROM email_notes_fts f'
            ' JOIN email_notes n ON n.rowid = f.rowid'
            ' JOIN emails e ON e.message_id = n.message_id'
            ' AND e.account_id = n.account_id'
            // Deleted locally, still waiting for the server delete.
            ' AND n.pending_delete = 0',
        ftsTable: 'email_notes_fts',
        readsFrom: {_db.emails, _db.emailNotes},
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
        limit: limit,
      );

  /// Runs an FTS5 `MATCH` search whose hits resolve back to `emails` (aliased
  /// `e`) and returns them as models, flagged and newest first. [fromJoin] is
  /// the `FROM …` clause joining the [ftsTable] shadow index to `emails`;
  /// [ftsTable] is the virtual-table name used in the `MATCH` predicate.
  /// Optionally filtered by [accountId] and [mailboxPath]; at most [limit]
  /// rows. Shared by the subject, body and note search paths.
  Future<List<model.Email>> _searchEmailsByFts({
    required String fromJoin,
    required String ftsTable,
    required Set<ResultSetImplementation> readsFrom,
    required String? accountId,
    required String? mailboxPath,
    required String query,
    required int limit,
    bool distinct = true,
  }) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    final extraConditions = StringBuffer();
    final extraVars = <Variable<String>>[];
    if (accountId != null) {
      extraConditions.write(' AND e.account_id = ?');
      extraVars.add(Variable<String>(accountId));
    }
    if (mailboxPath != null) {
      extraConditions.write(' AND e.mailbox_path = ?');
      extraVars.add(Variable<String>(mailboxPath));
    }

    final sql = 'SELECT${distinct ? ' DISTINCT' : ''} e.* $fromJoin'
        ' WHERE $ftsTable MATCH ?$extraConditions'
        ' ORDER BY $_emailListOrderSql LIMIT ?';

    final rows = await _db
        .customSelect(
          sql,
          variables: [
            Variable<String>(ftsQuery),
            ...extraVars,
            Variable<int>(limit),
          ],
          readsFrom: readsFrom,
        )
        .get();
    final emailRows =
        await Future.wait(rows.map((r) => _db.emails.mapFromRow(r)));
    return emailRows.map(_toModel).toList();
  }

  @override
  Future<List<model.Email>> searchEmailsStructured(
    String? accountId,
    FilterGroup filter, {
    int limit = searchPageSize,
  }) async {
    final rows = await (_db.select(_db.emails)
          ..where((t) {
            final fe = _filterGroup(filter, t);
            if (accountId == null) return fe;
            return t.accountId.equals(accountId) & fe;
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
    return rows.map(_toModel).toList();
  }

  Expression<bool> _filterGroup(FilterGroup group, $EmailsTable t) {
    if (group.isEmpty) return const Constant(true);
    final exprs = group.children.map((c) => _filterNode(c, t)).toList();
    return switch (group.operator) {
      FilterOperator.and_ => exprs.reduce((a, b) => a & b),
      FilterOperator.or_ => exprs.reduce((a, b) => a | b),
    };
  }

  Expression<bool> _filterNode(FilterNode node, $EmailsTable t) =>
      switch (node) {
        final FilterLeaf l => _filterLeaf(l, t),
        final FilterGroup g => _filterGroup(g, t),
      };

  Expression<bool> _filterLeaf(FilterLeaf leaf, $EmailsTable t) {
    final val = leaf.value.toLowerCase();
    return switch (leaf.field) {
      FilterField.from_ => _jsonLike(t.fromJson, leaf.comparison, val),
      FilterField.to => _jsonLike(t.toAddresses, leaf.comparison, val),
      FilterField.cc => _jsonLike(t.ccJson, leaf.comparison, val),
      FilterField.subject => _textLike(t.subject, leaf.comparison, val),
      FilterField.size => _sizeCompare(t.sizeBytes, leaf),
      FilterField.header => _headerLike(leaf, t),
      // `is` compares the whole stored path, ignoring ASCII case. Not LIKE:
      // that lowercased the value first, and as SQLite folds only ASCII case
      // a non-ASCII path ("Übersicht") never matched; `_`/`%` in a path also
      // acted as wildcards.
      FilterField.folder => leaf.comparison == FilterComparison.is_
          ? t.mailboxPath.collate(Collate.noCase).equals(leaf.value)
          : const Constant(false),
    };
  }

  /// Compares the stored message size. An unparseable value matches
  /// nothing (the editors refuse it), and so does a row whose size is unknown
  /// (NULL: cached before schema v64 and not yet backfilled by a reconcile):
  /// SQL `NULL > n` is not true.
  Expression<bool> _sizeCompare(GeneratedColumn<int> col, FilterLeaf leaf) {
    final bytes = parseFilterSize(leaf.value);
    if (bytes == null) return const Constant(false);
    return switch (leaf.comparison) {
      FilterComparison.over => col.isBiggerThanValue(bytes),
      FilterComparison.under => col.isSmallerThanValue(bytes),
      _ => const Constant(false),
    };
  }

  Expression<bool> _jsonLike(
    GeneratedColumn<String> col,
    FilterComparison comp,
    String val,
  ) =>
      switch (comp) {
        FilterComparison.contains => col.like('%$val%'),
        FilterComparison.is_ => col.like('%"email":"$val"%'),
        FilterComparison.matches => col.like(_globToLike(val)),
        // over/under on a text field: the editors never offer it, but a
        // hand-made or imported filter must not match every mail.
        _ => const Constant(false),
      };

  Expression<bool> _textLike(
    GeneratedColumn<String> col,
    FilterComparison comp,
    String val,
  ) =>
      switch (comp) {
        FilterComparison.contains => col.like('%$val%'),
        FilterComparison.is_ => col.like(val),
        FilterComparison.matches => col.like(_globToLike(val)),
        // over/under on a text field: the editors never offer it, but a
        // hand-made or imported filter must not match every mail.
        _ => const Constant(false),
      };

  /// Header filters are matched against the JSON-encoded header list cached
  /// in `email_bodies.headers_json`. Only messages whose body has already
  /// been fetched (and therefore have a matching `email_bodies` row) can be
  /// found — messages without a cached body are silently skipped.
  Expression<bool> _headerLike(FilterLeaf leaf, $EmailsTable t) {
    final name = (leaf.headerName ?? '').trim();
    if (name.isEmpty) return const Constant(false);
    // Header list is stored as `[{"name":"X","value":"Y"},...]`, in the
    // order produced by `EmailHeader.toJson` (name first, then value).
    final storedName = _jsonEsc(name);
    final storedValue = _jsonEsc(leaf.value);
    final literalNameLike = _likeEsc(storedName);
    final literalValueLike = _likeEsc(storedValue);
    final pattern = switch (leaf.comparison) {
      FilterComparison.is_ =>
        '%"name":"$literalNameLike","value":"$literalValueLike"%',
      FilterComparison.contains =>
        '%"name":"$literalNameLike","value":"%$literalValueLike%"%',
      FilterComparison.matches =>
        '%"name":"$literalNameLike","value":"${_globToLikeBang(storedValue)}"%',
      _ => null,
    };
    if (pattern == null) return const Constant(false);
    final sub = _db.selectOnly(_db.emailBodies)
      ..addColumns([_db.emailBodies.emailId])
      ..where(
        _db.emailBodies.emailId.equalsExp(t.id) &
            _db.emailBodies.headersJson.like(pattern, escapeChar: '!'),
      );
    return existsQuery(sub);
  }

  /// Escapes characters that would break out of a JSON string literal.
  static String _jsonEsc(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  /// Escapes SQL LIKE meta-characters (`%`, `_`) with a leading `!`; the
  /// caller must pair this with `escapeChar: '!'` on the LIKE call. `!` is
  /// used instead of `\` so it never collides with the literal backslashes
  /// that JSON encoding inserts into the header value.
  static String _likeEsc(String s) =>
      s.replaceAll('!', '!!').replaceAll('%', '!%').replaceAll('_', '!_');

  /// Converts a glob pattern to a SQL LIKE pattern, escaping LIKE
  /// meta-characters with `!` to match the escape char used by [_headerLike].
  static String _globToLikeBang(String glob) {
    final buf = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '%' || ch == '_' || ch == '!') {
        buf.write('!$ch');
      } else if (ch == '*') {
        buf.write('%');
      } else if (ch == '?') {
        buf.write('_');
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  static String _globToLike(String glob) {
    final buf = StringBuffer();
    for (var i = 0; i < glob.length; i++) {
      final ch = glob[i];
      if (ch == '%' || ch == '_') {
        buf.write('\\$ch');
      } else if (ch == '*') {
        buf.write('%');
      } else if (ch == '?') {
        buf.write('_');
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }

  /// Converts a user query string into an FTS5 match expression.
  ///
  /// The query is first split on whitespace into the chunks the user actually
  /// typed. Each chunk becomes a quoted prefix phrase: `foo` → `"foo" *`, so
  /// partial words still match while typing. A punctuated chunk (`foo.com`)
  /// becomes the adjacent phrase `"foo com" *`: the default `unicode61`
  /// tokenizer splits on the punctuation on the index side too, so requiring
  /// the tokens to stay adjacent is the closest FTS5 can get to an exact
  /// "foo.com" match — and, unlike the old `foo* com*`, it no longer matches
  /// mails that merely contain `foo` and `com` far apart (#806). The trailing
  /// `*` keeps prefix matching on the last token (`foo.co` → `"foo co" *`).
  /// Separate chunks are still combined with FTS5's implicit AND, so
  /// `foo com` finds mails containing both words anywhere.
  ///
  /// The quotes keep a typed `AND`, `OR` or `NOT` a plain word: unquoted, FTS5
  /// reads it as an operator and the search fails with a syntax error.
  ///
  /// Every Unicode letter, mark and digit counts as part of a word. Dart's
  /// `\w` is ASCII-only, so `Müller` used to become the phrase `"M ller"` and
  /// `Привет` an empty query, and neither found anything. unicode61 does not
  /// split CJK text into words, so there only a prefix of the whole run
  /// matches (`東京` finds `東京駅`, `駅` does not).
  static String _toFtsQuery(String query) {
    final terms = <String>[];
    for (final chunk in query.trim().split(RegExp(r'\s+'))) {
      final tokens =
          chunk.split(_nonWordChars).where((t) => t.isNotEmpty).toList();
      if (tokens.isEmpty) continue;
      terms.add('"${tokens.join(' ')}" *');
    }
    return terms.join(' ');
  }

  static final _nonWordChars = RegExp(r'[^\p{L}\p{M}\p{N}_]+', unicode: true);

  @override
  Future<List<model.Email>> getEmailsByAddress(
    String? accountId,
    String address, {
    int? limit,
  }) async {
    final pattern = '%${address.toLowerCase()}%';
    final select = _db.select(_db.emails)
      ..where((t) {
        Expression<bool> condition = const Constant(true);
        if (accountId != null) {
          condition = t.accountId.equals(accountId);
        }
        condition = condition &
            (t.fromJson.like(pattern) |
                t.toAddresses.like(pattern) |
                t.ccJson.like(pattern));
        return condition;
      })
      ..orderBy([
        (t) => OrderingTerm.desc(t.isFlagged),
        (t) => OrderingTerm.desc(t.receivedAt),
        (t) => OrderingTerm.desc(t.uid),
        (t) => OrderingTerm.desc(t.id),
      ]);
    if (limit != null) select.limit(limit);
    final rows = await select.get();
    return rows.map(_toModel).toList();
  }

  @override
  Future<List<model.EmailAddress>> searchAddresses(
    String? accountId,
    String query, {
    int limit = 10,
  }) async {
    if (query.length < 2) return [];
    final pattern = '%${query.toLowerCase()}%';

    // Addresses we deliberately wrote to (sent folder) should appear before
    // addresses that happened to email us (inbox/other folders).
    final sentMailboxes = await (_db.select(_db.mailboxes)
          ..where((t) {
            Expression<bool> cond = t.role.equals('sent');
            if (accountId != null) {
              cond = t.accountId.equals(accountId) & cond;
            }
            return cond;
          }))
        .get();
    final sentPaths = {for (final m in sentMailboxes) m.path};

    final rows = await (_db.select(_db.emails)
          ..where((t) {
            Expression<bool> cond = const Constant(true);
            if (accountId != null) cond = t.accountId.equals(accountId);
            cond = cond &
                (t.fromJson.like(pattern) |
                    t.toAddresses.like(pattern) |
                    t.ccJson.like(pattern));
            return cond;
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(100))
        .get();

    // Two passes: sent-folder rows first (prioritise recipients we chose),
    // then other rows (senders who contacted us).
    final sortedRows = [
      ...rows.where((r) => sentPaths.contains(r.mailboxPath)),
      ...rows.where((r) => !sentPaths.contains(r.mailboxPath)),
    ];

    final seen = <String>{};
    final results = <model.EmailAddress>[];
    final lowerQuery = query.toLowerCase();
    for (final row in sortedRows) {
      final isSent = sentPaths.contains(row.mailboxPath);
      final fields = isSent
          ? [row.toAddresses, row.ccJson, row.fromJson]
          : [row.fromJson, row.toAddresses, row.ccJson];
      for (final jsonStr in fields) {
        final list = jsonDecode(jsonStr) as List<dynamic>;
        for (final e in list) {
          final map = e as Map<String, dynamic>;
          final addr = model.EmailAddress(
            name: map['name'] as String?,
            email: map['email'] as String,
          );
          if ((addr.email.toLowerCase().contains(lowerQuery) ||
                  (addr.name?.toLowerCase().contains(lowerQuery) ?? false)) &&
              seen.add(addr.email.toLowerCase())) {
            results.add(addr);
            if (results.length >= limit) return results;
          }
        }
      }
    }
    return results;
  }

  @override
  // Results are limited to emails already synced into the local SQLite FTS5
  // index; call syncEmails first to ensure the index is up-to-date.
  Future<List<model.Email>> searchEmails(
    String accountId,
    String mailboxPath,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsLocal(
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
        limit: limit,
      );

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// JMAP header fields like messageId/inReplyTo/references come as arrays.
  /// We join them space-separated to match the IMAP convention.
  static String? _joinJmapStringList(List<dynamic>? list) {
    if (list == null || list.isEmpty) return null;
    final joined = list.cast<String>().join(' ');
    return joined.isEmpty ? null : joined;
  }

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

  /// Derives a stable thread key from RFC 2822 headers.
  ///
  /// Precedence, matching JWZ-style threading:
  ///   1. First entry of `References` — the oldest ancestor, so every message
  ///      down the chain agrees on the same root Message-ID.
  ///   2. `In-Reply-To` — used when `References` is missing but the client
  ///      still recorded the immediate parent.
  ///   3. Own `Message-ID` — starts a fresh thread that later replies will
  ///      attach to via their `In-Reply-To`.
  ///   4. Subject fallback — when a message has no Message-ID/References/
  ///      In-Reply-To at all (rare, non-conformant senders), group by
  ///      normalised subject bucketed into a `yyyy-mm` window so unrelated
  ///      re-uses of the same subject in a different month land in a
  ///      separate thread. See [normalizedSubject] for the strip rules.
  ///
  /// Returns `null` only when nothing usable is available (no headers, no
  /// subject); the caller then falls back to the per-message `emailId` so the
  /// thread contains just this message.
  static String? _computeThreadId({
    required String? messageId,
    required String? inReplyTo,
    required String? references,
    String? subject,
    DateTime? date,
  }) {
    if (references != null && references.isNotEmpty) {
      final first = references.trim().split(RegExp(r'\s+')).firstOrNull;
      if (first != null && first.isNotEmpty) return first;
    }
    if (inReplyTo != null && inReplyTo.isNotEmpty) return inReplyTo;
    if (messageId != null && messageId.isNotEmpty) return messageId;
    final subj = normalizedSubject(subject);
    if (subj.isNotEmpty && date != null) {
      final utc = date.toUtc();
      final bucket = '${utc.year.toString().padLeft(4, '0')}-'
          '${utc.month.toString().padLeft(2, '0')}';
      return 'subj:$bucket:$subj';
    }
    return null;
  }

  String _encodeAddresses(List<imap.MailAddress>? addresses) => jsonEncode(
        (addresses ?? const [])
            .map((a) => {'name': a.personalName, 'email': a.email})
            .toList(),
      );

  @override
  Stream<List<model.Email>> observeEmailsInThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) {
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.threadId.equals(threadId),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.uid),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Stream<List<model.Email>> observeThreadAcrossFolders(
    String accountId,
    String threadId,
  ) {
    // Same as observeEmailsInThread but without the mailboxPath filter, so a
    // conversation's Inbox, Sent and Archive copies are gathered together
    // (#754). The UID tiebreak compares UIDs of different folders, so for
    // same-second copies it only makes the order deterministic.
    return (_db.select(_db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.threadId.equals(threadId),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.uid),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  model.Email _toModel(Email row) {
    List<model.EmailAddress> parseAddresses(String json) {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map(
            (e) => model.EmailAddress(
              name: (e as Map<String, dynamic>)['name'] as String?,
              email: e['email'] as String,
            ),
          )
          .toList();
    }

    return model.Email(
      id: row.id,
      accountId: row.accountId,
      mailboxPath: row.mailboxPath,
      uid: row.uid,
      subject: row.subject,
      sentAt: row.sentAt,
      receivedAt: row.receivedAt,
      from: parseAddresses(row.fromJson),
      to: parseAddresses(row.toAddresses),
      cc: parseAddresses(row.ccJson),
      replyTo: parseAddresses(row.replyToJson),
      bcc: parseAddresses(row.bccJson),
      preview: row.preview,
      isSeen: row.isSeen,
      isFlagged: row.isFlagged,
      hasAttachment: row.hasAttachment,
      threadId: row.threadId,
      messageId: row.messageId,
      inReplyTo: row.inReplyTo,
      references: row.references,
      snoozedUntil: row.snoozedUntil,
      snoozedFromMailboxPath: row.snoozedFromMailboxPath,
      listUnsubscribeHeader: row.listUnsubscribeHeader,
      isLocal: row.isLocal,
      size: row.sizeBytes,
    );
  }

  model.EmailBody _bodyRowToModel(EmailBody row) => model.EmailBody(
        emailId: row.emailId,
        textBody: row.textBody,
        htmlBody: row.htmlBody,
        attachments: _parseAttachments(row.attachmentsJson),
        headers: _parseHeaders(row.headersJson),
        mimeTree: _parseMimeTree(row.mimeTreeJson),
      );

  model.MimePart? _parseMimeTree(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return _mimePartFromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  model.MimePart _mimePartFromJson(Map<String, dynamic> m) => model.MimePart(
        contentType: m['contentType'] as String? ?? 'application/octet-stream',
        filename: m['filename'] as String?,
        size: m['size'] as int?,
        encoding: m['encoding'] as String?,
        children: ((m['children'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>()
            .map(_mimePartFromJson)
            .toList(),
      );

  /// Opportunistic backfill for address headers stored only since a later
  /// schema: Reply-To (#919), so mail cached before replies to the right
  /// address, and Bcc (#1097). Fills only empty columns, from the body's
  /// [headers] already at hand (fresh fetch or cache), so it costs no network
  /// round trip. [row] saves the lookup when the caller has it.
  Future<void> _backfillAddressHeaders(
    String emailId,
    List<model.EmailHeader> headers, {
    Email? row,
  }) async {
    const names = {'reply-to', 'bcc'};
    final relevant = [
      for (final h in headers)
        if (names.contains(h.name.toLowerCase())) h,
    ];
    if (relevant.isEmpty) return;
    final emailRow = row ??
        await (_db.select(_db.emails)..where((t) => t.id.equals(emailId)))
            .getSingleOrNull();
    if (emailRow == null) return;
    bool isEmpty(String stored) => stored.isEmpty || stored == '[]';
    if (!isEmpty(emailRow.replyToJson) && !isEmpty(emailRow.bccJson)) return;

    // Let enough_mail parse and RFC 2047-decode the raw header values.
    final msg = imap.MimeMessage.parseFromText(
      '${relevant.map((h) => '${h.name}: ${h.value}').join('\r\n')}\r\n\r\n',
    );
    String? decode(String stored, String header) {
      if (!isEmpty(stored)) return null;
      final addresses = msg.decodeHeaderMailAddressValue(header);
      if (addresses == null || addresses.isEmpty) return null;
      return _encodeAddresses(addresses);
    }

    final replyTo = decode(emailRow.replyToJson, 'Reply-To');
    final bcc = decode(emailRow.bccJson, 'Bcc');
    if (replyTo == null && bcc == null) return;
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        replyToJson: replyTo == null ? const Value.absent() : Value(replyTo),
        bccJson: bcc == null ? const Value.absent() : Value(bcc),
      ),
    );
  }

  List<model.EmailHeader> _parseHeaders(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list
          .cast<Map<String, dynamic>>()
          .map((m) => model.EmailHeader.fromJson(m))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Rough on-disk size of a cached body in characters — sum of textBody +
  /// htmlBody length. Reported by the Sync state screen; not the wire size.
  int _bodySize(String? textBody, String? htmlBody) =>
      (textBody?.length ?? 0) + (htmlBody?.length ?? 0);

  /// Records the first time a server message is stored locally, so the
  /// per-message "Show Logs" view starts with the mail's own fetch (#920).
  void _logEmailFetched({
    required String emailId,
    required String accountId,
    required String mailboxPath,
    required String protocol,
    String? subject,
    int? bytes,
  }) {
    unawaited(
      _appLogger?.info(
        'email.fetched',
        'Fetched "${subject ?? '(no subject)'}" from the server '
            '(${protocol.toUpperCase()})',
        data: {
          'protocol': protocol,
          if (bytes != null) 'bytes': bytes,
        },
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
      ),
    );
  }

  /// Records how a message body was loaded so the per-message "Show Logs" view
  /// answers "did opening this mail need the Internet?" (#642). [source] is one
  /// of `cache`, `local`, `imap` or `jmap`; [network] says whether the load hit
  /// the server. Best-effort and fire-and-forget — logging must never affect or
  /// slow down the body load.
  void _logBodyLoaded({
    required String emailId,
    required String source,
    required bool network,
    required bool prefetch,
    String? accountId,
    String? mailboxPath,
    int? cacheAgeSeconds,
    int? bytes,
    int? durationMs,
  }) {
    final where = network
        ? 'over the Internet (${source.toUpperCase()})'
        : source == 'local'
            ? 'from this device (locally-composed message) — no Internet needed'
            : 'from the local cache — no Internet needed';
    final how = prefetch ? 'Prefetched' : 'Loaded';
    unawaited(
      _appLogger?.info(
        'email.body.loaded',
        '$how message body $where',
        data: {
          'source': source,
          'internet': network,
          'trigger': prefetch ? 'prefetch' : 'open',
          if (cacheAgeSeconds != null) 'cacheAgeSeconds': cacheAgeSeconds,
          if (bytes != null) 'bytes': bytes,
          if (durationMs != null) 'durationMs': durationMs,
        },
        accountId: accountId,
        mailboxPath: mailboxPath,
        emailId: emailId,
      ),
    );
  }

  List<model.EmailAttachment> _parseAttachments(String json) {
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map(
          (e) => model.EmailAttachment(
            filename: (e as Map<String, dynamic>)['filename'] as String,
            contentType: e['contentType'] as String,
            size: e['size'] as int,
            fetchPartId: (e['fetchPartId'] as String?) ?? '',
          ),
        )
        .toList();
  }

  // ── Failed mutations (offline compose queue) ─────────────────────────────

  @override
  Stream<List<model.FailedMutation>> observeFailedMutations(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where(
            (t) => t.accountId.equals(accountId) & t.lastError.isNotNull(),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map(
          (rows) => rows
              .map(
                (r) => model.FailedMutation(
                  id: r.id,
                  accountId: r.accountId,
                  changeType: r.changeType,
                  resourceId: r.resourceId,
                  lastError: r.lastError!,
                  attempts: r.attempts,
                  createdAt: r.createdAt,
                  failed: r.state == _failedState,
                  stuck: r.state == _stuckState,
                ),
              )
              .toList(),
        );
  }

  @override
  Future<void> discardMutation(int id) async {
    final discarded = await _db.transaction(() async {
      final row = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      // An in-flight change may be reaching the server right now: the
      // flush settles it (the screen offers no Discard for it).
      if (row == null || row.state == _inflightState) return null;
      await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(id)))
          .go();
      // A failed change no longer shows locally.
      if (row.state == _failedState) return null;
      // Pending or stuck: the mail still shows the user's intent. Give that
      // up as a failure would, so it does not vanish or keep a value the
      // server never gets; the mail's later moves and deletes depend on it.
      await _afterFlagFailure(row, revert: true);
      return (
        row: row,
        dependents: await _afterLocationFailure(row, revert: true)
      );
    });
    if (discarded != null) {
      _logDependentFailures(discarded.row, discarded.dependents);
    }
  }

  @override
  Future<void> retryMutation(int id) async {
    final row = await (_db.select(_db.pendingChanges)
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    if (row.state == _stuckState) {
      // Not synced yet: try it at the next flush instead of after its
      // backoff. It keeps its place in the queue.
      await (_db.update(_db.pendingChanges)
            ..where((t) => t.id.equals(id) & t.state.equals(_stuckState)))
          .write(PendingChangesCompanion(leaseUntil: Value(_now())));
      _changeCtrl.add(row.accountId);
      return;
    }
    if (row.state != _failedState) {
      // Still queued: it keeps its place, so newer changes stay newer and a
      // change being flushed right now is not queued twice. Just flush soon.
      _changeCtrl.add(row.accountId);
      return;
    }
    _noteLocalEdit(row.resourceId);
    await _db.transaction(() async {
      final current = await (_db.select(_db.pendingChanges)
            ..where((t) => t.id.equals(id) & t.state.equals(_failedState)))
          .getSingleOrNull();
      if (current == null) return;
      // The failure showed the server's state again; show the user's
      // intent again while it is retried.
      await _reapplyRetriedChange(current);
      // A fresh row at the end of the queue (new autoincrement id): the
      // retried change must not jump ahead of changes queued after it, or it
      // could undo the user's newer intent for the same mail.
      await _db.into(_db.pendingChanges).insert(
            PendingChangesCompanion.insert(
              accountId: current.accountId,
              resourceType: current.resourceType,
              resourceId: current.resourceId,
              changeType: current.changeType,
              payload: current.payload,
              createdAt: DateTime.now(),
            ),
          );
      await _deletePendingChange(current);
    });
    _noteLocalEdit(row.resourceId);
    _changeCtrl.add(row.accountId);
  }

  /// Re-applies the optimistic local part of a failed [row] that is being
  /// retried, without queueing or mirroring anything: the flag value, or for
  /// a move/snooze/unsnooze the destination, when the mail is (again) at the
  /// change's source. Leaves the mail alone otherwise.
  Future<void> _reapplyRetriedChange(PendingChangeRow row) async {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(row.payload) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final email = await (_db.select(_db.emails)
          ..where((t) => t.id.equals(row.resourceId)))
        .getSingleOrNull();
    if (email == null) return;
    if (!_sameMessage(row, email.messageId)) return;
    final seen = payload['seen'];
    final flagged = payload['flagged'];
    if ((row.changeType == 'flag_seen' && seen is bool) ||
        (row.changeType == 'flag_flagged' && flagged is bool)) {
      await (_db.update(_db.emails)..where((t) => t.id.equals(email.id))).write(
        EmailsCompanion(
          isSeen: seen is bool ? Value(seen) : const Value.absent(),
          isFlagged: flagged is bool ? Value(flagged) : const Value.absent(),
        ),
      );
      await _updateThread(
        email.accountId,
        email.mailboxPath,
        email.threadId ?? email.id,
      );
      return;
    }
    if (!_locationChangeTypes.contains(row.changeType)) return;
    final src = payload['mailboxPath'] ?? payload['src'];
    final dest = payload['dest'];
    if (src is! String || dest is! String) return;
    if (!await _isAtLocation(email, src)) return;
    final target = await _resolveSnoozedPlaceholder(email.accountId, dest);
    switch (row.changeType) {
      case 'move':
        await _applyLocalMove(email, target);
      case 'snooze':
        final until = DateTime.tryParse(payload['until'] as String? ?? '');
        if (until == null) return;
        await _applyLocalSnooze(email, target, until);
      case 'unsnooze':
        await _applyLocalUnsnooze(email, target);
    }
  }

  @override
  Stream<List<model.PendingChange>> observePendingChanges(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toPendingChange).toList());
  }

  @override
  Stream<List<model.PendingChange>> observeAllPendingChanges() {
    return (_db.select(_db.pendingChanges)
          ..orderBy([
            (t) => OrderingTerm.asc(t.createdAt),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toPendingChange).toList());
  }

  static model.PendingChange _toPendingChange(PendingChangeRow r) =>
      model.PendingChange(
        id: r.id,
        accountId: r.accountId,
        kind: r.changeType,
        resourceType: r.resourceType,
        resourceId: r.resourceId,
        payload: r.payload,
        createdAt: r.createdAt,
        attempts: r.attempts,
        lastError: r.lastError,
        failed: r.state == _failedState,
        sending: r.state == _inflightState,
        stuck: r.state == _stuckState,
        nextTry: r.state == _stuckState ? r.leaseUntil : null,
      );

  @override
  Future<void> clearForResync(String accountId) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion.
    // When emails are re-inserted after the next sync with the same IDs, the
    // cached body content will be reused without a network round-trip.
    // The pragma is per connection: other statements that run until the
    // finally block are unchecked too.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.emails,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
        // NB: pending_changes are deliberately NOT deleted here. A queued
        // change (e.g. a just-starred mail whose \Flagged flag hasn't reached
        // the server yet) is un-pushed user intent — dropping it would let the
        // subsequent full re-fetch overwrite the local state with stale server
        // truth, losing the star (#558). The caller flushes pending changes
        // before clearing; anything still queued (offline) survives and is
        // retried on the next sync, its payload carrying the uid/id needed to
        // apply it even though the email row was deleted.
        await (_db.delete(
          _db.syncStates,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  @override
  Future<void> clearMailboxForResync(
    String accountId,
    String mailboxPath,
  ) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion —
    // re-inserting emails with the same IDs after the next sync reuses the
    // cached body without a network round-trip. The pragma is per connection:
    // other statements that run until the finally block are unchecked too.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        // NB: pending_changes are deliberately NOT deleted here. A queued
        // change (e.g. a just-starred mail whose \Flagged flag hasn't reached
        // the server yet) is un-pushed user intent — dropping it would let the
        // subsequent full re-fetch overwrite the local state with stale server
        // truth, losing the star (#558). The caller flushes pending changes
        // before clearing; anything still queued (offline) survives and is
        // retried on the next sync, its payload carrying the uid/id needed to
        // apply it even though the email row was deleted.
        await (_db.delete(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(mailboxPath),
              ))
            .go();
        await (_db.delete(_db.threads)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(mailboxPath),
              ))
            .go();
        // Reset this mailbox's sync checkpoint. Only the row matching the
        // account's protocol exists; deleting both variants is a no-op for the
        // other. The global 'Email' state is left intact.
        await (_db.delete(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    (t.resourceType.equals('IMAP:$mailboxPath') |
                        t.resourceType.equals('JMAP:Email:$mailboxPath') |
                        t.resourceType.equals('JMAP:FullSync:$mailboxPath')),
              ))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }
}

/// Recursively converts an [imap.MimePart] into a JSON-serialisable map.
Map<String, dynamic> _mimePartToJson(imap.MimePart part) {
  final ct = part.getHeaderContentType();
  final disposition = part.getHeaderContentDisposition();
  final rawEncoding =
      part.getHeader('content-transfer-encoding')?.firstOrNull?.value;
  final encoding = rawEncoding?.split(';').first.trim().toLowerCase();
  return {
    'contentType': ct?.mediaType.text ?? 'application/octet-stream',
    'filename': mimePartFileName(disposition, ct),
    'size': disposition?.size,
    'encoding': encoding,
    'children': (part.parts ?? []).map(_mimePartToJson).toList(),
  };
}

/// Builds a JSON string representing the MIME tree of [msg].
String _buildMimeTreeJson(imap.MimeMessage msg) =>
    jsonEncode(_mimePartToJson(msg));

/// Converts a JMAP `bodyStructure` object into the same JSON format used by
/// [_mimePartToJson], so [_parseMimeTree] can deserialise it uniformly.
Map<String, dynamic> _jmapBodyStructureToJson(Map<String, dynamic> m) => {
      'contentType': m['type'] as String? ?? 'application/octet-stream',
      'filename': m['name'],
      'size': m['size'],
      'encoding': null,
      'children': ((m['subParts'] as List<dynamic>?) ?? [])
          .cast<Map<String, dynamic>>()
          .map(_jmapBodyStructureToJson)
          .toList(),
    };

/// Zone key under which [EmailRepositoryImpl.deleteEmails] publishes its
/// [_BulkScope].
final _bulkScopeKey = Object();

/// Zone key under which [EmailRepositoryImpl.flushPendingChanges] publishes
/// its claim token, which every change it claims carries, so it can release
/// exactly those if it ends without settling one.
final _flushTokenKey = Object();

/// A server flag read in progress (see
/// [EmailRepositoryImpl._startServerFlagRead]). The server's answer reflects
/// its state at some point after [_seq] was taken, so it must not overwrite a
/// row that had an edit queued when the read started, has one queued now, or
/// was edited locally since.
class _ServerFlagRead {
  _ServerFlagRead(this._seq, this._editSeqById, this._queuedAtStart);

  final int _seq;
  final Map<String, int> _editSeqById;
  final Set<String> _queuedAtStart;

  /// Whether the server's flags for [emailId] may be stale against a local
  /// edit. [queuedNow] is the `pendingChanges` set read after the answer
  /// arrived. Checked synchronously right before each write, so an edit
  /// started up to that moment is respected.
  bool protects(String emailId, Set<String> queuedNow) =>
      _queuedAtStart.contains(emailId) ||
      queuedNow.contains(emailId) ||
      editedSince(emailId);

  /// Whether a change for [emailId] was queued (or retried) after the read
  /// started.
  bool editedSince(String emailId) => (_editSeqById[emailId] ?? 0) > _seq;
}

/// State shared by every mutation running inside one bulk operation.
class _BulkScope {
  /// App Log writes deferred until the bulk transaction has committed.
  final logs = <Future<Object?>? Function()>[];

  /// Accounts that queued pending changes; each is kicked once at the end.
  final kickedAccounts = <String>{};

  /// Accounts already looked up during this operation.
  final accounts = <String, account_model.Account?>{};
}

/// A queued IMAP change whose message is gone: a move's message is in
/// neither its source nor its destination mailbox (another client deleted or
/// moved it), or a change queued behind a move cannot find its message
/// after that move. The flush marks the change failed.
class _ImapMessageGoneException implements Exception {
  _ImapMessageGoneException(this.message, {this.inNeitherMailbox = false});

  final String message;

  /// A move's message was searched for in its source and its destination
  /// and found in neither: the local row names no message any more.
  final bool inNeitherMailbox;

  @override
  String toString() => message;
}

/// The folder a queued IMAP change acts in could not be selected because it
/// no longer exists: the change is moot (see `_settleImapChange`).
class _ImapSourceMailboxGoneException implements Exception {
  _ImapSourceMailboxGoneException(this.cause);

  final Object cause;

  @override
  String toString() => cause.toString();
}

/// A queued IMAP change whose folder's UIDVALIDITY changed, and whose
/// message is not found exactly once again by Message-ID.
class _ImapUidValidityChangedException implements Exception {
  _ImapUidValidityChangedException(this.message, {this.noMatch = false});

  final String message;

  /// No message in the folder has the change's Message-ID: the mail is not
  /// there any more.
  final bool noMatch;

  @override
  String toString() => message;
}
