import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/data/db/database.dart' as db;

/// Coordinate identifying a single message the debug view should inspect.
class DebugMessageRef {
  const DebugMessageRef({
    required this.accountId,
    required this.mailboxPath,
    required this.emailId,
  });

  final String accountId;
  final String mailboxPath;
  final String emailId;
}

/// UI-agnostic snapshot of a message's local state — every column drift stores
/// for the message, its cached body, any pending outbound mutations, the
/// account's sync-state tokens, and the most recent sync log entry.
///
/// Assembled once in a background read and passed to the debug UI so the UI
/// file itself doesn't have to import `lib/data/db/*` (banned by the layer
/// check in `ci/main.go`).
class MessageDebugSnapshot {
  const MessageDebugSnapshot({
    required this.email,
    required this.body,
    required this.pending,
    required this.syncStates,
    required this.lastSyncLog,
    required this.attachments,
  });

  final MessageDebugEmail? email;
  final MessageDebugBody? body;
  final List<MessageDebugPending> pending;
  final List<MessageDebugSyncState> syncStates;
  final MessageDebugSyncLog? lastSyncLog;
  final List<EmailAttachment> attachments;
}

class MessageDebugEmail {
  const MessageDebugEmail({
    required this.id,
    required this.accountId,
    required this.mailboxPath,
    required this.uid,
    required this.subject,
    required this.sentAt,
    required this.receivedAt,
    required this.fromJson,
    required this.toAddresses,
    required this.ccJson,
    required this.preview,
    required this.isSeen,
    required this.isFlagged,
    required this.hasAttachment,
    required this.threadId,
    required this.messageId,
    required this.inReplyTo,
    required this.references,
    required this.snoozedUntil,
    required this.snoozedFromMailboxPath,
    required this.listUnsubscribeHeader,
  });

  final String id;
  final String accountId;
  final String mailboxPath;
  final int uid;
  final String? subject;
  final DateTime? sentAt;
  final DateTime receivedAt;
  final String fromJson;
  final String toAddresses;
  final String ccJson;
  final String? preview;
  final bool isSeen;
  final bool isFlagged;
  final bool hasAttachment;
  final String? threadId;
  final String? messageId;
  final String? inReplyTo;
  final String? references;
  final DateTime? snoozedUntil;
  final String? snoozedFromMailboxPath;
  final String? listUnsubscribeHeader;
}

class MessageDebugBody {
  const MessageDebugBody({
    required this.cachedAt,
    required this.textBodyLength,
    required this.htmlBodyLength,
  });

  final DateTime? cachedAt;
  final int textBodyLength;
  final int htmlBodyLength;
}

class MessageDebugPending {
  const MessageDebugPending({
    required this.changeType,
    required this.attempts,
    required this.createdAt,
    required this.lastError,
    required this.payload,
  });

  final String changeType;
  final int attempts;
  final DateTime createdAt;
  final String? lastError;
  final String payload;
}

class MessageDebugSyncState {
  const MessageDebugSyncState({
    required this.resourceType,
    required this.state,
    required this.syncedAt,
  });

  final String resourceType;
  final String state;
  final DateTime syncedAt;
}

class MessageDebugSyncLog {
  const MessageDebugSyncLog({
    required this.result,
    required this.startedAt,
    required this.finishedAt,
    required this.errorMessage,
  });

  final String result;
  final DateTime startedAt;
  final DateTime finishedAt;
  final String? errorMessage;
}

