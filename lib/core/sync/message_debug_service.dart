import 'dart:convert';

import 'package:drift/drift.dart';

import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/sync/message_probe.dart';
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

/// Builds the [LocalMessageSnapshot] the probe comparison expects from a
/// [MessageDebugEmail] and its cached [attachments]. Shared by the debug
/// screen and the markdown export so the mapping lives in one place.
LocalMessageSnapshot buildLocalMessageSnapshot(
  MessageDebugEmail email,
  List<EmailAttachment> attachments,
) {
  return LocalMessageSnapshot(
    mailboxPath: email.mailboxPath,
    messageId: email.messageId,
    subject: email.subject,
    sentAt: email.sentAt,
    receivedAt: email.receivedAt,
    isSeen: email.isSeen,
    isFlagged: email.isFlagged,
    hasAttachment: email.hasAttachment,
    uid: email.uid,
    from: decodeMessageDebugAddresses(email.fromJson),
    to: decodeMessageDebugAddresses(email.toAddresses),
    cc: decodeMessageDebugAddresses(email.ccJson),
    inReplyTo: email.inReplyTo,
    references: email.references,
    listUnsubscribeHeader: email.listUnsubscribeHeader,
    attachments: attachments,
  );
}

/// Renders [snapshot] (and, when supplied, a remote [probe] comparison) as a
/// self-contained markdown document the user can paste straight into a bug
/// report. Pure and Flutter-free so it can be unit-tested and reused by the
/// "Debug Mail" screen.
String buildMessageDebugMarkdown(
  MessageDebugSnapshot snapshot, {
  ProbeResult? probe,
}) {
  final buf = StringBuffer('# Mail debug report\n\n');
  final email = snapshot.email;
  if (email == null) {
    buf.writeln('No local row found for this message id.');
    return buf.toString().trimRight();
  }

  buf.writeln('## Local state\n');
  _writeTable(buf, [
    ('id', email.id),
    ('accountId', email.accountId),
    ('mailboxPath', email.mailboxPath),
    ('uid', email.uid.toString()),
    ('subject', email.subject ?? ''),
    ('sentAt', _fmtTime(email.sentAt)),
    ('receivedAt', _fmtTime(email.receivedAt)),
    ('from', email.fromJson),
    ('to', email.toAddresses),
    ('cc', email.ccJson),
    ('preview', email.preview ?? ''),
    ('isSeen', email.isSeen.toString()),
    ('isFlagged', email.isFlagged.toString()),
    ('hasAttachment', email.hasAttachment.toString()),
    ('threadId', email.threadId ?? ''),
    ('messageId', email.messageId ?? ''),
    ('inReplyTo', email.inReplyTo ?? ''),
    ('references', email.references ?? ''),
    ('snoozedUntil', _fmtTime(email.snoozedUntil)),
    ('snoozedFromMailboxPath', email.snoozedFromMailboxPath ?? ''),
    ('listUnsubscribeHeader', email.listUnsubscribeHeader ?? ''),
  ]);
  buf.writeln();

  buf.writeln('## Body\n');
  final body = snapshot.body;
  if (body == null) {
    _writeTable(buf, [('body', '(not cached)')]);
  } else {
    _writeTable(buf, [
      ('cachedAt', body.cachedAt != null ? _fmtTime(body.cachedAt) : '(never)'),
      ('textBytes', body.textBodyLength.toString()),
      ('htmlBytes', body.htmlBodyLength.toString()),
    ]);
  }
  buf.writeln();

  buf.writeln('## Attachments (${snapshot.attachments.length})\n');
  if (snapshot.attachments.isEmpty) {
    buf.writeln('None.');
  } else {
    _writeTable(buf, [
      for (final a in snapshot.attachments)
        (
          a.filename.isEmpty ? '(unnamed)' : a.filename,
          '${a.contentType}, ${a.size} bytes',
        ),
    ]);
  }
  buf.writeln();

  buf.writeln('## Pending changes (${snapshot.pending.length})\n');
  if (snapshot.pending.isEmpty) {
    buf.writeln('None.');
  } else {
    for (final p in snapshot.pending) {
      _writeTable(buf, [
        ('changeType', p.changeType),
        ('attempts', p.attempts.toString()),
        ('createdAt', _fmtTime(p.createdAt)),
        if (p.lastError != null) ('lastError', p.lastError!),
        ('payload', p.payload),
      ]);
      buf.writeln();
    }
  }

  buf.writeln('## Sync state\n');
  final syncRows = <(String, String)>[
    for (final s in snapshot.syncStates)
      (s.resourceType, '${s.state} (synced ${_fmtTime(s.syncedAt)})'),
    if (snapshot.lastSyncLog != null)
      (
        'lastSyncLog',
        '${snapshot.lastSyncLog!.result} at '
            '${_fmtTime(snapshot.lastSyncLog!.startedAt)}'
            '${snapshot.lastSyncLog!.errorMessage != null ? ' — ${snapshot.lastSyncLog!.errorMessage}' : ''}',
      ),
  ];
  if (syncRows.isEmpty) {
    buf.writeln('None.');
  } else {
    _writeTable(buf, syncRows);
  }
  buf.writeln();

  if (probe != null) {
    buf.writeln('## Remote state\n');
    if (probe.notFound) {
      buf.writeln('Message not found on server.');
    } else if (probe.error != null) {
      buf.writeln('Remote fetch failed: ${probe.error}');
    } else if (probe.snapshot != null) {
      final remote = probe.snapshot!;
      _writeTable(buf, [
        ('subject', remote.subject ?? ''),
        ('isSeen', remote.isSeen.toString()),
        ('isFlagged', remote.isFlagged.toString()),
        ('mailboxPath', remote.mailboxPath),
        ('messageId', remote.messageId ?? ''),
        if (remote.uid != null) ('uid', remote.uid.toString()),
        if (remote.sizeBytes != null)
          ('sizeBytes', remote.sizeBytes.toString()),
        ('attachmentCount', remote.attachments.length.toString()),
      ]);
      buf.writeln();
      final comparison = compareMessage(
        buildLocalMessageSnapshot(email, snapshot.attachments),
        remote,
      );
      buf.writeln('### Local vs remote\n');
      if (comparison.isMatch) {
        buf.writeln('Match: local and remote agree on every checked field.');
      } else {
        buf.writeln('Mismatch: ${comparison.diffs.length} field(s) differ.\n');
        _writeTable(
          buf,
          [
            for (final d in comparison.diffs)
              (d.field, 'local=`${d.local}` remote=`${d.remote}`'),
          ],
          headers: ('field', 'diff'),
        );
      }
      buf.writeln();
      if (remote.headers.isNotEmpty) {
        buf.writeln('### Headers\n');
        _writeTable(buf, [
          for (final e in remote.headers.entries) (e.key, e.value),
        ]);
      }
    }
  }

  return buf.toString().trimRight();
}

void _writeTable(
  StringBuffer buf,
  List<(String, String)> rows, {
  (String, String) headers = ('field', 'value'),
}) {
  buf.writeln('| ${headers.$1} | ${headers.$2} |');
  buf.writeln('| --- | --- |');
  for (final (k, v) in rows) {
    buf.writeln('| ${_escapeCell(k)} | ${_escapeCell(v)} |');
  }
}

/// Flattens a value to a single markdown table cell: newlines collapse to
/// spaces and pipes are escaped so they don't break the column layout.
String _escapeCell(String value) {
  return value
      .replaceAll('\r\n', ' ')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ')
      .replaceAll('|', r'\|')
      .trim();
}

String _fmtTime(DateTime? time) =>
    time == null ? '' : time.toUtc().toIso8601String();

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
