part of '../email_repository_impl.dart';

// Derived state: the threads table, kept in step with the email rows it
// summarises.

// ── Helpers ────────────────────────────────────────────────────────────────

/// JMAP header fields like messageId/inReplyTo/references come as arrays.
/// We join them space-separated to match the IMAP convention.
String? _joinJmapStringList(List<dynamic>? list) {
  if (list == null || list.isEmpty) return null;
  final joined = list.cast<String>().join(' ');
  return joined.isEmpty ? null : joined;
}

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
String? _computeThreadId({
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

extension _Threads on EmailRepositoryImpl {
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

  /// Recalculates and updates the [Threads] table for [threadId]
  /// ([refreshThreadAggregate]). Called after any change to the [Emails]
  /// table. Never for `''`, the `mailbox_path` of a hidden row
  /// (SYNC-REDESIGN.md §2): a hidden row is in no folder, and its old
  /// folder's thread is refreshed instead.
  Future<void> _updateThread(
    String accountId,
    String mailboxPath,
    String threadId,
  ) =>
      refreshThreadAggregate(_db, accountId, mailboxPath, threadId);

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
}
