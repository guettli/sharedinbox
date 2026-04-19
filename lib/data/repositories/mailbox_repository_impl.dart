import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import '../../core/models/account.dart' as account_model;
import '../../core/models/mailbox.dart' as model;
import '../../core/repositories/account_repository.dart';
import '../../core/repositories/mailbox_repository.dart';
import '../../core/utils/logger.dart';
import '../db/database.dart';
import '../imap/imap_client_factory.dart';
import '../jmap/jmap_client.dart';
import 'email_repository_impl.dart' show ImapConnectFn;

class MailboxRepositoryImpl implements MailboxRepository {
  MailboxRepositoryImpl(
    this._db,
    this._accounts, {
    ImapConnectFn imapConnect = connectImap,
    http.Client? httpClient,
  })  : _imapConnect = imapConnect,
        _httpClient = httpClient ?? http.Client();

  final AppDatabase _db;
  final AccountRepository _accounts;
  final ImapConnectFn _imapConnect;
  final http.Client _httpClient;

  String _effectiveUsername(account_model.Account account) =>
      account.username.isNotEmpty ? account.username : account.email;

  @override
  Stream<List<model.Mailbox>> observeMailboxes(String accountId) {
    return (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId))
          ..orderBy([(t) => OrderingTerm.asc(t.path)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<void> syncMailboxes(String accountId) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        await _syncMailboxesImap(account, password);
      case account_model.AccountType.jmap:
        await _syncMailboxesJmap(account, password);
    }
  }

  // ── IMAP ──────────────────────────────────────────────────────────────────

  Future<void> _syncMailboxesImap(
      account_model.Account account, String password) async {
    final client =
        await _imapConnect(account, _effectiveUsername(account), password);
    try {
      final mailboxes = await client.listMailboxes(recursive: true);
      for (final mb in mailboxes) {
        final path = mb.path;
        final id = '${account.id}:$path';

        var unread = 0;
        var total = 0;
        try {
          final status = await client.statusMailbox(
            mb,
            [imap.StatusFlags.messages, imap.StatusFlags.unseen],
          );
          unread = status.messagesUnseen;
          total = status.messagesExists;
        } catch (e) {
          log('STATUS skipped for $path: $e');
        }

        await _db.into(_db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: id,
                accountId: account.id,
                path: path,
                name: mb.name,
                unreadCount: Value(unread),
                totalCount: Value(total),
              ),
            );
      }
    } finally {
      await client.logout();
    }
  }

  // ── JMAP ──────────────────────────────────────────────────────────────────

  Future<void> _syncMailboxesJmap(
      account_model.Account account, String password) async {
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

    final storedState = await _loadSyncState(account.id, 'Mailbox');

    if (storedState == null) {
      await _jmapFullMailboxSync(account.id, jmap);
    } else {
      await _jmapIncrementalMailboxSync(account.id, jmap, storedState);
    }
  }

  /// First-time sync: fetch all mailboxes and persist state.
  Future<void> _jmapFullMailboxSync(
      String accountId, JmapClient jmap) async {
    final responses = await jmap.call([
      [
        'Mailbox/get',
        {'accountId': jmap.accountId, 'ids': null},
        '0',
      ]
    ]);

    final result = _responseArgs(responses, 0, 'Mailbox/get');
    final mailboxes = result['list'] as List<dynamic>;
    final newState = result['state'] as String;

    await _upsertJmapMailboxes(accountId, mailboxes);
    await _saveSyncState(accountId, 'Mailbox', newState);
    log('JMAP full mailbox sync: ${mailboxes.length} mailboxes, state=$newState');
  }

  /// Incremental sync using Mailbox/changes since [sinceState].
  Future<void> _jmapIncrementalMailboxSync(
      String accountId, JmapClient jmap, String sinceState) async {
    final responses = await jmap.call([
      [
        'Mailbox/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ]
    ]);

    final changes = _responseArgs(responses, 0, 'Mailbox/changes');
    final newState = changes['newState'] as String;
    final created = List<String>.from(changes['created'] as List? ?? []);
    final updated = List<String>.from(changes['updated'] as List? ?? []);
    final destroyed = List<String>.from(changes['destroyed'] as List? ?? []);

    // Fetch details for created + updated mailboxes
    final toFetch = [...created, ...updated];
    if (toFetch.isNotEmpty) {
      final getResponses = await jmap.call([
        [
          'Mailbox/get',
          {'accountId': jmap.accountId, 'ids': toFetch},
          '1',
        ]
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Mailbox/get');
      await _upsertJmapMailboxes(
          accountId, getResult['list'] as List<dynamic>);
    }

    // Remove destroyed mailboxes
    for (final jmapId in destroyed) {
      await (_db.delete(_db.mailboxes)
            ..where((t) => t.id.equals('$accountId:$jmapId')))
          .go();
    }

    await _saveSyncState(accountId, 'Mailbox', newState);
    log('JMAP incremental mailbox sync: +${created.length} '
        '~${updated.length} -${destroyed.length}, state=$newState');
  }

  Future<void> _upsertJmapMailboxes(
      String accountId, List<dynamic> mailboxes) async {
    for (final mb in mailboxes) {
      final m = mb as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      final dbId = '$accountId:$jmapId';
      // For JMAP accounts, path stores the JMAP mailbox ID so that
      // Email rows can reference it via mailboxPath.
      await _db.into(_db.mailboxes).insertOnConflictUpdate(
            MailboxesCompanion.insert(
              id: dbId,
              accountId: accountId,
              path: jmapId,
              name: m['name'] as String? ?? jmapId,
              unreadCount: Value((m['unreadEmails'] as int?) ?? 0),
              totalCount: Value((m['totalEmails'] as int?) ?? 0),
            ),
          );
    }
  }

  // ── sync_state helpers ────────────────────────────────────────────────────

  Future<String?> _loadSyncState(String accountId, String resourceType) async {
    final row = await (_db.select(_db.syncStates)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.resourceType.equals(resourceType)))
        .getSingleOrNull();
    return row?.state;
  }

  Future<void> _saveSyncState(
      String accountId, String resourceType, String state) async {
    await _db.into(_db.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            accountId: accountId,
            resourceType: resourceType,
            state: state,
            syncedAt: DateTime.now(),
          ),
        );
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  /// Extracts the argument map from a methodResponse at [index].
  /// Throws [JmapException] if the response is an error.
  Map<String, dynamic> _responseArgs(
      List<dynamic> responses, int index, String expectedMethod) {
    final triple = responses[index] as List<dynamic>;
    final method = triple[0] as String;
    if (method == 'error') {
      final err = triple[1] as Map<String, dynamic>;
      throw JmapException('$expectedMethod error: ${err['type']}');
    }
    return triple[1] as Map<String, dynamic>;
  }

  model.Mailbox _toModel(MailboxRow row) => model.Mailbox(
        id: row.id,
        accountId: row.accountId,
        path: row.path,
        name: row.name,
        unreadCount: row.unreadCount,
        totalCount: row.totalCount,
      );
}
