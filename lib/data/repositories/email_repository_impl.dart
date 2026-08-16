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
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/app_log_repository.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/outbox_repository.dart';
import 'package:sharedinbox/core/services/app_logger.dart';
import 'package:sharedinbox/core/sieve/sieve_interpreter.dart';
import 'package:sharedinbox/core/sieve/sieve_parser.dart';
import 'package:sharedinbox/core/sieve/sieve_rule.dart';
import 'package:sharedinbox/core/sync/account_comparison.dart';
import 'package:sharedinbox/core/sync/push_status.dart';
import 'package:sharedinbox/core/utils/cid_utils.dart';
import 'package:sharedinbox/core/utils/email_preview.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/core/utils/mail_header_decode.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/core/utils/subject_normalize.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/imap/imap_errors.dart';
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
  EmailRepositoryImpl(
    AppDatabase db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    SmtpConnectFn smtpConnect = connectSmtp,
    GetCacheDirFn getCacheDir = getTemporaryDirectory,
    http.Client? httpClient,
    OutboxRepository? outbox,
    AppLogger? appLogger,
    Duration sendOperationTimeout = const Duration(seconds: 50),
  })  : _db = db,
        _imapConnect = imapConnect,
        _smtpConnect = smtpConnect,
        _getCacheDir = getCacheDir,
        _httpClient = httpClient ?? http.Client(),
        _outbox = outbox ?? OutboxRepositoryImpl(db),
        _appLogger = appLogger,
        _sendOperationTimeout = sendOperationTimeout;

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
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
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
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
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.latestDate),
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
  /// `isFlagged`/`latestDate` ordering.
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
      final dedupKey = '${groupIds.first} $mid';

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
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
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
            participantsJson: Value(jsonEncode(participants)),
            preview: Value(latest.preview),
            latestEmailId: latest.id,
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

  @override
  Future<model.EmailBody> getEmailBody(
    String emailId, {
    bool forceRefresh = false,
  }) async {
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
        return _bodyRowToModel(cached);
      }
    }

    final emailRow = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
    // Local self-sent "virtual" messages have no server copy to fetch — always
    // serve the cached body we wrote when the message was composed (#545).
    if (emailRow.isLocal) {
      return cached != null
          ? _bodyRowToModel(cached)
          : const model.EmailBody(emailId: '', attachments: []);
    }
    final account = (await _accounts.getAccount(emailRow.accountId))!;
    final password = await _accounts.getPassword(account.id);

    if (account.type == account_model.AccountType.jmap) {
      return _getEmailBodyJmap(emailId, account, password);
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, '(BODY.PEEK[])');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      final textBody = msg.decodeTextPlainPart();
      final rawHtml = msg.decodeTextHtmlPart();
      final htmlBody =
          rawHtml == null ? null : injectInlineImages(rawHtml, msg);
      final contentInfos = msg.findContentInfo();

      final attachmentsJson = jsonEncode(
        contentInfos
            .map(
              (a) => {
                'filename': a.fileName ?? '',
                'contentType': a.contentType?.mediaType.text ?? '',
                // ContentInfo.fetchId is empty for parts that aren't addressable
                // (e.g. a non-multipart message whose top-level part is itself
                // marked as an attachment). MimeMessage.getPart() throws on an
                // empty fetchId, so guard before calling it.
                'size': a.size ??
                    (a.fetchId.isNotEmpty
                        ? msg.getPart(a.fetchId)?.decodeContentBinary()?.length
                        : null) ??
                    0,
                'fetchPartId': a.fetchId,
              },
            )
            .toList(),
      );

      final headersJson = jsonEncode(
        (msg.headers ?? [])
            .map((h) => {'name': h.name, 'value': h.value})
            .toList(),
      );

      final mimeTreeJson = _buildMimeTreeJson(msg);

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

      return model.EmailBody(
        emailId: emailId,
        textBody: textBody,
        htmlBody: htmlBody,
        attachments: _parseAttachments(attachmentsJson),
        headers: _parseHeaders(headersJson),
        mimeTree: _parseMimeTree(mimeTreeJson),
      );
    } finally {
      await client.logout();
    }
  }

  Future<model.EmailBody> _getEmailBodyJmap(
    String emailId,
    account_model.Account account,
    String password,
  ) async {
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
          'bodyProperties': ['partId', 'type', 'name', 'size', 'subParts'],
        },
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Email/get');
    final emailData =
        (result['list'] as List<dynamic>).first as Map<String, dynamic>;

    final (textBody, htmlBody, attachmentsJson) = _parseJmapBody(emailData);

    final rawHeaders = emailData['headers'] as List<dynamic>? ?? [];
    final headersJson = jsonEncode(
      rawHeaders.map((h) {
        final map = h as Map<String, dynamic>;
        return {'name': map['name'] ?? '', 'value': map['value'] ?? ''};
      }).toList(),
    );

    final rawBodyStructure =
        emailData['bodyStructure'] as Map<String, dynamic>?;
    final mimeTreeJson = rawBodyStructure != null
        ? jsonEncode(_jmapBodyStructureToJson(rawBodyStructure))
        : null;

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

    return model.EmailBody(
      emailId: emailId,
      textBody: textBody,
      htmlBody: htmlBody,
      attachments: _parseAttachments(attachmentsJson),
      headers: _parseHeaders(headersJson),
      mimeTree: _parseMimeTree(mimeTreeJson),
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
        selectedMailbox = await client.selectMailboxByPath(
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
          await removeLocalMailbox(_db, account.id, mailboxPath);
          return model.SyncEmailsResult.zero;
        }
        rethrow;
      }
      final uidValidity = selectedMailbox.uidValidity ?? 0;
      final serverModSeq = selectedMailbox.highestModSequence;
      final resourceType = 'IMAP:$mailboxPath';
      final checkpoint = await _loadImapCheckpoint(account.id, resourceType);

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
          );
        }
        final maxUid = allUids.isEmpty ? 0 : allUids.reduce(math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
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
        final newUids = (await client.uidSearchMessages(
              searchCriteria: 'UID ${lastUid + 1}:*',
            ))
                .matchingSequence
                ?.toList() ??
            [];
        var bytes = 0;
        if (newUids.isNotEmpty) {
          bytes = await _fetchAndUpsertImap(
            client,
            account,
            mailboxPath,
            imap.MessageSequence.fromIds(newUids, isUid: true),
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
        final maxUid =
            serverUids.isEmpty ? lastUid : serverUids.reduce(math.max);
        await _saveImapCheckpoint(
          account.id,
          resourceType,
          uidValidity,
          maxUid,
          highestModSeq: serverModSeq,
        );
        await _sweepOrphanThreads(account.id, mailboxPath);
        return model.SyncEmailsResult(
          fetched: newUids.length,
          skipped: serverUids.length - newUids.length,
          bytesTransferred: bytes,
        );
      }
    } finally {
      await client.logout();
    }
  }

  /// Fetches FLAGS for all messages modified since [sinceModSeq] and updates
  /// the local DB. Only messages whose modseq is > [sinceModSeq] are returned
  /// by the server (RFC 7162 §3.2).
  Future<void> _refreshFlagsImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    int sinceModSeq,
  ) async {
    final result = await client.uidFetchMessages(
      imap.MessageSequence.fromAll(),
      'FLAGS',
      changedSinceModSequence: sinceModSeq,
    );
    for (final msg in result.messages) {
      final uid = msg.uid;
      if (uid == null) continue;
      final emailId = '${account.id}:$mailboxPath:$uid';
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(
          isSeen: Value(msg.flags?.contains(r'\Seen') ?? false),
          isFlagged: Value(msg.flags?.contains(r'\Flagged') ?? false),
        ),
      );
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
    if (last != null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _imapFlagReconcileInterval) {
        return;
      }
    }

    final fetch = await client.uidFetchMessages(
      imap.MessageSequence.fromAll(),
      'FLAGS',
    );
    final byUid = <int, ({bool seen, bool flagged})>{};
    for (final msg in fetch.messages) {
      final uid = msg.uid;
      if (uid == null) continue;
      byUid[uid] = (
        seen: msg.flags?.contains(r'\Seen') ?? false,
        flagged: msg.flags?.contains(r'\Flagged') ?? false,
      );
    }

    final localRows = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath),
          ))
        .get();

    final inFlightIds = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.changeType.isIn(
                  const [
                    'flag_seen',
                    'flag_flagged',
                    'move',
                    'snooze',
                    'unsnooze',
                    'delete',
                  ],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    final inFlightSet = inFlightIds.toSet();

    final affectedThreads = <String>{};
    var corrected = 0;
    for (final row in localRows) {
      if (inFlightSet.contains(row.id)) continue;
      final serverFlags = byUid[row.uid];
      if (serverFlags == null) continue; // handled by _reconcileDeletedImap
      if (serverFlags.seen == row.isSeen &&
          serverFlags.flagged == row.isFlagged) {
        continue;
      }
      await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
        EmailsCompanion(
          isSeen: Value(serverFlags.seen),
          isFlagged: Value(serverFlags.flagged),
        ),
      );
      affectedThreads.add(row.threadId ?? row.id);
      corrected++;
    }

    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }

    if (corrected > 0) {
      log(
        'IMAP-sync: flag-reconcile mailbox=$mailboxPath corrected=$corrected '
        '(local=${localRows.length}, server=${byUid.length})',
      );
    }
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
  }

  // Returns the total bytes transferred (sum of RFC822.SIZE for each message).
  Future<int> _fetchAndUpsertImap(
    imap.ImapClient client,
    account_model.Account account,
    String mailboxPath,
    imap.MessageSequence sequence,
  ) async {
    // Request the first 8 KB of the body so we can derive an offline preview
    // snippet without a second round trip. Matches the JMAP `preview` field
    // (see [_upsertJmapEmails]); IMAP has no standard preview property.
    const fetchItems = '(UID FLAGS ENVELOPE BODYSTRUCTURE RFC822.SIZE '
        'BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-UNSUBSCRIBE)] '
        'BODY.PEEK[TEXT]<0.8192>)';
    final fetch = sequence.isUidSequence
        ? await client.uidFetchMessages(sequence, fetchItems)
        : await client.fetchMessages(sequence, fetchItems);
    final pendingByUid = await _pendingDeleteOrMoveUids(
      account.id,
      mailboxPath,
    );
    var bytes = 0;
    final affectedThreads = <String>{};
    // (realEmailId, messageId) of each row we just wrote — checked afterwards
    // for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String?)>[];
    await _db.transaction(() async {
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
            '(pending ${pendingByUid[uid]})',
          );
          continue;
        }
        bytes += msg.size ?? 0;
        final emailId = '${account.id}:$mailboxPath:$uid';
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

        await _db.into(_db.emails).insertOnConflictUpdate(
              EmailsCompanion.insert(
                id: emailId,
                accountId: account.id,
                mailboxPath: mailboxPath,
                uid: uid,
                subject: Value(subject),
                sentAt: Value(envelope.date),
                receivedAt: envelope.date ?? DateTime.now(),
                fromJson: Value(_encodeAddresses(envelope.from)),
                toAddresses: Value(_encodeAddresses(envelope.to)),
                ccJson: Value(_encodeAddresses(envelope.cc)),
                preview: Value(_extractImapPreview(msg)),
                isSeen: Value(msg.flags?.contains(r'\Seen') ?? false),
                isFlagged: Value(msg.flags?.contains(r'\Flagged') ?? false),
                hasAttachment: Value(msg.hasAttachments()),
                threadId: Value(threadId),
                messageId: Value(msgId),
                inReplyTo: Value(inReplyTo),
                references: Value(refs),
                snoozedUntil: Value(snoozedUntil),
                listUnsubscribeHeader: Value(listUnsubscribe),
              ),
            );
        if (msgId != null) dissolveCandidates.add((emailId, msgId));
      }
    });
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

  // UIDs in [mailboxPath] that have a pending local delete or move queued.
  // Used by the IMAP fetch path to avoid re-inserting rows the user has
  // already removed from view but whose change has not yet flushed.
  Future<Map<int, String>> _pendingDeleteOrMoveUids(
    String accountId,
    String mailboxPath,
  ) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals('Email') &
                (t.changeType.equals('delete') | t.changeType.equals('move')),
          ))
        .get();
    final result = <int, String>{};
    for (final r in rows) {
      try {
        final payload = jsonDecode(r.payload) as Map<String, dynamic>;
        if (payload['mailboxPath'] != mailboxPath) continue;
        final uid = payload['uid'];
        if (uid is int) result[uid] = r.changeType;
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
  }) async {
    final data = <String, dynamic>{
      'uidValidity': uidValidity,
      'lastUid': lastUid,
    };
    if (highestModSeq != null) data['highestModSeq'] = highestModSeq;
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
    final inFlightIds = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.changeType.isIn(
                  const ['move', 'snooze', 'unsnooze'],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    final inFlightSet = inFlightIds.toSet();

    final serverUidSet = serverUids.toSet();
    final affectedThreads = <String>{};
    for (final row in localRows) {
      // Local self-sent "virtual" rows have no server UID and must survive
      // until the real message arrives and dissolves them (#545).
      if (row.isLocal) continue;
      if (!serverUidSet.contains(row.uid)) {
        if (inFlightSet.contains(row.id)) continue;
        affectedThreads.add(row.threadId ?? row.id);
        await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
      }
    }
    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxPath, tid);
    }
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
      final selected = await client.selectMailboxByPath(mailboxPath);
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
      await client.logout();
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
      await client.selectMailboxByPath(mailboxPath);
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
      await client.logout();
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

  /// Pending changes exceeding this attempt count are evicted rather than
  /// retried, preventing unbounded queue growth from permanent server errors.
  static const _maxChangeAttempts = 5;

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

    if (storedMailboxState == null) {
      // Fallback to global 'Email' state
      final globalState = await _loadSyncState(account.id, 'Email');
      if (globalState != null) {
        storedMailboxState = globalState;
        await _saveSyncState(account.id, mailboxResourceType, globalState);
      }
    }

    final model.SyncEmailsResult result;
    if (storedMailboxState == null) {
      log('JMAP-sync: full sync mailbox=$mailboxJmapId (no stored state)');
      result = await _jmapFullEmailSync(account.id, jmap, mailboxJmapId);
    } else {
      log(
        'JMAP-sync: incremental sync mailbox=$mailboxJmapId '
        'sinceState=$storedMailboxState',
      );
      result = await _jmapIncrementalEmailSync(
        account.id,
        jmap,
        storedMailboxState,
        mailboxJmapId: mailboxJmapId,
      );
    }

    // Defence-in-depth: periodically diff the local cache against a bare
    // Email/query to catch server-side edge cases where Email/changes
    // under-reports deletions (see #262). Cheap: ids only, no bodies.
    await _maybeReconcileJmapMailbox(account.id, jmap, mailboxJmapId);
    return result;
  }

  Future<model.SyncEmailsResult> _jmapFullEmailSync(
    String accountId,
    JmapClient jmap,
    String mailboxJmapId,
  ) async {
    int position = 0;
    String? firstState;
    var fetched = 0;
    var bytes = 0;
    final seenIds = <String>{};

    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'sort': [
              {'property': 'receivedAt', 'isAscending': false},
            ],
            'limit': _jmapPageSize,
            'position': position,
            'calculateTotal': true,
          },
          '0',
        ],
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            '#ids': {'resultOf': '0', 'name': 'Email/query', 'path': '/ids'},
            'properties': _emailProperties,
            ..._emailGetBodyOptions,
          },
          '1',
        ],
      ]);

      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = queryResult['ids'] as List<dynamic>;
      final total = queryResult['total'] as int?;
      seenIds.addAll(ids.cast<String>());

      final getResult = _responseArgs(responses, 1, 'Email/get');
      firstState ??= getResult['state'] as String;
      final list = getResult['list'] as List<dynamic>;
      bytes += await _upsertJmapEmails(
        accountId,
        list,
        currentMailboxJmapId: mailboxJmapId,
      );
      fetched += list.length;

      position += ids.length;
      if (ids.isEmpty || total == null || position >= total) break;
    }

    final pruned = await _pruneJmapMailboxToServerIds(
      accountId,
      mailboxJmapId,
      seenIds,
    );
    log(
      'JMAP-sync: full mailbox=$mailboxJmapId fetched=$fetched pruned=$pruned '
      'newState=$firstState',
    );

    await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', firstState);
    // Record that we've just done an exhaustive reconciliation so the periodic
    // pass in _maybeReconcileJmapMailbox doesn't repeat it immediately.
    await _saveSyncState(
      accountId,
      'JMAP:Reconcile:$mailboxJmapId',
      DateTime.now().toIso8601String(),
    );
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

  Future<model.SyncEmailsResult> _jmapIncrementalEmailSync(
    String accountId,
    JmapClient jmap,
    String sinceState, {
    String? mailboxJmapId,
  }) async {
    final responses = await jmap.call([
      [
        'Email/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ],
    ]);

    // RFC 8620 §5.2: when the server can no longer resolve the sinceState
    // token (e.g. GC after long inactivity) it returns an error method
    // response with type=cannotCalculateChanges. Recover by discarding the
    // stored state and falling through to a full sync, which also runs a
    // deletion reconciliation.
    final triple = responses[0] as List<dynamic>;
    if (triple[0] == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      final type = err['type'] as String?;
      log(
        'JMAP-sync: Email/changes error type=$type mailbox=$mailboxJmapId '
        'sinceState=$sinceState — falling back to full sync',
      );
      if (type == 'cannotCalculateChanges') {
        await _clearJmapSyncState(accountId, mailboxJmapId);
        if (mailboxJmapId != null) {
          return _jmapFullEmailSync(accountId, jmap, mailboxJmapId);
        }
      }
      throw JmapException('Email/changes error: $type');
    }

    final changes = triple[1] as Map<String, dynamic>;
    final newState = changes['newState'] as String;
    final created = List<String>.from(changes['created'] as List? ?? []);
    final updated = List<String>.from(changes['updated'] as List? ?? []);
    final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);

    log(
      'JMAP-sync: incremental mailbox=$mailboxJmapId '
      '$sinceState → $newState '
      'created=${_briefIds(created)} '
      'updated=${_briefIds(updated)} '
      'destroyed=${_briefIds(destroyed)}',
    );

    var fetched = 0;
    var bytes = 0;
    final toFetch = [...created, ...updated];
    if (toFetch.isNotEmpty) {
      final getResponses = await jmap.call([
        [
          'Email/get',
          {
            'accountId': jmap.accountId,
            'ids': toFetch,
            'properties': _emailProperties,
            ..._emailGetBodyOptions,
          },
          '1',
        ],
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Email/get');
      final list = getResult['list'] as List<dynamic>;
      bytes += await _upsertJmapEmails(
        accountId,
        list,
        currentMailboxJmapId: mailboxJmapId,
      );
      fetched += list.length;

      // Any id we asked to fetch but did not receive back is treated by the
      // server as gone (RFC 8620 §5.1 notFound); clean it up so stale rows
      // don't linger.
      final returnedIds = <String>{
        for (final e in list) (e as Map<String, dynamic>)['id'] as String,
      };
      for (final jmapId in toFetch) {
        if (!returnedIds.contains(jmapId)) {
          await _deleteJmapEmailById(accountId, jmapId);
        }
      }
    }

    for (final jmapId in destroyed) {
      await _deleteJmapEmailById(accountId, jmapId);
    }

    await _saveSyncState(accountId, 'Email', newState);
    if (mailboxJmapId != null) {
      await _saveSyncState(accountId, 'JMAP:Email:$mailboxJmapId', newState);
    }
    return model.SyncEmailsResult(
      fetched: fetched,
      skipped: 0,
      bytesTransferred: bytes,
    );
  }

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
    await (_db.delete(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.resourceType.equals('Email') |
                    t.resourceType.like('JMAP:Email:%')),
          ))
        .go();
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

    final inFlightIds = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.changeType.isIn(
                  const ['move', 'snooze', 'unsnooze'],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    final inFlightSet = inFlightIds.toSet();

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
    if (last != null) {
      final lastAt = DateTime.tryParse(last);
      if (lastAt != null &&
          DateTime.now().difference(lastAt) < _jmapReconcileInterval) {
        return;
      }
    }

    final serverIds = <String>{};
    int position = 0;
    while (true) {
      final responses = await jmap.call([
        [
          'Email/query',
          {
            'accountId': jmap.accountId,
            'filter': {'inMailbox': mailboxJmapId},
            'limit': _jmapPageSize,
            'position': position,
            'calculateTotal': true,
          },
          '0',
        ],
      ]);
      final queryResult = _responseArgs(responses, 0, 'Email/query');
      final ids = List<String>.from(queryResult['ids'] as List);
      final total = queryResult['total'] as int?;
      serverIds.addAll(ids);
      position += ids.length;
      if (ids.isEmpty || total == null || position >= total) break;
    }

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
    await _reconcileJmapFlagsForMailbox(
      accountId,
      jmap,
      mailboxJmapId,
      serverIds,
    );
    await _sweepOrphanThreads(accountId, mailboxJmapId);
    await _saveSyncState(accountId, key, DateTime.now().toIso8601String());
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

    final inFlightIds = await (_db.selectOnly(_db.pendingChanges)
          ..addColumns([_db.pendingChanges.resourceId])
          ..where(
            _db.pendingChanges.accountId.equals(accountId) &
                _db.pendingChanges.changeType.isIn(
                  const [
                    'flag_seen',
                    'flag_flagged',
                    'move',
                    'snooze',
                    'unsnooze',
                    'delete',
                  ],
                ),
          ))
        .map((row) => row.read(_db.pendingChanges.resourceId)!)
        .get();
    final inFlightSet = inFlightIds.toSet();

    final toCheck = [
      for (final jmapId in localByJmapId.keys)
        if (serverIds.contains(jmapId) &&
            !inFlightSet.contains(localByJmapId[jmapId]!.id))
          jmapId,
    ];
    if (toCheck.isEmpty) return;

    final affectedThreads = <String>{};
    var corrected = 0;
    for (var offset = 0; offset < toCheck.length; offset += _jmapPageSize) {
      final batch = toCheck.sublist(
        offset,
        math.min(offset + _jmapPageSize, toCheck.length),
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
        final jmapId = m['id'] as String;
        final row = localByJmapId[jmapId];
        if (row == null) continue;
        final keywords = (m['keywords'] as Map<String, dynamic>?) ?? {};
        final serverSeen = keywords.containsKey(r'$seen');
        final serverFlagged = keywords.containsKey(r'$flagged');
        if (serverSeen == row.isSeen && serverFlagged == row.isFlagged) {
          continue;
        }
        await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
          EmailsCompanion(
            isSeen: Value(serverSeen),
            isFlagged: Value(serverFlagged),
          ),
        );
        affectedThreads.add(row.threadId ?? row.id);
        corrected++;
      }
    }

    for (final tid in affectedThreads) {
      await _updateThread(accountId, mailboxJmapId, tid);
    }
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
  }) async {
    var bytes = 0;
    final affectedByMailbox = <String, Set<String>>{};
    // (mailboxPath, realEmailId, messageId) of each row we just wrote — checked
    // afterwards for a local self-sent "virtual" counterpart to dissolve (#545).
    final dissolveCandidates = <(String, String, String?)>[];
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
              preview: Value(m['preview'] as String?),
              isSeen: Value(keywords.containsKey(r'$seen')),
              isFlagged: Value(keywords.containsKey(r'$flagged')),
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

  /// Records a failure for [row]: increments attempt count and stores the
  /// error message. When attempts reach [_maxChangeAttempts] the row is
  /// deleted instead — the change is permanently abandoned.
  Future<void> _recordChangeError(PendingChangeRow row, Object error) async {
    final next = row.attempts + 1;
    if (next >= _maxChangeAttempts) {
      await (_db.delete(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .go();
    } else {
      await (_db.update(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .write(
        PendingChangesCompanion(
          attempts: Value(next),
          lastError: Value(error.toString()),
        ),
      );
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

  Future<String?> _loadLatestJmapState(String accountId) async {
    final rows = await (_db.select(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.resourceType.equals('Email') |
                    t.resourceType.like('JMAP:Email:%')),
          ))
        .get();
    if (rows.isEmpty) return null;
    rows.sort((a, b) => b.syncedAt.compareTo(a.syncedAt));
    return rows.first.state;
  }

  Future<void> _updateAllJmapStates(String accountId, String newState) async {
    await (_db.update(_db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                (t.resourceType.equals('Email') |
                    t.resourceType.like('JMAP:Email:%')),
          ))
        .write(
      SyncStatesCompanion(
        state: Value(newState),
        syncedAt: Value(DateTime.now()),
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
  /// types, keep the stream open (we enforce our own 25-min cap below), and
  /// ask for a 30 s keep-alive ping to survive NAT/proxy idle timeouts.
  static String _expandEventSourceUrl(String template) {
    return template
        .replaceAll('{types}', '*')
        .replaceAll('{closeafter}', 'no')
        .replaceAll('{ping}', '30');
  }

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
            .timeout(const Duration(minutes: 25))
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
                'JMAP push stream ended (server closed connection '
                'or 25-min cap reached)',
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
  Future<void> setFlag(String emailId, {bool? seen, bool? flagged}) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingleOrNull();
    if (row == null) return;
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
  Future<void> _moveRow(Email row, String destMailboxPath) async {
    if (row.mailboxPath == destMailboxPath) return;
    final emailId = row.id;
    final account = (await _accounts.getAccount(row.accountId))!;

    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        emailId,
        'move',
        jsonEncode({'src': row.mailboxPath, 'dest': destMailboxPath}),
      );
      // Optimistic: move the cached row so it disappears from the current
      // mailbox immediately and is visible in the destination mailbox.
      await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
        EmailsCompanion(mailboxPath: Value(destMailboxPath)),
      );
      await _reconcileSourceThreads(
        row.accountId,
        row.mailboxPath,
        emailId,
        row.threadId ?? emailId,
      );
      await _updateThread(
        row.accountId,
        destMailboxPath,
        row.threadId ?? emailId,
      );
      return;
    }

    await _enqueueChange(
      account.id,
      emailId,
      'move',
      jsonEncode({
        'uid': row.uid,
        'mailboxPath': row.mailboxPath,
        'dest': destMailboxPath,
      }),
    );
    // Optimistic: move the cached row locally instead of hard-deleting.
    await (_db.update(_db.emails)..where((t) => t.id.equals(emailId))).write(
      EmailsCompanion(
        mailboxPath: Value(destMailboxPath),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );
    await _reconcileSourceThreads(
      row.accountId,
      row.mailboxPath,
      emailId,
      row.threadId ?? emailId,
    );
    await _updateThread(
      row.accountId,
      destMailboxPath,
      row.threadId ?? emailId,
    );
    // Destination UID will be updated when synced (IMAP move is a delete + copy).
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

  /// Deletes a single [row] on its own account: moves it to that account's
  /// Trash when one exists (so the user can recover it), otherwise hard-deletes.
  /// Returns the Trash path when moved, or null when hard-deleted. Does not
  /// mirror to counterpart accounts (see [_mirrorDeleteToCounterparts]).
  Future<String?> _deleteRow(Email row) async {
    final emailId = row.id;
    final account = (await _accounts.getAccount(row.accountId))!;

    // Move to Trash when possible so the user can recover the message.
    final trashRow = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('trash'),
          )
          ..limit(1))
        .getSingleOrNull();

    if (trashRow != null && trashRow.path != row.mailboxPath) {
      await _moveRow(row, trashRow.path);
      return trashRow.path;
    }

    // Already in Trash or no Trash folder — hard delete.
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

  Future<void> _enqueueChange(
    String accountId,
    String resourceId,
    String changeType,
    String payload,
  ) async {
    // Local self-sent "virtual" messages have no server counterpart yet, so an
    // outbound mutation would be rejected (`notFound`) and evicted. The state
    // is instead applied locally and carried over to the real message when it
    // arrives (see [_maybeDissolveLocalMessage]). Skip queuing here (#545).
    if (await _isLocalEmail(resourceId)) return;
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
    _changeCtrl.add(accountId);
  }

  /// Whether [emailId] refers to a local self-sent "virtual" row (#545).
  Future<bool> _isLocalEmail(String emailId) async {
    final row = await (_db.selectOnly(_db.emails)
          ..addColumns([_db.emails.isLocal])
          ..where(_db.emails.id.equals(emailId))
          ..limit(1))
        .getSingleOrNull();
    return row?.read(_db.emails.isLocal) ?? false;
  }

  @override
  Future<bool> cancelPendingChange(String emailId, String changeType) async {
    // Find the latest pending change for this email/type that hasn't been
    // attempted yet.
    final query = _db.select(_db.pendingChanges)
      ..where(
        (t) =>
            t.resourceId.equals(emailId) &
            t.changeType.equals(changeType) &
            t.attempts.equals(0),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.id)])
      ..limit(1);

    final row = await query.getSingleOrNull();
    if (row != null) {
      final count = await (_db.delete(
        _db.pendingChanges,
      )..where((t) => t.id.equals(row.id)))
          .go();
      return count > 0;
    }
    return false;
  }

  @override
  Future<void> snoozeEmail(String emailId, DateTime until) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId)))
        .getSingle();
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

    // Find or create Snoozed mailbox.
    var snoozedMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    snoozedMailbox ??= await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.name.equals('Snoozed'),
          )
          ..limit(1))
        .getSingleOrNull();

    // Default path if not found; flush logic will attempt to create it.
    final destPath = snoozedMailbox?.path ?? 'Snoozed';

    // Optimistic local update.
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(destPath),
        snoozedUntil: Value(until),
        snoozedFromMailboxPath: Value(row.mailboxPath),
      ),
    );

    await _enqueueChange(
      accountId,
      row.id,
      'snooze',
      jsonEncode({
        'uid': row.uid,
        'src': row.mailboxPath,
        'dest': destPath,
        'until': until.toIso8601String(),
      }),
    );

    await _updateThread(accountId, row.mailboxPath, row.threadId ?? row.id);
    await _updateThread(accountId, destPath, row.threadId ?? row.id);
  }

  @override
  Future<int> wakeUpEmails(String accountId) async {
    final now = DateTime.now();
    final expired = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.snoozedUntil.isSmallerOrEqualValue(now),
          ))
        .get();

    if (expired.isEmpty) return 0;

    for (final row in expired) {
      await _unsnoozeRow(row);
      await _mirrorSnoozeToCounterparts(
        row.accountId,
        row.messageId,
        until: null,
      );
    }
    return expired.length;
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
      jsonEncode({'uid': row.uid, 'src': row.mailboxPath, 'dest': dest}),
    );

    // Optimistic local update.
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      EmailsCompanion(
        mailboxPath: Value(dest),
        snoozedUntil: const Value(null),
        snoozedFromMailboxPath: const Value(null),
      ),
    );

    await _updateThread(accountId, row.mailboxPath, row.threadId ?? row.id);
    await _updateThread(accountId, dest, row.threadId ?? row.id);
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

  Future<void> _maybeDissolveLocalMessage(
    String accountId,
    String arrivalMailboxPath,
    String realEmailId,
    String? messageId,
  ) async {
    final mid = normaliseMessageId(messageId);
    if (mid == null) return;

    // Never dissolve against the Sent copy we append after sending — the
    // virtual message lives in the inbox and should merge with the inbox
    // arrival, which carries the user's intended folder.
    if (await _mailboxRole(accountId, arrivalMailboxPath) == 'sent') return;

    final local = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.isLocal.equals(true) &
                (t.messageId.equals(mid) | t.messageId.equals('<$mid>')),
          )
          ..limit(1))
        .getSingleOrNull();
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
  /// whose source destination had the given [role] / [name]. Prefers a role
  /// match (roles are protocol-independent); falls back to a case-insensitive
  /// name match for role-less custom folders. Returns null when the counterpart
  /// has no equivalent mailbox.
  Future<String?> _resolveCounterpartMailboxPath(
    String accountId, {
    required String? role,
    required String name,
  }) async {
    final mailboxes = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    if (role != null) {
      for (final m in mailboxes) {
        if (m.role == role) return m.path;
      }
    }
    final lowerName = name.toLowerCase();
    for (final m in mailboxes) {
      if (m.name.toLowerCase() == lowerName) return m.path;
    }
    return null;
  }

  @override
  @override
  Future<model.Email?> findEmailByMessageId(
    String accountId,
    String messageId,
  ) async {
    final row = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) & t.messageId.equals(messageId),
          )
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

    final inboxEmails = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(inboxPath) &
                t.messageId.isNotNull(),
          ))
        .get();

    final account = (await _accounts.getAccount(accountId))!;
    final interpreter = SieveInterpreter();
    var matched = 0;

    for (final row in inboxEmails) {
      final msgId = row.messageId!;
      if (skipAlreadyApplied && appliedIds.contains(msgId)) continue;

      final emailCtx = _buildSieveContext(row);

      SieveExecutionContext result;
      try {
        result = interpreter.execute(rules, emailCtx);
      } catch (e) {
        log('Sieve interpreter error for message $msgId: $e');
        if (enqueueActions) await _markSieveApplied(accountId, msgId);
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

      await _markSieveApplied(accountId, msgId);

      if (result.isCancelled) {
        await _enqueueSieveDelete(account, row);
      } else if (result.targetFolders.isNotEmpty) {
        final dest = result.targetFolders.first;
        await _enqueueSieveMove(account, row, dest);
      } else if (result.flagsToAdd.isNotEmpty) {
        await _enqueueSieveFlagSeen(account, row);
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
      );
    } else {
      await _enqueueChange(
        account.id,
        row.id,
        'delete',
        jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
      );
    }
    await (_db.delete(_db.emails)..where((t) => t.id.equals(row.id))).go();
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  Future<void> _enqueueSieveFlagSeen(
    account_model.Account account,
    Email row,
  ) async {
    if (account.type == account_model.AccountType.jmap) {
      await _enqueueChange(
        account.id,
        row.id,
        'flag_seen',
        jsonEncode({'seen': true}),
      );
    } else {
      await _enqueueChange(
        account.id,
        row.id,
        'flag_seen',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'seen': true,
        }),
      );
    }
    await (_db.update(_db.emails)..where((t) => t.id.equals(row.id))).write(
      const EmailsCompanion(isSeen: Value(true)),
    );
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Drains pending changes for [accountId] via the appropriate protocol.
  /// Called at the start of each sync cycle. Returns count of applied changes.
  @override
  Future<int> flushPendingChanges(String accountId, String password) async {
    final rows = await (_db.select(_db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.isEmpty) return 0;

    final account = (await _accounts.getAccount(accountId))!;
    switch (account.type) {
      case account_model.AccountType.imap:
        return _flushPendingChangesImap(account, password, rows);
      case account_model.AccountType.jmap:
        return _flushPendingChangesJmap(account, password, rows);
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

    final ifInState = await _loadSyncState(account.id, 'Email') ??
        await _loadLatestJmapState(account.id);
    var applied = 0;

    for (final row in rows) {
      try {
        final newState = await _applyPendingChangeJmap(
          jmap,
          row,
          ifInState: ifInState,
        );
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.id.equals(row.id)))
            .go();
        applied++;
        // Keep our checkpoint in sync with whatever the server returned.
        if (newState != null) {
          await _saveSyncState(account.id, 'Email', newState);
          await _updateAllJmapStates(account.id, newState);
        }
      } on JmapStateMismatchException {
        // Server rejected the mutation because our state token is stale.
        // Drop the cached state so the next sync cycle does a full re-fetch,
        // after which this change will be retried with a fresh token.
        await (_db.delete(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(account.id) &
                    (t.resourceType.equals('Email') |
                        t.resourceType.like('JMAP:Email:%')),
              ))
            .go();
        await _recordChangeError(
          row,
          'stateMismatch — will retry after re-sync',
        );
        // State is now stale for all remaining rows too; stop processing.
        break;
      } on JmapSetItemException catch (e) {
        // Permanent per-item rejection (e.g. notFound, forbidden) — discard
        // the change so the queue doesn't grow unboundedly.
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.id.equals(row.id)))
            .go();
        log('JMAP permanent error for change ${row.id}: $e');
      } catch (e) {
        await _recordChangeError(row, e);
      }
    }
    return applied;
  }

  Future<int> _flushPendingChangesImap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    imap.ImapClient? client;
    try {
      client = await _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      );
    } catch (e) {
      // Connection-level failure — bump all rows, they'll retry next cycle.
      for (final row in rows) {
        await _recordChangeError(row, e);
      }
      return 0;
    }
    var applied = 0;
    try {
      for (final row in rows) {
        try {
          await _applyPendingChangeImap(client, row);
          await (_db.delete(
            _db.pendingChanges,
          )..where((t) => t.id.equals(row.id)))
              .go();
          applied++;
        } catch (e) {
          if (isImapMailboxNotFound(e)) {
            // Email already gone on the server — treat as success so the
            // pending change doesn't accumulate or block future changes.
            await (_db.delete(
              _db.pendingChanges,
            )..where((t) => t.id.equals(row.id)))
                .go();
            applied++;
            log('IMAP change ${row.id} skipped: message already gone ($e)');
          } else {
            await _recordChangeError(row, e);
          }
        }
      }
    } finally {
      await client.logout();
    }
    return applied;
  }

  Future<void> _applyPendingChangeImap(
    imap.ImapClient client,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    final uid = payload['uid'] as int;
    // snooze/unsnooze payloads use 'src' for the source folder; all others use 'mailboxPath'.
    final mailboxPath = (payload['mailboxPath'] ?? payload['src']) as String;
    final seq = imap.MessageSequence.fromId(uid, isUid: true);
    await client.selectMailboxByPath(mailboxPath);

    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        seen ? await client.uidMarkSeen(seq) : await client.uidMarkUnseen(seq);
      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        flagged
            ? await client.uidMarkFlagged(seq)
            : await client.uidMarkUnflagged(seq);
      case 'move':
        final dest = payload['dest'] as String;
        final result = await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: result,
        );
      case 'delete':
        await client.uidMarkDeleted(seq);
        await client.uidExpunge(seq);
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
        await client.uidStore(seq, [keyword], action: imap.StoreAction.add);
        final snoozeResult = await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: snoozeResult,
        );
      case 'unsnooze':
        final dest = payload['dest'] as String;
        try {
          await client.createMailbox(dest);
        } catch (_) {}
        // Remove any existing snooze flags.
        final fetch = await client.uidFetchMessages(seq, 'FLAGS');
        if (fetch.messages.isNotEmpty) {
          final flags = fetch.messages.first.flags ?? [];
          final snzFlags = flags.where((f) => f.startsWith('snz:')).toList();
          if (snzFlags.isNotEmpty) {
            await client.uidStore(
              seq,
              snzFlags,
              action: imap.StoreAction.remove,
            );
          }
        }
        final unsnoozeResult =
            await client.uidMove(seq, targetMailboxPath: dest);
        await _remapEmailAfterImapMove(
          client,
          oldId: row.resourceId,
          sourceUid: uid,
          destMailboxPath: dest,
          moveResult: unsnoozeResult,
        );
    }
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
  Future<void> _remapEmailAfterImapMove(
    imap.ImapClient client, {
    required String oldId,
    required int sourceUid,
    required String destMailboxPath,
    required imap.GenericImapResult moveResult,
  }) async {
    final row = await (_db.select(_db.emails)..where((t) => t.id.equals(oldId)))
        .getSingleOrNull();
    if (row == null) return;

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
      return;
    }

    final newId = '${row.accountId}:$destMailboxPath:$newUid';
    if (newId == oldId) return;

    await _db.transaction(() async {
      await _db.customStatement('PRAGMA defer_foreign_keys = ON');

      await _db.customStatement(
        'UPDATE email_bodies SET email_id = ?1 WHERE email_id = ?2',
        [newId, oldId],
      );

      await (_db.update(_db.emails)..where((t) => t.id.equals(oldId))).write(
        EmailsCompanion(
          id: Value(newId),
          uid: Value(newUid),
          mailboxPath: Value(destMailboxPath),
        ),
      );

      await (_db.update(_db.pendingChanges)
            ..where((t) => t.resourceId.equals(oldId)))
          .write(PendingChangesCompanion(resourceId: Value(newId)));

      // threads.latest_email_id is a plain equality match; threads.email_ids_json
      // is a JSON array of email IDs — both are safe to update via REPLACE()
      // because email IDs are unique opaque strings.
      await _db.customStatement(
        'UPDATE threads SET latest_email_id = ?1 '
        'WHERE latest_email_id = ?2',
        [newId, oldId],
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

    // Rebuild thread aggregates in both mailboxes from the now-updated emails.
    final threadId = row.threadId ?? newId;
    await _updateThread(row.accountId, row.mailboxPath, threadId);
    await _updateThread(row.accountId, destMailboxPath, threadId);
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
  Future<int?> _searchUidByMessageId(
    imap.ImapClient client,
    String mailboxPath,
    String? messageId,
  ) async {
    if (messageId == null || messageId.isEmpty) return null;
    try {
      await client.selectMailboxByPath(mailboxPath);
      // RFC 3501 SEARCH HEADER uses an astring for the value; quoting is safe
      // for typical Message-ID syntax (no embedded quotes or backslashes).
      final escaped = messageId.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      final result = await client.uidSearchMessages(
        searchCriteria: 'HEADER Message-ID "$escaped"',
      );
      final uids = result.matchingSequence?.toList() ?? const <int>[];
      if (uids.isEmpty) return null;
      return uids.reduce((a, b) => a > b ? a : b);
    } catch (e) {
      log('_searchUidByMessageId failed for $messageId in $mailboxPath: $e');
      return null;
    }
  }

  /// Applies a single pending change to the JMAP server.
  ///
  /// Returns the `newState` from the server's `Email/set` response so the
  /// caller can keep the local checkpoint in sync.
  ///
  /// Throws [JmapStateMismatchException] when the server rejects the request
  /// because [ifInState] is stale (RFC 8620 §5.3 `stateMismatch`).
  Future<String?> _applyPendingChangeJmap(
    JmapClient jmap,
    PendingChangeRow row, {
    String? ifInState,
  }) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    // Extract the JMAP email ID from the DB id (format: "accountId:jmapId").
    final jmapEmailId = row.resourceId.contains(':')
        ? row.resourceId.substring(row.resourceId.indexOf(':') + 1)
        : row.resourceId;

    Map<String, dynamic> setArgs(Map<String, dynamic> extra) => {
          'accountId': jmap.accountId,
          if (ifInState != null) 'ifInState': ifInState,
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

      case 'move':
        final destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  'mailboxIds/$destMailboxId': true,
                  'mailboxIds/$srcMailboxId': null,
                },
              },
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
        final srcMailboxId = payload['src'] as String;
        // When the Snoozed folder didn't exist at enqueue time, 'dest' holds
        // the literal name 'Snoozed' rather than a JMAP mailbox ID.  Create it.
        if (destMailboxId == 'Snoozed') {
          final createResps = await jmap.call([
            [
              'Mailbox/set',
              {
                'accountId': jmap.accountId,
                'create': {
                  'new-snoozed': {'name': 'Snoozed', 'role': 'snoozed'},
                },
              },
              '0',
            ],
          ]);
          final createResult = _responseArgs(createResps, 0, 'Mailbox/set');
          final created = createResult['created'] as Map<String, dynamic>?;
          final newId = (created?['new-snoozed']
              as Map<String, dynamic>?)?['id'] as String?;
          if (newId != null) destMailboxId = newId;
        }
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  'keywords/$keyword': true,
                  'mailboxIds/$destMailboxId': true,
                  'mailboxIds/$srcMailboxId': null,
                },
              },
            }),
            '0',
          ],
        ]);

      case 'unsnooze':
        final destMailboxId = payload['dest'] as String;
        final srcMailboxId = payload['src'] as String;
        // Fetch current keywords to identify which snz: keywords to remove.
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
        final toRemove = keywords.keys.where(
          (k) => k.toString().startsWith('snz:'),
        );

        final update = {
          'mailboxIds/$destMailboxId': true,
          'mailboxIds/$srcMailboxId': null,
        };
        for (final k in toRemove) {
          update['keywords/$k'] = null;
        }

        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      default:
        return null;
    }

    final result = _responseArgs(responses, 0, 'Email/set');

    // stateMismatch is returned as a top-level error in the Email/set response
    // (not the per-method error handled by _responseArgs).
    if (result['type'] == 'stateMismatch') {
      throw const JmapStateMismatchException();
    }

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

    return result['newState'] as String?;
  }

  @override
  Future<void> sendEmail(String accountId, model.EmailDraft draft) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        await _sendEmailImap(account, password, draft);
      case account_model.AccountType.jmap:
        await _sendEmailJmap(account, password, draft);
    }
  }

  @override
  Future<int> enqueueSend(String accountId, model.EmailDraft draft) async {
    // Stamp a deterministic Message-ID so a self-send's immediately-created
    // local message and the real message that arrives later share the same id
    // (#545). enough_mail would otherwise generate a random one at send time.
    final host = draft.from.email.contains('@')
        ? draft.from.email.split('@').last
        : 'localhost';
    final stampedDraft = draft.messageId != null
        ? draft
        : draft.copyWith(messageId: imap.MessageBuilder.createMessageId(host));
    final rowId = await _outbox.enqueue(accountId, stampedDraft);
    await _createLocalSelfMessages(accountId, stampedDraft);
    return rowId;
  }

  /// Marker inserted into a local (virtual) email row's `id` so it never
  /// collides with a real server row id (`accountId:mailboxPath:uid` for IMAP
  /// or `accountId:jmapId` for JMAP).
  static const _localIdMarker = '__local__';

  /// For every configured account whose address is among [draft]'s recipients,
  /// insert a local "virtual" copy of the message into that account's inbox so
  /// it shows up immediately for note-taking (#545). Dissolved into the real
  /// message by [_maybeDissolveLocalMessage] once it arrives via sync.
  Future<void> _createLocalSelfMessages(
    String accountId,
    model.EmailDraft draft,
  ) async {
    final mid = normaliseMessageId(draft.messageId);
    if (mid == null) return;
    final recipients = <String>{
      for (final a in draft.to) a.email.toLowerCase().trim(),
      for (final a in draft.cc) a.email.toLowerCase().trim(),
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

      await _db.into(_db.emails).insertOnConflictUpdate(
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
          );
      await _db.into(_db.emailBodies).insertOnConflictUpdate(
            EmailBodiesCompanion.insert(
              emailId: emailId,
              textBody: Value(body),
              cachedAt: Value(now),
              bodySize: Value(_bodySize(body, null)),
            ),
          );
      await _updateThread(account.id, inbox.path, threadId);
    }
  }

  String _encodeModelAddresses(List<model.EmailAddress> addresses) =>
      jsonEncode(
        addresses.map((a) => {'name': a.name, 'email': a.email}).toList(),
      );

  @override
  Future<int> flushOutbox(String accountId, String password) async {
    final account = (await _accounts.getAccount(accountId))!;
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
        try {
          switch (account.type) {
            case account_model.AccountType.imap:
              await _sendEmailImap(account, password, job.draft);
            case account_model.AccountType.jmap:
              await _sendEmailJmap(account, password, job.draft);
          }
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
        }
      },
      observer: _outboxLogObserver(accountId),
    );
  }

  // Mirrors every outbox row outcome into the application log so a user who
  // hits Retry on a queued message actually sees why it did or did not send
  // (previously the failure was only stored in `outbox.lastError` and the
  // log stayed silent — see #323).
  OutboxFlushObserver? _outboxLogObserver(String accountId) {
    final logger = _appLogger;
    if (logger == null) return null;
    String describe(OutboxJob job) {
      final subject = job.draft.subject.isEmpty
          ? '(no subject)'
          : (job.draft.subject.length > 60
              ? '${job.draft.subject.substring(0, 60)}…'
              : job.draft.subject);
      final recipients = job.draft.to.length + job.draft.cc.length;
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
        unawaited(
          logger.info(
            'outbox.send.ok',
            'Queued message ${describe(job)} sent',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
            },
          ),
        );
      },
      onTransient: (job, error, stack, nextAttemptAt) {
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
            },
            error: error,
            stack: stack,
          ),
        );
      },
      onPermanent: (job, error) {
        unawaited(
          logger.error(
            'outbox.send.permanent_error',
            'Send permanently failed for ${describe(job)}: ${error.message}',
            accountId: accountId,
            emailId: 'outbox:${job.id}',
            data: {
              'outboxRowId': job.id,
              'attempts': job.attempts + 1,
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
  ) async {
    final builder = imap.MessageBuilder()
      ..from = [imap.MailAddress(draft.from.name, draft.from.email)]
      ..to = draft.to.map((a) => imap.MailAddress(a.name, a.email)).toList()
      ..cc = draft.cc.map((a) => imap.MailAddress(a.name, a.email)).toList()
      ..subject = draft.subject
      ..messageId = draft.messageId
      ..text = draft.body;
    for (final filePath in draft.attachmentFilePaths) {
      final file = File(filePath);
      final mediaType = imap.MediaType.guessFromFileName(filePath);
      await builder.addFile(file, mediaType);
    }
    final mimeMessage = builder.buildMimeMessage();
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
    );
    try {
      await _withPhase(
        'SMTP send message',
        smtpEndpoint,
        () =>
            smtpClient.sendMessage(mimeMessage).timeout(_sendOperationTimeout),
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
    // Save a copy to the Sent folder via IMAP APPEND.
    // Create the folder first — many servers don't pre-create it.
    final imapClient = await _withPhase(
      'IMAP connect/login (to append Sent copy)',
      imapEndpoint,
      () => _imapConnect(
        account,
        _effectiveUsername(account),
        password,
      ).timeout(_sendOperationTimeout),
    );
    try {
      try {
        await imapClient.createMailbox('Sent').timeout(_sendOperationTimeout);
      } on TimeoutException catch (e) {
        throw _wrapPhaseError(
          'IMAP create Sent folder',
          imapEndpoint,
          e,
        );
      } catch (_) {
        // Already exists — that's fine.
      }
      await _withPhase(
        'IMAP append to Sent folder',
        imapEndpoint,
        () => imapClient.appendMessage(
          mimeMessage,
          targetMailboxPath: 'Sent',
          flags: [r'\Seen'],
          responseTimeout: _sendOperationTimeout,
        ),
      );
    } finally {
      // Logout is best-effort — bound it so a wedged server can't strand the
      // caller after the message is already appended to Sent.
      try {
        await imapClient.logout().timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Best-effort: the message is already saved to Sent.
      }
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
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on TimeoutException catch (e) {
      throw _wrapPhaseError(phase, endpoint, e);
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

  Future<void> _sendEmailJmap(
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

    // Look up the Sent mailbox JMAP ID from the local DB.
    final sentMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(account.id) & t.role.equals('sent'),
          )
          ..limit(1))
        .getSingleOrNull();
    final sentJmapId = sentMailbox?.path;

    // Build the email body.
    const bodyPartId = '1';
    final emailCreate = {
      'from': [
        {'name': draft.from.name, 'email': draft.from.email},
      ],
      'to': draft.to.map((a) => {'name': a.name, 'email': a.email}).toList(),
      if (draft.cc.isNotEmpty)
        'cc': draft.cc.map((a) => {'name': a.name, 'email': a.email}).toList(),
      'subject': draft.subject,
      // JMAP messageId is an array of bracket-less ids (RFC 8621 §4.1.2.3).
      if (draft.messageId != null)
        'messageId': [normaliseMessageId(draft.messageId)],
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
      ...draft.to.map((a) => {'email': a.email}),
      ...draft.cc.map((a) => {'email': a.email}),
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
    } catch (_) {
      await _destroyJmapEmail(jmap, emailId);
      rethrow;
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
    final dir = Directory(
      p.join(
        cacheDir.path,
        'sharedinbox',
        'attachments',
        emailId.replaceAll(':', '_'),
      ),
    );
    await dir.create(recursive: true);

    final file = File(p.join(dir.path, attachment.filename));
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
      await file.writeAsBytes(bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    }

    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.selectMailboxByPath(emailRow.mailboxPath);
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
      final part = msg.getPart(attachment.fetchPartId) ?? msg;
      final bytes = part.decodeContentBinary();
      if (bytes == null) {
        throw StateError('Failed to decode attachment ${attachment.filename}.');
      }
      await file.writeAsBytes(bytes);
      await _recordAttachmentFile(emailId, attachment.filename, file);
      return file.path;
    } finally {
      await client.logout();
    }
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
    await _db.into(_db.attachmentFiles).insertOnConflictUpdate(
          AttachmentFilesCompanion.insert(
            emailId: emailId,
            filename: filename,
            size: size,
            downloadedAt: DateTime.now(),
          ),
        );
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
      await client.selectMailboxByPath(emailRow.mailboxPath);
      final fetch = await client.uidFetchMessage(emailRow.uid, 'BODY.PEEK[]');
      final msg = fetch.messages.firstOrNull;
      if (msg == null) {
        throw StateError(
          'IMAP server returned no message for UID ${emailRow.uid}.',
        );
      }
      return msg.renderMessage();
    } finally {
      await client.logout();
    }
  }

  @override
  Future<List<model.Email>> searchEmailsGlobal(
    String? accountId,
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    final sql = accountId != null
        ? 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ? AND e.account_id = ?'
            ' ORDER BY e.is_flagged DESC, e.received_at DESC LIMIT 50'
        : 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
            ' WHERE email_fts MATCH ?'
            ' ORDER BY e.is_flagged DESC, e.received_at DESC LIMIT 50';
    final variables = accountId != null
        ? [Variable<String>(ftsQuery), Variable<String>(accountId)]
        : [Variable<String>(ftsQuery)];

    final queryRows = await _db
        .customSelect(sql, variables: variables, readsFrom: {_db.emails}).get();
    final emailRows = await Future.wait(
      queryRows.map((r) => _db.emails.mapFromRow(r)),
    );

    final noteRows = await _searchEmailsByNotes(accountId, null, query);
    final bodyRows = await _searchEmailsByBody(accountId, null, query);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...emailRows.map(_toModel), ...noteRows, ...bodyRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort((a, b) {
      if (a.isFlagged != b.isFlagged) return a.isFlagged ? -1 : 1;
      return b.receivedAt.compareTo(a.receivedAt);
    });
    return merged;
  }

  /// Returns emails whose plaintext body matches [query] via the
  /// `email_body_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByBody(
    String? accountId,
    String? mailboxPath,
    String query,
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
      );

  /// Returns emails whose associated notes match [query] via the
  /// `email_notes_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByNotes(
    String? accountId,
    String? mailboxPath,
    String query,
  ) =>
      _searchEmailsByFts(
        fromJoin: 'FROM email_notes_fts f'
            ' JOIN email_notes n ON n.rowid = f.rowid'
            ' JOIN emails e ON e.message_id = n.message_id'
            ' AND e.account_id = n.account_id',
        ftsTable: 'email_notes_fts',
        readsFrom: {_db.emails, _db.emailNotes},
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
      );

  /// Runs an FTS5 `MATCH` search whose hits resolve back to `emails` (aliased
  /// `e`) and returns them as models, flagged and newest first. [fromJoin] is
  /// the `FROM …` clause joining the [ftsTable] shadow index to `emails`;
  /// [ftsTable] is the virtual-table name used in the `MATCH` predicate.
  /// Optionally filtered by [accountId] and [mailboxPath]. Shared by the
  /// body and note search paths.
  Future<List<model.Email>> _searchEmailsByFts({
    required String fromJoin,
    required String ftsTable,
    required Set<ResultSetImplementation> readsFrom,
    required String? accountId,
    required String? mailboxPath,
    required String query,
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

    final sql = 'SELECT DISTINCT e.* $fromJoin'
        ' WHERE $ftsTable MATCH ?$extraConditions'
        ' ORDER BY e.is_flagged DESC, e.received_at DESC LIMIT 50';

    final rows = await _db
        .customSelect(
          sql,
          variables: [Variable<String>(ftsQuery), ...extraVars],
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
    FilterGroup filter,
  ) async {
    final rows = await (_db.select(_db.emails)
          ..where((t) {
            final fe = _filterGroup(filter, t);
            if (accountId == null) return fe;
            return t.accountId.equals(accountId) & fe;
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.receivedAt),
          ])
          ..limit(100))
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
      // Size is not stored in the local cache; skip silently.
      FilterField.size => const Constant(true),
      FilterField.header => _headerLike(leaf, t),
      FilterField.folder => _textLike(t.mailboxPath, leaf.comparison, val),
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
        _ => const Constant(true),
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
        _ => const Constant(true),
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
    if (pattern == null) return const Constant(true);
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
  /// Each whitespace-separated word becomes a prefix term (word*) so that
  /// partial words still match. Special FTS5 characters are stripped.
  static String _toFtsQuery(String query) {
    final words = query
        .trim()
        .split(RegExp(r'[^\w]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    return words.map((w) => '$w*').join(' ');
  }

  @override
  Future<List<model.Email>> getEmailsByAddress(
    String? accountId,
    String address,
  ) async {
    final pattern = '%${address.toLowerCase()}%';
    final rows = await (_db.select(_db.emails)
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
          ]))
        .get();
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
          ..orderBy([(t) => OrderingTerm.desc(t.receivedAt)])
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
    String query,
  ) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    const sql = 'SELECT e.* FROM email_fts f JOIN emails e ON e.rowid = f.rowid'
        ' WHERE email_fts MATCH ? AND e.account_id = ? AND e.mailbox_path = ?'
        ' ORDER BY e.is_flagged DESC, e.received_at DESC LIMIT 50';
    final variables = [
      Variable<String>(ftsQuery),
      Variable<String>(accountId),
      Variable<String>(mailboxPath),
    ];

    final queryRows = await _db
        .customSelect(sql, variables: variables, readsFrom: {_db.emails}).get();
    final emailRows = await Future.wait(
      queryRows.map((r) => _db.emails.mapFromRow(r)),
    );

    final noteRows = await _searchEmailsByNotes(accountId, mailboxPath, query);
    final bodyRows = await _searchEmailsByBody(accountId, mailboxPath, query);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...emailRows.map(_toModel), ...noteRows, ...bodyRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort((a, b) {
      if (a.isFlagged != b.isFlagged) return a.isFlagged ? -1 : 1;
      return b.receivedAt.compareTo(a.receivedAt);
    });
    return merged;
  }

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
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
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
                ),
              )
              .toList(),
        );
  }

  @override
  Future<void> discardMutation(int id) async {
    await (_db.delete(_db.pendingChanges)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<void> retryMutation(int id) async {
    await (_db.update(_db.pendingChanges)..where((t) => t.id.equals(id))).write(
      const PendingChangesCompanion(attempts: Value(0), lastError: Value(null)),
    );
  }

  @override
  Stream<List<model.PendingChange>> observePendingChanges(String accountId) {
    return (_db.select(_db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .watch()
        .map((rows) => rows.map(_toPendingChange).toList());
  }

  @override
  Stream<List<model.PendingChange>> observeAllPendingChanges() {
    return (_db.select(_db.pendingChanges)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
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
      );

  @override
  Future<void> clearForResync(String accountId) async {
    // Disable FK constraints so EmailBodies rows survive the emails deletion.
    // When emails are re-inserted after the next sync with the same IDs, the
    // cached body content will be reused without a network round-trip.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        await (_db.delete(
          _db.emails,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
        await (_db.delete(
          _db.pendingChanges,
        )..where((t) => t.accountId.equals(accountId)))
            .go();
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
    // cached body without a network round-trip.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        // Clear pending changes that target emails in this mailbox first —
        // they are keyed by resourceId, so this must run before the emails
        // themselves are deleted.
        final mailboxEmailIds = _db.selectOnly(_db.emails)
          ..addColumns([_db.emails.id])
          ..where(
            _db.emails.accountId.equals(accountId) &
                _db.emails.mailboxPath.equals(mailboxPath),
          );
        await (_db.delete(_db.pendingChanges)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.resourceType.equals('Email') &
                    t.resourceId.isInQuery(mailboxEmailIds),
              ))
            .go();

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
                        t.resourceType.equals('JMAP:Email:$mailboxPath')),
              ))
            .go();
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }
}

/// Derives a JMAP-style preview snippet from an IMAP [imap.MimeMessage].
/// Prefers the text/plain part; falls back to a tag-stripped text/html part.
String? _extractImapPreview(imap.MimeMessage msg) =>
    previewFromBody(msg.decodeTextPlainPart(), msg.decodeTextHtmlPart());

/// Recursively converts an [imap.MimePart] into a JSON-serialisable map.
Map<String, dynamic> _mimePartToJson(imap.MimePart part) {
  final ct = part.getHeaderContentType();
  final disposition = part.getHeaderContentDisposition();
  final rawEncoding =
      part.getHeader('content-transfer-encoding')?.firstOrNull?.value;
  final encoding = rawEncoding?.split(';').first.trim().toLowerCase();
  return {
    'contentType': ct?.mediaType.text ?? 'application/octet-stream',
    'filename': disposition?.filename ?? ct?.parameters['name'],
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
