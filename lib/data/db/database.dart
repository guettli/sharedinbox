import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sharedinbox/core/db_schema_version.dart';
import 'package:sharedinbox/core/storage/db_encryption.dart';
import 'package:sharedinbox/core/storage/secure_storage.dart';
import 'package:sharedinbox/core/utils/message_id_utils.dart';
import 'package:sharedinbox/data/db/db_encryption_migration.dart';
import 'package:sharedinbox/data/storage/flutter_secure_storage_impl.dart';
import 'package:sqlite3/sqlite3.dart' show Database;

part 'database.g.dart';

// ── Tables ────────────────────────────────────────────────────────────────────

class Accounts extends Table {
  TextColumn get id => text()();
  TextColumn get displayName => text()();
  TextColumn get email => text()();
  TextColumn get imapHost => text()();
  IntColumn get imapPort => integer()();
  BoolColumn get imapSsl => boolean()();
  TextColumn get smtpHost => text()();
  IntColumn get smtpPort => integer()();
  BoolColumn get smtpSsl => boolean()();
  // Added in schema v2:
  TextColumn get accountType => text().withDefault(const Constant('imap'))();
  TextColumn get jmapUrl => text().nullable()();
  // Added in schema v3:
  TextColumn get username => text().withDefault(const Constant(''))();
  // Added in schema v13:
  BoolColumn get verbose => boolean().withDefault(const Constant(false))();
  // Added in schema v15: ManageSieve (RFC 5804) settings for IMAP accounts.
  TextColumn get manageSieveHost => text().withDefault(const Constant(''))();
  IntColumn get manageSievePort =>
      integer().withDefault(const Constant(4190))();
  BoolColumn get manageSieveSsl =>
      boolean().withDefault(const Constant(true))();
  // Added in schema v16: tri-state probe result.
  // null  = not probed yet (treat as available; show UI)
  // true  = probe succeeded; show ManageSieve UI
  // false = probe failed; hide ManageSieve UI (server doesn't support it)
  BoolColumn get manageSieveAvailable => boolean().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MailboxRow')
class Mailboxes extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // Opaque server-side identifier used as a foreign key by [Emails],
  // [Threads] and outbound protocol requests. For IMAP this equals the
  // hierarchical folder path (e.g. "INBOX/Work"); for JMAP it is the
  // server-assigned mailbox ID (e.g. "a").
  TextColumn get path => text()();
  TextColumn get name => text()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  IntColumn get totalCount => integer().withDefault(const Constant(0))();
  // Added in schema v8: JMAP role (e.g. "inbox", "sent", "trash").
  TextColumn get role => text().nullable()();
  // Added in schema v47: hierarchical, human-readable path used by the UI
  // and by Sieve `fileinto`. Equal to [path] for IMAP; for JMAP built from
  // the `parentId` chain of names joined with `/`.
  TextColumn get displayPath => text().withDefault(const Constant(''))();
  // Added in schema v47: parent mailbox server ID (JMAP). Null for a root
  // or for IMAP.
  TextColumn get parentId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class Emails extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get mailboxPath => text()();
  IntColumn get uid => integer()();
  TextColumn get subject => text().nullable()();
  DateTimeColumn get sentAt => dateTime().nullable()();
  DateTimeColumn get receivedAt => dateTime()();
  // JSON-encoded List<{name,email}>
  TextColumn get fromJson => text().withDefault(const Constant('[]'))();
  TextColumn get toAddresses => text().withDefault(const Constant('[]'))();
  TextColumn get ccJson => text().withDefault(const Constant('[]'))();
  TextColumn get preview => text().nullable()();
  BoolColumn get isSeen => boolean().withDefault(const Constant(false))();
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();
  BoolColumn get hasAttachment =>
      boolean().withDefault(const Constant(false))();
  // Added in schema v14: email threading.
  TextColumn get threadId => text().nullable()();
  TextColumn get messageId => text().nullable()();
  TextColumn get inReplyTo => text().nullable()();
  // Space-separated list of Message-IDs (RFC 2822 References header).
  TextColumn get references => text().nullable()();

  // Added in schema v22:
  DateTimeColumn get snoozedUntil => dateTime().nullable()();
  TextColumn get snoozedFromMailboxPath => text().nullable()();

