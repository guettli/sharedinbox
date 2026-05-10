import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  TextColumn get path => text()();
  TextColumn get name => text()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  IntColumn get totalCount => integer().withDefault(const Constant(0))();
  // Added in schema v8: JMAP role (e.g. "inbox", "sent", "trash").
  TextColumn get role => text().nullable()();

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

  @override
  Set<Column> get primaryKey => {emailId};
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
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  @override
  int get schemaVersion => 22;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
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
          if (from < 10) {
            await m.addColumn(syncLogs, syncLogs.protocol);
            await m.addColumn(syncLogs, syncLogs.mailboxesSynced);
            await m.addColumn(syncLogs, syncLogs.pendingFlushed);
          }
          if (from < 11) {
            await m.addColumn(syncLogs, syncLogs.emailsSkipped);
            await m.addColumn(syncLogs, syncLogs.bytesTransferred);
          }
          if (from < 12) {
            await m.createTable(syncLogMailboxes);
          }
          if (from < 13) {
            await m.addColumn(accounts, accounts.verbose);
            await m.addColumn(syncLogs, syncLogs.protocolLog);
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
                  participantsJson:
                      Value(latest.fromJson), // Good enough for migration
                ),
              );
            }
          }
          if (from < 18) {
            // Index for sorting email list by date.
            await m.createIndex(
              Index(
                'emails_received_at',
                'CREATE INDEX emails_received_at ON emails (accountId, mailboxPath, receivedAt DESC);',
              ),
            );
            // Index for finding emails in a thread.
            await m.createIndex(
              Index(
                'emails_thread_id',
                'CREATE INDEX emails_thread_id ON emails (accountId, mailboxPath, threadId);',
              ),
            );
            // Index for pending changes queue.
            await m.createIndex(
              Index(
                'pending_changes_account_id',
                'CREATE INDEX pending_changes_account_id ON pending_changes (accountId);',
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
                'CREATE INDEX IF NOT EXISTS emails_snoozed_until ON emails (accountId, snoozedUntil) WHERE snoozedUntil IS NOT NULL;',
              ),
            );
          }
        },
      );
}

// Resolved once in main() via initDatabasePath() before runApp().
String? _dbPath;

/// Call after WidgetsFlutterBinding.ensureInitialized() so that the
/// path_provider plugin channel is registered before the first DB access.
Future<void> initDatabasePath() async {
  final dir = await getApplicationSupportDirectory();
  _dbPath = p.join(dir.path, 'sharedinbox.db');
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final file = File(
      _dbPath ??
          p.join(
            (await getApplicationSupportDirectory()).path,
            'sharedinbox.db',
          ),
    );
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // WAL lets readers and writers proceed concurrently (different account
        // sync loops share the same DB).  busy_timeout makes SQLite retry for
        // up to 5 s instead of immediately returning SQLITE_BUSY.
        db.execute('PRAGMA journal_mode = WAL;');
        db.execute('PRAGMA busy_timeout = 5000;');
      },
    );
  });
}
