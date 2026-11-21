import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sharedinbox/data/db/database.dart';

/// Recalculates the [Threads] row of [threadId] in [mailboxPath] of
/// [accountId] from the email rows shown there (deleting it when none is
/// left). Shared by the email repository (`_updateThread`) and
/// `removeLocalMailbox`, whose failed moves put mails back in their source
/// folder. Never for `''`, the `mailbox_path` of a hidden row
/// (SYNC-REDESIGN.md §2): a hidden row is in no folder, and its old folder's
/// thread is refreshed instead.
Future<void> refreshThreadAggregate(
  AppDatabase db,
  String accountId,
  String mailboxPath,
  String threadId,
) async {
  if (mailboxPath.isEmpty) return;
  // Same key as `latestDate` below, so an undated message sorts by its
  // arrival time rather than first (SQLite orders NULL lowest). Same-second
  // mail by UID, so `latest` is the newest arrival.
  final indexed = await (db.select(db.emails)
        ..where(
          (t) =>
              t.accountId.equals(accountId) &
              t.mailboxPath.equals(mailboxPath) &
              t.threadId.equals(threadId),
        )
        ..orderBy([
          (t) => OrderingTerm.asc(coalesce([t.sentAt, t.receivedAt])),
          (t) => OrderingTerm.asc(t.receivedAt),
          (t) => OrderingTerm.asc(t.uid),
          (t) => OrderingTerm.asc(t.id),
        ]))
      .get();
  // The key is `threadId ?? id`, as every caller derives it: a row without
  // a thread id is the thread [threadId] when that is its id. A second
  // query (a primary-key lookup), so the one above keeps using the
  // `emails_thread_id` index; an `OR` in it scanned the folder.
  final idless = await (db.select(db.emails)
        ..where(
          (t) =>
              t.id.equals(threadId) &
              t.accountId.equals(accountId) &
              t.mailboxPath.equals(mailboxPath) &
              t.threadId.isNull(),
        ))
      .getSingleOrNull();
  final threadEmails =
      idless == null ? indexed : ([...indexed, idless]..sort(_threadOrder));

  if (threadEmails.isEmpty) {
    await (db.delete(db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(mailboxPath) &
                t.id.equals(threadId),
          ))
        .go();
    return;
  }

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

  await db.into(db.threads).insertOnConflictUpdate(
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

/// The order of [refreshThreadAggregate]'s query, for a row added to it.
int _threadOrder(Email a, Email b) {
  final byDate = (a.sentAt ?? a.receivedAt).compareTo(b.sentAt ?? b.receivedAt);
  if (byDate != 0) return byDate;
  final byArrival = a.receivedAt.compareTo(b.receivedAt);
  if (byArrival != 0) return byArrival;
  final byUid = a.uid.compareTo(b.uid);
  if (byUid != 0) return byUid;
  return a.id.compareTo(b.id);
}