/// Reads every local-state artefact needed by the debug view in one pass.
///
/// Split from the UI file so the layer-check in `ci/main.go` (no
/// `package:sharedinbox/data/*` imports from `lib/ui/`) stays green.
Future<MessageDebugSnapshot> loadMessageDebugSnapshot(
  db.AppDatabase database,
  DebugMessageRef messageRef,
) async {
  final email = await (database.select(database.emails)
        ..where((t) => t.id.equals(messageRef.emailId)))
      .getSingleOrNull();
  final body = await (database.select(database.emailBodies)
        ..where((t) => t.emailId.equals(messageRef.emailId)))
      .getSingleOrNull();
  final pending = await (database.select(database.pendingChanges)
        ..where(
          (t) =>
              t.accountId.equals(messageRef.accountId) &
              t.resourceId.equals(messageRef.emailId),
        )
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
      .get();
  final syncStates = await (database.select(database.syncStates)
        ..where((t) => t.accountId.equals(messageRef.accountId)))
      .get();
  final lastSyncLog = await (database.select(database.syncLogs)
        ..where((t) => t.accountId.equals(messageRef.accountId))
        ..orderBy([(t) => OrderingTerm.desc(t.finishedAt)])
        ..limit(1))
      .getSingleOrNull();

  final attachments = <EmailAttachment>[];
  if (body != null) {
    try {
      attachments.addAll(_decodeAttachments(body.attachmentsJson));
    } catch (_) {
      // Malformed cache — leave attachments empty, still show the row above.
    }
  }

  return MessageDebugSnapshot(
    email: email == null
        ? null
        : MessageDebugEmail(
            id: email.id,
            accountId: email.accountId,
            mailboxPath: email.mailboxPath,
            uid: email.uid,
            subject: email.subject,
            sentAt: email.sentAt,
            receivedAt: email.receivedAt,
            fromJson: email.fromJson,
            toAddresses: email.toAddresses,
            ccJson: email.ccJson,
            preview: email.preview,
            isSeen: email.isSeen,
            isFlagged: email.isFlagged,
            hasAttachment: email.hasAttachment,
            threadId: email.threadId,
            messageId: email.messageId,
            inReplyTo: email.inReplyTo,
            references: email.references,
            snoozedUntil: email.snoozedUntil,
            snoozedFromMailboxPath: email.snoozedFromMailboxPath,
            listUnsubscribeHeader: email.listUnsubscribeHeader,
          ),
    body: body == null
        ? null
        : MessageDebugBody(
            cachedAt: body.cachedAt,
            textBodyLength: body.textBody?.length ?? 0,
            htmlBodyLength: body.htmlBody?.length ?? 0,
          ),
    pending: [
      for (final p in pending)
        MessageDebugPending(
          changeType: p.changeType,
          attempts: p.attempts,
          createdAt: p.createdAt,
          lastError: p.lastError,
          payload: p.payload,
        ),
    ],
    syncStates: [
      for (final s in syncStates)
        MessageDebugSyncState(
          resourceType: s.resourceType,
          state: s.state,
          syncedAt: s.syncedAt,
        ),
    ],
    lastSyncLog: lastSyncLog == null
        ? null
        : MessageDebugSyncLog(
            result: lastSyncLog.result,
            startedAt: lastSyncLog.startedAt,
            finishedAt: lastSyncLog.finishedAt,
            errorMessage: lastSyncLog.errorMessage,
          ),
    attachments: attachments,
  );
}

// ── JSON helpers — kept local so the UI never has to touch data/ ────────────

List<EmailAddress> decodeMessageDebugAddresses(String rawJson) {
  if (rawJson.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        EmailAddress(
          name: (e as Map<String, dynamic>)['name'] as String?,
          email: e['email'] as String? ?? '',
        ),
    ];
  } catch (_) {
    return const [];
  }
}

List<EmailAttachment> _decodeAttachments(String rawJson) {
  if (rawJson.trim().isEmpty) return const [];
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) return const [];
  return [
    for (final e in decoded)
      EmailAttachment(
        filename: (e as Map<String, dynamic>)['filename'] as String? ?? '',
        contentType: e['contentType'] as String? ?? '',
        size: (e['size'] as int?) ?? 0,
        fetchPartId: e['fetchPartId'] as String? ?? '',
      ),
  ];
}