  // Added in schema v23: RFC 2369 List-Unsubscribe header value.
  TextColumn get listUnsubscribeHeader => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class EmailBodies extends Table {
  TextColumn get emailId =>
      text().references(Emails, #id, onDelete: KeyAction.cascade)();
  TextColumn get textBody => text().nullable()();
  TextColumn get htmlBody => text().nullable()();
  // JSON-encoded List<{filename,contentType,size}>
  TextColumn get attachmentsJson => text().withDefault(const Constant('[]'))();
  // Added in schema v9: when the body was last fetched from the server.
  // Null for rows cached before this column was added (treated as expired).
  DateTimeColumn get cachedAt => dateTime().nullable()();
  // Added in schema v20: raw or parsed headers
  TextColumn get headersJson => text().nullable()();
  // Added in schema v28: serialised MimePart tree (JSON)
  TextColumn get mimeTreeJson => text().nullable()();
  // Added in schema v48: cached body size in characters (textBody + htmlBody
  // length). Populated on write; null for rows cached before v48.
  IntColumn get bodySize => integer().nullable()();

  @override
  Set<Column> get primaryKey => {emailId};
}

/// One row per attachment file that lives on the local file system under the
/// cache directory. Written by [EmailRepository.downloadAttachment] after
/// the bytes have been flushed to disk. Cascade-deleted with the parent email.
// Added in schema v48.
@DataClassName('AttachmentFileRow')
class AttachmentFiles extends Table {
  TextColumn get emailId =>
      text().references(Emails, #id, onDelete: KeyAction.cascade)();
  TextColumn get filename => text()();
  IntColumn get size => integer()();
  DateTimeColumn get downloadedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {emailId, filename};
}

@DataClassName('ThreadRow')
class Threads extends Table {
  TextColumn get id => text()(); // the threadId
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get mailboxPath => text()();
  TextColumn get subject => text().nullable()();
  DateTimeColumn get latestDate => dateTime()();
  IntColumn get messageCount => integer().withDefault(const Constant(1))();
  BoolColumn get hasUnread => boolean().withDefault(const Constant(false))();
  BoolColumn get isFlagged => boolean().withDefault(const Constant(false))();
  // JSON-encoded List<{name,email}>
  TextColumn get participantsJson => text().withDefault(const Constant('[]'))();
  TextColumn get preview => text().nullable()();
  TextColumn get latestEmailId => text()();
  TextColumn get emailIdsJson => text().withDefault(const Constant('[]'))();

  @override
  Set<Column> get primaryKey => {accountId, mailboxPath, id};
}

/// Protocol-agnostic outbound change queue.
/// Local mutations are written here before being sent to the server,
/// enabling offline-first behaviour and durable retries.
@DataClassName('PendingChangeRow')
class PendingChanges extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get resourceType => text()();
  TextColumn get resourceId => text()();
  // "flag_seen" | "flag_flagged" | "move" | "delete"
  TextColumn get changeType => text()();
  // JSON payload, e.g. {"seen": true} or {"dest": "Archive"}
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
}

/// Sync checkpoint per (account, resource type).
/// Stores the server-side state token used for incremental sync.
/// For JMAP: the opaque `state` string from Mailbox/get or Email/get.
/// For IMAP: a JSON object with last-synced UID / MODSEQ per mailbox.
@DataClassName('SyncStateRow')
class SyncStates extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get resourceType => text()();
  TextColumn get state => text()();
  DateTimeColumn get syncedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {accountId, resourceType};
}

/// Lightweight audit trail for each sync cycle.
/// Useful for debugging and surfacing "last synced" timestamps in the UI.
@DataClassName('SyncLogRow')
class SyncLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // "ok" | "error"
  TextColumn get result => text()();
  TextColumn get errorMessage => text().nullable()();
  // "imap" | "jmap"
  TextColumn get protocol => text().withDefault(const Constant(''))();
  IntColumn get itemsSynced => integer().withDefault(const Constant(0))();
  IntColumn get mailboxesSynced => integer().withDefault(const Constant(0))();
  IntColumn get pendingFlushed => integer().withDefault(const Constant(0))();
  IntColumn get emailsSkipped => integer().withDefault(const Constant(0))();
  IntColumn get bytesTransferred => integer().withDefault(const Constant(0))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get finishedAt => dateTime()();
  // Added in schema v13: raw protocol log when account.verbose == true.
  TextColumn get protocolLog => text().nullable()();
  // Added in schema v33: stack trace and permanent flag for error entries.
  TextColumn get errorStackTrace => text().nullable()();
  BoolColumn get isPermanent => boolean().withDefault(const Constant(false))();
}

/// Per-mailbox breakdown for a single sync cycle.
/// Each row is a child of one SyncLogs row.
@DataClassName('SyncLogMailboxRow')
class SyncLogMailboxes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get syncLogId =>
      integer().references(SyncLogs, #id, onDelete: KeyAction.cascade)();
  TextColumn get mailboxPath => text()();
  IntColumn get fetched => integer().withDefault(const Constant(0))();
  IntColumn get skipped => integer().withDefault(const Constant(0))();
  IntColumn get bytesTransferred => integer().withDefault(const Constant(0))();
  // Added in schema v30: how long this mailbox took to sync, in milliseconds.
  IntColumn get durationMs => integer().nullable()();
  // Added in schema v44: human-readable mailbox name for display.
  // For JMAP accounts mailboxPath holds the opaque server id (e.g. "a"),
  // so this holds the label (e.g. "Inbox"). Nullable so pre-v44 rows still
  // load — the UI falls back to mailboxPath when this is null.
  TextColumn get mailboxName => text().nullable()();
}

/// Stores the result of the periodic "ground truth" verification.
@DataClassName('SyncHealthRow')
class SyncHealth extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get lastVerifiedAt => dateTime()();
  BoolColumn get isHealthy => boolean()();
  // JSON summary of discrepancies (missingLocally, missingOnServer, etc.)
  TextColumn get discrepancySummary => text().nullable()();

  @override
  Set<Column> get primaryKey => {accountId};
}

/// Auto-saved compose drafts — persisted across app restarts.
class Drafts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId => text().nullable()();

  /// Set for replies/reply-alls; null for new messages.
  TextColumn get replyToEmailId => text().nullable()();
  TextColumn get toText => text().withDefault(const Constant(''))();
  TextColumn get ccText => text().withDefault(const Constant(''))();
  TextColumn get subjectText => text().withDefault(const Constant(''))();
  TextColumn get bodyText => text().withDefault(const Constant(''))();
  DateTimeColumn get updatedAt => dateTime()();
  // Added in schema v24: IMAP UID string ("mailbox:uid") on the server.
  TextColumn get imapServerId => text().nullable()();
  // Added in schema v42: JMAP Email id on the server.
  TextColumn get jmapServerId => text().nullable()();
  // Added in schema v42: local edits not yet pushed to the server.
  BoolColumn get dirty => boolean().withDefault(const Constant(true))();
}

/// Tombstones for drafts that were deleted locally but still need to be
/// removed from the server on the next sync cycle.
// Added in schema v42.
@DataClassName('DraftTombstoneRow')
class DraftTombstones extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // IMAP UID string or JMAP Email id on the server.
  TextColumn get serverId => text()();
  DateTimeColumn get createdAt => dateTime()();
}

/// Ephemeral public/private key pair generated for secure account sharing.
/// Expires after 20 minutes; used to decrypt an incoming encrypted-accounts QR.
@DataClassName('ShareKeyRow')
class ShareKeys extends Table {
  /// Random 16-byte key ID, hex-encoded.  Identifies which key pair the sender
  /// used so the receiver can look it up even if multiple pairs exist.
  TextColumn get id => text()();

  /// Base64-encoded X25519 public key (32 bytes).
  TextColumn get publicKey => text()();

  /// Base64-encoded X25519 private key (32 bytes).
  TextColumn get privateKey => text()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SearchHistoryRow')
class SearchHistoryEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get query => text()();
  DateTimeColumn get searchedAt => dateTime()();
}

@DataClassName('LocalSieveScriptRow')
class LocalSieveScripts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get content => text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
}

@DataClassName('UndoActionRow')
class UndoActions extends Table {
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // JSON-encoded UndoAction
  TextColumn get dataJson => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Records which emails have already had local Sieve rules applied.
/// Keyed by (accountId, messageId) so the same email is never processed twice,
/// even across restarts or re-syncs.
@DataClassName('LocalSieveAppliedRow')
class LocalSieveApplied extends Table {
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // RFC 2822 Message-ID header value — stable across folder moves.
  TextColumn get messageId => text()();
  DateTimeColumn get appliedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {accountId, messageId};
}

/// Senders for whom remote images are loaded automatically.
/// Per-device/per-user — not tied to any email account.
@DataClassName('ImageTrustedSenderRow')
class ImageTrustedSenders extends Table {
  TextColumn get senderEmail => text()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {senderEmail};
}

/// Per-email notes stored server-side (IMAP Notes folder / JMAP Notes mailbox).
/// Keyed by the RFC 2822 Message-ID header so notes survive folder moves.
// Added in schema v39.
@DataClassName('EmailNoteRow')
class EmailNotes extends Table {
  // UUID matching the X-SharedInbox-Note-Id custom header on the server.
  TextColumn get id => text()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // X-SharedInbox-Note-For value — stable across IMAP folder moves.
  TextColumn get messageId => text()();
  TextColumn get noteText => text()();
  // IMAP UID (as string) or JMAP email ID of the note message on the server.
  TextColumn get serverId => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Records the first time the user ran each app version (identified by GIT_HASH).
/// Added in schema v40.
@DataClassName('InstalledVersionRow')
class InstalledVersions extends Table {
  TextColumn get gitHash => text()();
  DateTimeColumn get installedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {gitHash};
}

/// General-purpose application event log.
/// Distinct from [SyncLogs], which is a per-cycle sync audit trail.
/// Rows are tagged with optional context (screen / account / folder / mail /
/// syncLog) and a level (debug | info | warn | error). [dataJson] holds a JSON
/// object with any extra structured fields.
// Added in schema v45.
@DataClassName('AppLogRow')
class AppLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt => dateTime()();
  // 'debug' | 'info' | 'warn' | 'error'
  TextColumn get level => text()();
  // Short event key, e.g. 'sync.cycle.complete', 'ui.screen.enter'.
  TextColumn get event => text()();
  // Human-readable one-liner.
  TextColumn get message => text()();
  // JSON object: extra structured fields, including serialised error+stack.
  TextColumn get dataJson => text().nullable()();
  // Optional context (any combination may be null).
  TextColumn get screen => text().nullable()();
  TextColumn get accountId => text()
      .nullable()
      .references(Accounts, #id, onDelete: KeyAction.setNull)();
  TextColumn get mailboxPath => text().nullable()();
  TextColumn get emailId =>
      text().nullable().references(Emails, #id, onDelete: KeyAction.setNull)();
  IntColumn get syncLogId => integer()
      .nullable()
      .references(SyncLogs, #id, onDelete: KeyAction.setNull)();
}

/// Offline send queue. One row per message that the user has hit "Send" on
/// while the network was unreachable (or whose send is otherwise pending).
/// Drained by [EmailRepository.flushOutbox] on every sync cycle.
///
/// The MIME bytes are pre-built at enqueue time so the queued message survives
/// changes to the [Drafts] / [Accounts] rows. JMAP attachment blobs cannot be
/// pre-uploaded (they expire and are session-scoped) so for JMAP we store
/// local file paths in [attachmentsJson] and re-upload at flush time.
// Added in schema v46.
@DataClassName('OutboxRow')
class Outbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get accountId =>
      text().references(Accounts, #id, onDelete: KeyAction.cascade)();
  // Original Drafts.id this message came from; nullable so an outbox row
  // outlives the draft.
  IntColumn get draftId => integer().nullable()();
  // RFC 822 bytes, base64-encoded. Used as the SMTP payload for IMAP accounts
  // and (after rebuild) as a fallback for the IMAP APPEND of the Sent copy.
  TextColumn get mimeBase64 => text()();
  // JSON envelope: {from, to, cc, subject, body} — used both for re-building
  // the JMAP Email/set payload at flush time and for the Outbox list UI.
  TextColumn get envelopeJson => text()();
  // JSON list of local file-system paths of attachments (re-uploaded as JMAP
  // blobs at flush time). Empty list = no attachments.
  TextColumn get attachmentsJson => text().withDefault(const Constant('[]'))();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  // When the row becomes eligible for the next attempt. Null = retry now.
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  // 'pending' (default, retried with backoff) | 'failed' (permanent error,
  // user must Retry or Discard manually).
  TextColumn get status => text().withDefault(const Constant('pending'))();
}

/// App-wide user preferences, stored as a singleton row (id always 1).
@DataClassName('UserPreferencesRow')
class UserPreferences extends Table {
  IntColumn get id => integer()();
  // 'bottom' (default) | 'top'
  TextColumn get menuPosition => text().withDefault(const Constant('bottom'))();
  // Added in schema v35: 'bottom' (default) | 'top'
  TextColumn get mailViewButtonPosition =>
      text().withDefault(const Constant('bottom'))();
  // Added in schema v36: 'nextMessage' (default) | 'showMailbox'
  TextColumn get afterMailViewAction =>
      text().withDefault(const Constant('nextMessage'))();
  // Added in schema v38: 'disabled' | 'wifiOnly' (default) | 'always'
  TextColumn get prefetchMode =>
      text().withDefault(const Constant('wifiOnly'))();
  // Added in schema v38: max cache size for offline email bodies, in megabytes.
  IntColumn get bodyCacheLimitMb =>
      integer().withDefault(const Constant(100))();

  @override
  Set<Column> get primaryKey => {id};
}

// ── Database ──────────────────────────────────────────────────────────────────

@DriftDatabase(
  tables: [
    Accounts,
    Mailboxes,
    Emails,
    EmailBodies,
    Threads,
    Drafts,
    SyncStates,
    PendingChanges,
    SyncLogs,
    SyncLogMailboxes,
    SyncHealth,
    UndoActions,
    SearchHistoryEntries,
    LocalSieveScripts,
    LocalSieveApplied,
    ShareKeys,
    UserPreferences,
    ImageTrustedSenders,
    EmailNotes,
    InstalledVersions,
    DraftTombstones,
    AppLogs,
    Outbox,
    AttachmentFiles,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => dbSchemaVersion;

  Future<void> _createEmailFts() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS email_fts USING fts5(
        subject, preview, from_json,
        content='emails',
        content_rowid='rowid'
      )
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_fts_ai
      AFTER INSERT ON emails BEGIN
        INSERT INTO email_fts(rowid, subject, preview, from_json)
        VALUES (new.rowid, new.subject, new.preview, new.from_json);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_fts_au
      AFTER UPDATE OF subject, preview, from_json ON emails BEGIN
        INSERT INTO email_fts(email_fts, rowid, subject, preview, from_json)
        VALUES ('delete', old.rowid, old.subject, old.preview, old.from_json);
        INSERT INTO email_fts(rowid, subject, preview, from_json)
        VALUES (new.rowid, new.subject, new.preview, new.from_json);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_fts_ad
      AFTER DELETE ON emails BEGIN
        INSERT INTO email_fts(email_fts, rowid, subject, preview, from_json)
        VALUES ('delete', old.rowid, old.subject, old.preview, old.from_json);
      END
    ''');
  }

  /// FTS5 shadow index over [EmailNotes.noteText]. Contentless mirror keyed
  /// on the email_notes rowid; join back via
  /// `email_notes_fts.rowid = email_notes.rowid`.
  Future<void> _createEmailNotesFts() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS email_notes_fts USING fts5(
        note_text,
        content='email_notes',
        content_rowid='rowid'
      )
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_notes_fts_ai
      AFTER INSERT ON email_notes BEGIN
        INSERT INTO email_notes_fts(rowid, note_text)
        VALUES (new.rowid, new.note_text);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_notes_fts_au
      AFTER UPDATE OF note_text ON email_notes BEGIN
        INSERT INTO email_notes_fts(email_notes_fts, rowid, note_text)
        VALUES ('delete', old.rowid, old.note_text);
        INSERT INTO email_notes_fts(rowid, note_text)
        VALUES (new.rowid, new.note_text);
      END
    ''');
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS email_notes_fts_ad
      AFTER DELETE ON email_notes BEGIN
        INSERT INTO email_notes_fts(email_notes_fts, rowid, note_text)
        VALUES ('delete', old.rowid, old.note_text);
      END
    ''');
  }

  Future<void> _createAppLogsIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS app_logs_created_at '
      'ON app_logs (created_at DESC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS app_logs_account_created_at '
      'ON app_logs (account_id, created_at DESC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS app_logs_level '
      'ON app_logs (level);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS app_logs_sync_log_id '
      'ON app_logs (sync_log_id);',
    );
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createEmailFts();
          await _createEmailNotesFts();
          await _createAppLogsIndexes();
        },
        onUpgrade: (m, from, to) async {
          // NOTE: m.createTable(T) creates the LATEST version of table T.
          // If you later add a column C to T in version X, you must guard
          // addColumn(T, T.C) with `if (from >= creationVersionOfT && from < X)`.
          if (from < 2) {
            await m.addColumn(accounts, accounts.accountType);
            await m.addColumn(accounts, accounts.jmapUrl);
          }
          if (from < 3) {
            await m.addColumn(accounts, accounts.username);
          }
          if (from < 4) {
            await m.createTable(drafts);
          }
          if (from < 5) {
            await m.createTable(syncStates);
          }
          if (from < 6) {
            await m.createTable(pendingChanges);
          }
          if (from < 7) {
            await m.createTable(syncLogs);
          }
          if (from < 8) {
            await m.addColumn(mailboxes, mailboxes.role);
          }
          if (from < 9) {
            await m.addColumn(emailBodies, emailBodies.cachedAt);
          }
          if (from >= 7 && from < 10) {
            await m.addColumn(syncLogs, syncLogs.protocol);
            await m.addColumn(syncLogs, syncLogs.mailboxesSynced);
            await m.addColumn(syncLogs, syncLogs.pendingFlushed);
          }
          if (from >= 7 && from < 11) {
            await m.addColumn(syncLogs, syncLogs.emailsSkipped);
            await m.addColumn(syncLogs, syncLogs.bytesTransferred);
          }
          if (from < 12) {
            await m.createTable(syncLogMailboxes);
          }
          if (from < 13) {
            await m.addColumn(accounts, accounts.verbose);
            if (from >= 7) {
              await m.addColumn(syncLogs, syncLogs.protocolLog);
            }
          }
          if (from < 14) {
            await m.addColumn(emails, emails.threadId);
            await m.addColumn(emails, emails.messageId);
            await m.addColumn(emails, emails.inReplyTo);
            await m.addColumn(emails, emails.references);
          }
          if (from < 15) {
            await m.addColumn(accounts, accounts.manageSieveHost);
            await m.addColumn(accounts, accounts.manageSievePort);
            await m.addColumn(accounts, accounts.manageSieveSsl);
          }
          if (from < 16) {
            await m.addColumn(accounts, accounts.manageSieveAvailable);
          }
          if (from < 17) {
            await m.createTable(threads);
            // Populate threads from existing emails.
            final allRows = await select(emails).get();
            final groups = <String, List<Email>>{};
            for (final row in allRows) {
              final key =
                  '${row.accountId}:${row.mailboxPath}:${row.threadId ?? row.id}';
              groups.putIfAbsent(key, () => []).add(row);
            }

            for (final threadEmails in groups.values) {
              threadEmails.sort((a, b) {
                final da = a.sentAt ?? a.receivedAt;
                final db = b.sentAt ?? b.receivedAt;
                return da.compareTo(db);
              });
              final latest = threadEmails.last;

              await into(threads).insert(
                ThreadsCompanion.insert(
                  id: latest.threadId ?? latest.id,
                  accountId: latest.accountId,
                  mailboxPath: latest.mailboxPath,
                  subject: Value(latest.subject),
                  latestDate: latest.sentAt ?? latest.receivedAt,
                  messageCount: Value(threadEmails.length),
                  hasUnread: Value(threadEmails.any((e) => !e.isSeen)),
                  isFlagged: Value(threadEmails.any((e) => e.isFlagged)),
                  preview: Value(latest.preview),
                  latestEmailId: latest.id,
                  emailIdsJson: Value(
                    jsonEncode(threadEmails.map((e) => e.id).toList()),
                  ),
                  participantsJson: Value(
                    latest.fromJson,
                  ), // Good enough for migration
                ),
              );
            }
          }
          if (from < 18) {
            // Index for sorting email list by date.
            await m.createIndex(
              Index(
                'emails_received_at',
                'CREATE INDEX emails_received_at ON emails (account_id, mailbox_path, received_at DESC);',
              ),
            );
            // Index for finding emails in a thread.
            await m.createIndex(
              Index(
                'emails_thread_id',
                'CREATE INDEX emails_thread_id ON emails (account_id, mailbox_path, thread_id);',
              ),
            );
            // Index for pending changes queue.
            await m.createIndex(
              Index(
                'pending_changes_account_id',
                'CREATE INDEX pending_changes_account_id ON pending_changes (account_id);',
              ),
            );
          }
          if (from < 19) {
            await m.createTable(syncHealth);
          }
          if (from < 20) {
            await m.addColumn(emailBodies, emailBodies.headersJson);
          }
          if (from < 21) {
            await m.createTable(undoActions);
          }
          if (from < 22) {
            final check = await customSelect('PRAGMA table_info(emails)').get();
            final names = check.map((row) => row.read<String>('name')).toList();

            if (!names.contains('snoozed_until')) {
              await m.addColumn(emails, emails.snoozedUntil);
            }
            if (!names.contains('snoozed_from_mailbox_path')) {
              await m.addColumn(emails, emails.snoozedFromMailboxPath);
            }

            await m.createIndex(
              Index(
                'emails_snoozed_until',
                'CREATE INDEX IF NOT EXISTS emails_snoozed_until ON emails (account_id, snoozed_until) WHERE snoozed_until IS NOT NULL;',
              ),
            );
          }
          if (from < 23) {
            await m.addColumn(emails, emails.listUnsubscribeHeader);
          }
          if (from >= 4 && from < 24) {
            await m.addColumn(drafts, drafts.imapServerId);
          }
          if (from < 25) {
            // For observeMailboxes: filter by account_id, sort by path.
            await m.createIndex(
              Index(
                'mailboxes_account_id',
                'CREATE INDEX IF NOT EXISTS mailboxes_account_id ON mailboxes (account_id, path);',
              ),
            );
            // For observeThreads: filter by account_id+mailbox_path, sort by latest_date.
            await m.createIndex(
              Index(
                'threads_latest_date',
                'CREATE INDEX IF NOT EXISTS threads_latest_date ON threads (account_id, mailbox_path, latest_date DESC);',
              ),
            );
          }
          if (from < 26) {
            await _createEmailFts();
            // Backfill FTS index from existing rows.
            await customStatement('''
              INSERT INTO email_fts(rowid, subject, preview, from_json)
              SELECT rowid, subject, preview, from_json FROM emails
            ''');
          }
          if (from < 27) {
            await m.createTable(searchHistoryEntries);
          }
          if (from < 28) {
            await m.addColumn(emailBodies, emailBodies.mimeTreeJson);
          }
          if (from < 29) {
            await m.createTable(localSieveScripts);
          }
          if (from >= 12 && from < 30) {
            await m.addColumn(syncLogMailboxes, syncLogMailboxes.durationMs);
          }
          if (from < 31) {
            await m.createTable(shareKeys);
          }
          if (from < 32) {
            await m.createTable(localSieveApplied);
          }
          if (from >= 7 && from < 33) {
            await m.addColumn(syncLogs, syncLogs.errorStackTrace);
            await m.addColumn(syncLogs, syncLogs.isPermanent);
          }
          if (from < 34) {
            await m.createTable(userPreferences);
          }
          if (from >= 34 && from < 35) {
            await m.addColumn(
              userPreferences,
              userPreferences.mailViewButtonPosition,
            );
          }
          if (from >= 34 && from < 36) {
            await m.addColumn(
              userPreferences,
              userPreferences.afterMailViewAction,
            );
          }
          if (from < 37) {
            await m.createTable(imageTrustedSenders);
          }
          if (from >= 34 && from < 38) {
            await m.addColumn(userPreferences, userPreferences.prefetchMode);
            await m.addColumn(
              userPreferences,
              userPreferences.bodyCacheLimitMb,
            );
          }
          if (from < 39) {
            await m.createTable(emailNotes);
          }
          if (from < 40) {
            await m.createTable(installedVersions);
          }
          if (from < 41) {
            // Fix IMAP email IDs to include mailboxPath, preventing UID
            // collisions across mailboxes (IMAP UIDs are mailbox-scoped).
            // New format: "accountId:mailboxPath:uid" (was "accountId:uid").
            //
            // defer_foreign_keys defers the email_bodies→emails FK check
            // to COMMIT so the two tables can be updated sequentially inside
            // the migration transaction without a transient FK violation.
            await customStatement('PRAGMA defer_foreign_keys = ON');

            // 1. Remap email_bodies.email_id before emails.id changes.
            await customStatement('''
              UPDATE email_bodies
              SET email_id = (
                SELECT e.account_id || ':' || e.mailbox_path || ':' || CAST(e.uid AS TEXT)
                FROM emails e
                JOIN accounts a ON a.id = e.account_id
                WHERE e.id = email_bodies.email_id
                  AND a.account_type = 'imap'
              )
              WHERE EXISTS (
                SELECT 1 FROM emails e
                JOIN accounts a ON a.id = e.account_id
                WHERE e.id = email_bodies.email_id
                  AND a.account_type = 'imap'
              )
            ''');

            // 2. Update emails.thread_id where it was set to the email's own
            //    id (fallback for messages with no Message-ID header).
            await customStatement('''
              UPDATE emails
              SET thread_id = account_id || ':' || mailbox_path || ':' || CAST(uid AS TEXT)
              WHERE account_id IN (SELECT id FROM accounts WHERE account_type = 'imap')
                AND thread_id = id
            ''');

            // 3. Update the primary key on emails.
            await customStatement('''
              UPDATE emails
              SET id = account_id || ':' || mailbox_path || ':' || CAST(uid AS TEXT)
              WHERE account_id IN (
                SELECT id FROM accounts WHERE account_type = 'imap'
              )
            ''');

            // 5. Rebuild threads for IMAP accounts from the updated email rows.
            //    The threads table stores denormalised data (latest_email_id,
            //    email_ids_json) that references email IDs, so it is simpler to
            //    delete and reconstruct than to patch the JSON in SQL.
            await customStatement('''
              DELETE FROM threads
              WHERE account_id IN (SELECT id FROM accounts WHERE account_type = 'imap')
            ''');

            final imapAccounts = await (select(accounts)
                  ..where((t) => t.accountType.equals('imap')))
                .get();
            for (final acct in imapAccounts) {
              final emailRows = await (select(emails)
                    ..where((t) => t.accountId.equals(acct.id)))
                  .get();

              final groups = <String, List<Email>>{};
              for (final row in emailRows) {
                final key = '${row.mailboxPath}:${row.threadId ?? row.id}';
                groups.putIfAbsent(key, () => []).add(row);
              }

              for (final threadEmails in groups.values) {
                threadEmails.sort((a, b) {
                  final da = a.sentAt ?? a.receivedAt;
                  final db = b.sentAt ?? b.receivedAt;
                  return da.compareTo(db);
                });
                final latest = threadEmails.last;

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

                await into(threads).insert(
                  ThreadsCompanion.insert(
                    id: latest.threadId ?? latest.id,
                    accountId: latest.accountId,
                    mailboxPath: latest.mailboxPath,
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
            }
          }
          if (from < 42) {
            // Add FTS5 shadow table for email_notes so note search no longer
            // falls back to LIKE scans as the local DB grows.
            await _createEmailNotesFts();
            await customStatement('''
              INSERT INTO email_notes_fts(rowid, note_text)
              SELECT rowid, note_text FROM email_notes
            ''');
          }
          if (from >= 4 && from < 43) {
            await m.addColumn(drafts, drafts.jmapServerId);
            await m.addColumn(drafts, drafts.dirty);
          }
          if (from < 43) {
            await m.createTable(draftTombstones);
          }
          if (from >= 12 && from < 44) {
            await m.addColumn(syncLogMailboxes, syncLogMailboxes.mailboxName);
          }
          if (from < 45) {
            await m.createTable(appLogs);
            await _createAppLogsIndexes();
          }
          if (from < 46) {
            await m.createTable(outbox);
          }
          if (from < 47) {
            // Some legacy test snapshots build only a partial schema, so the
            // `mailboxes` / `sync_states` tables may not exist. Guard each
            // step against that so the migration is idempotent even under
            // incomplete states.
            if (await _tableExists(this, 'mailboxes')) {
              await m.addColumn(mailboxes, mailboxes.displayPath);
              await m.addColumn(mailboxes, mailboxes.parentId);
              // Backfill display_path from path so IMAP folders (whose path
              // is already hierarchical + human-readable) render correctly.
              // JMAP rows still hold the opaque server ID here; the next
              // mailbox sync recomputes them from the parent chain.
              await customStatement('''
                UPDATE mailboxes SET display_path = path
                WHERE display_path = ''
              ''');
            }
            // Drop the JMAP `Mailbox` sync checkpoint so the next launch
            // triggers a full re-sync and picks up hierarchical displayPaths.
            if (await _tableExists(this, 'sync_states') &&
                await _tableExists(this, 'accounts')) {
              await customStatement('''
                DELETE FROM sync_states WHERE resource_type = 'Mailbox'
                AND account_id IN (SELECT id FROM accounts
                WHERE account_type = 'jmap')
              ''');
            }
          }
          if (from < 48) {
            if (await _tableExists(this, 'email_bodies')) {
              await m.addColumn(emailBodies, emailBodies.bodySize);
              // Backfill bodySize for existing rows from the cached text/html.
              await customStatement('''
                UPDATE email_bodies
                SET body_size =
                  COALESCE(LENGTH(text_body), 0) + COALESCE(LENGTH(html_body), 0)
              ''');
            }
            await m.createTable(attachmentFiles);
          }
          if (from < 49) {
            // Normalise Message-ID / In-Reply-To / References for legacy IMAP
            // rows written before `_cleanMessageId` (#143) stripped the RFC
            // 5322 angle brackets at insert time. JMAP rows always stored
            // them bracket-less (RFC 8621 §4.1.2.3), so a compare against
            // JMAP would previously see `<foo@bar>` on the IMAP side and
            // `foo@bar` on the JMAP side and treat them as unrelated. See
            // #406.
            if (await _tableExists(this, 'emails')) {
              await customStatement(
                'UPDATE emails '
                'SET message_id = SUBSTR(message_id, 2, LENGTH(message_id) - 2) '
                "WHERE message_id LIKE '<%>'",
              );
              await customStatement(
                'UPDATE emails '
                'SET in_reply_to = SUBSTR(in_reply_to, 2, LENGTH(in_reply_to) - 2) '
                "WHERE in_reply_to LIKE '<%>'",
              );
              // References is a whitespace-separated list of ids; strip
              // per-token in Dart because SQLite has no split/join.
              final refRows = await customSelect(
                'SELECT rowid, "references" AS refs FROM emails '
                'WHERE "references" LIKE \'%<%\'',
              ).get();
              for (final r in refRows) {
                final rowid = r.read<int>('rowid');
                final refs = r.read<String>('refs');
                final cleaned = normaliseReferences(refs);
                if (cleaned == null) {
                  await customStatement(
                    'UPDATE emails SET "references" = NULL WHERE rowid = ?',
                    [rowid],
                  );
                } else {
                  await customStatement(
                    'UPDATE emails SET "references" = ? WHERE rowid = ?',
                    [cleaned, rowid],
                  );
                }
              }
            }
          }
        },
      );

  /// Inserts a row for [gitHash] the first time that version is seen.
  /// Subsequent calls for the same hash are silently ignored so the original
  /// install timestamp is preserved.
  Future<void> recordInstalledVersionIfNew(String gitHash) async {
    if (gitHash.isEmpty) return;
    await into(installedVersions).insert(
      InstalledVersionsCompanion.insert(
        gitHash: gitHash,
        installedAt: DateTime.now(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<Map<String, DateTime>> loadInstalledVersions() async {
    final rows = await select(installedVersions).get();
    return {for (final r in rows) r.gitHash: r.installedAt};
  }
}

/// True when [name] exists as a table in [db]. Used by migrations that need
/// to survive incomplete legacy test snapshots where not every table has
/// been created yet.
Future<bool> _tableExists(AppDatabase db, String name) async {
  final rows = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    variables: [Variable<String>(name)],
  ).get();
  return rows.isNotEmpty;
}

// Resolved once in main() via initDatabasePath() before runApp().
String? _dbPath;

/// Call after WidgetsFlutterBinding.ensureInitialized() so that the
/// path_provider plugin channel is registered before the first DB access.
/// On some Android versions the Pigeon channel is not ready at the very
/// start of main(); if it fails, _openConnection() retries lazily.
///
/// Also drains any pending encryption state change (toggle from Preferences):
/// the swap must happen before Drift opens its connection because converting
/// the file between plaintext and SQLCipher requires exclusive access.
Future<void> initDatabasePath() async {
  try {
    final dir = await getApplicationSupportDirectory();
    _dbPath = p.join(dir.path, 'sharedinbox.db');
  } on PlatformException {
    // Channel not yet established; LazyDatabase will resolve the path
    // on first access, after runApp() completes initialization.
  }
  if (_dbPath != null) {
    try {
      await processPendingDbEncryptionChange(
        dbPath: _dbPath!,
        storage: const FlutterSecureStorageImpl(),
      );
    } catch (_) {
      // Migration is best-effort: any failure leaves the original DB in
      // place. Surfacing a UI error here would require a context we don't
      // have yet; the user can re-toggle from Preferences.
    }
  }
}

/// Resolve the application support path, retrying on PlatformException to
/// survive a race where the path_provider Pigeon channel isn't ready yet.
Future<String> _resolveDatabasePath() async {
  if (_dbPath != null) return _dbPath!;
  // initDatabasePath() failed (channel not ready before runApp). Retry now
  // that the engine is fully initialised, with back-off. Some slow Android
  // devices need several seconds for the Pigeon channel to become ready
  // (issue #166), so use a longer schedule than the initial attempt.
  const delays = [200, 500, 1000, 2000, 4000];
  for (final ms in delays) {
    try {
      final dir = await getApplicationSupportDirectory();
      _dbPath = p.join(dir.path, 'sharedinbox.db');
      return _dbPath!;
    } on PlatformException {
      await Future<void>.delayed(Duration(milliseconds: ms));
    }
  }
  // On Android, path_provider can be permanently broken on some devices
  // regardless of how long we wait (issue #192).  Derive the path from
  // /proc/self/cmdline (the Android process name == package name) without
  // a platform channel as a last resort so the app can still open its DB.
  if (Platform.isAndroid) {
    final fallback = await _androidFallbackPath();
    if (fallback != null) {
      _dbPath = fallback;
      return _dbPath!;
    }
  }
  throw PlatformException(
    code: 'channel-error',
    message: 'path_provider unavailable after ${delays.length + 1} attempts — '
        'cannot open database.',
  );
}

// Reads /proc/self/cmdline to extract the Android package name, then
// constructs the standard app files-dir path without a platform channel.
// Returns null when the path cannot be determined or created.
Future<String?> _androidFallbackPath() async {
  try {
    final bytes = await File('/proc/self/cmdline').readAsBytes();
    final end = bytes.indexOf(0);
    final packageName = String.fromCharCodes(
      end >= 0 ? bytes.sublist(0, end) : bytes,
    ).trim();
    // A valid Android package name contains dots but not slashes.
    if (packageName.isEmpty ||
        !packageName.contains('.') ||
        packageName.contains('/')) {
      return null;
    }
    for (final base in [
      '/data/user/0/$packageName/files',
      '/data/data/$packageName/files',
    ]) {
      try {
        await Directory(base).create(recursive: true);
        return p.join(base, 'sharedinbox.db');
      } catch (_) {
        continue;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Returns the resolved DB path. Must be called after [initDatabasePath]
/// has completed (which it has, by the time any UI provider is built).
/// Throws [StateError] if invoked before the path is known — that would
/// indicate a wiring bug, not a recoverable runtime condition.
String currentDatabasePath() {
  final path = _dbPath;
  if (path == null) {
    throw StateError(
      'currentDatabasePath() called before initDatabasePath() resolved.',
    );
  }
  return path;
}

// These functions are only called from unit tests (database_path_test.dart).
// They expose internals that cannot be reached via the public API.
Future<String> resolveDatabasePathForTesting() => _resolveDatabasePath();
void resetDatabasePathForTesting() => _dbPath = null;
void setDatabasePathForTesting(String path) => _dbPath = path;
Future<String?> androidFallbackPathForTesting() => _androidFallbackPath();

/// Configures PRAGMAs on a newly opened SQLite connection.
///
/// When [cipherKeyHex] is non-null, SQLCipher is activated by issuing
/// `PRAGMA key` as the very first statement — required by SQLCipher so that
/// the header can be decrypted before any other operation runs.
/// `cipher_compatibility = 4` pins the KDF defaults so the on-disk format
/// stays stable across SQLCipher upstream releases.
///
/// busy_timeout must come after `PRAGMA key` so subsequent statements retry
/// on SQLITE_BUSY instead of immediately failing.
///
/// journal_mode = WAL is wrapped in a try/catch because a concurrent
/// WorkManager background task may already have the DB open when the app
/// starts.  SQLITE_BUSY_SNAPSHOT (extended code 261, primary code 5) is
/// returned in that situation; it only occurs when the DB is already in WAL
/// mode, so the pragma would be a no-op anyway and it is safe to continue.
void _setupPragmas(Database db, {String? cipherKeyHex}) {
  if (cipherKeyHex != null && cipherKeyHex.isNotEmpty) {
    db.execute("PRAGMA key = \"x'$cipherKeyHex'\";");
    db.execute('PRAGMA cipher_compatibility = 4;');
  }
  db.execute('PRAGMA busy_timeout = 5000;');
  try {
    db.execute('PRAGMA journal_mode = WAL;');
  } on SqliteException catch (e) {
    // resultCode strips the extended bits: both SQLITE_BUSY (5) and
    // SQLITE_BUSY_SNAPSHOT (261) reduce to 5.  Re-throw anything else.
    if (e.resultCode != 5) rethrow;
  }
}

/// Resolves the SQLCipher key (if any) for the DB at [dbPath].
///
/// Returns null when the marker file is absent (DB is plaintext) or when the
/// marker is present but secure-storage has no key — the caller treats that
/// as "open plaintext" and the DB layer will surface a clean `not a database`
/// error if the file is in fact encrypted.
Future<String?> _resolveCipherKey(String dbPath, SecureStorage storage) async {
  if (!isDbEncrypted(dbPath)) return null;
  return readDbCipherKey(storage);
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final path = await _resolveDatabasePath();
    final keyHex =
        await _resolveCipherKey(path, const FlutterSecureStorageImpl());
    return NativeDatabase.createInBackground(
      File(path),
      setup: (db) => _setupPragmas(db, cipherKeyHex: keyHex),
    );
  });
}

/// Background-isolate counterpart to [_openConnection] — exposed so the
/// WorkManager handler (background_sync.dart) opens the DB with the same
/// encryption logic as the foreground app.
Future<NativeDatabase> openNativeDatabaseForBackground(File dbFile) async {
  final keyHex = await _resolveCipherKey(
    dbFile.path,
    const FlutterSecureStorageImpl(),
  );
  return NativeDatabase(
    dbFile,
    setup: (db) => _setupPragmas(db, cipherKeyHex: keyHex),
  );
}

// Exposed so tests can run the exact production setup logic on a raw
// sqlite3 connection (same pattern as resolveDatabasePathForTesting).
void setupPragmasForTesting(Database db, {String? cipherKeyHex}) =>
    _setupPragmas(db, cipherKeyHex: cipherKeyHex);
