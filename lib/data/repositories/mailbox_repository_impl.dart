import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:enough_mail/enough_mail.dart' as imap;
import 'package:http/http.dart' as http;

import 'package:sharedinbox/core/models/account.dart' as account_model;
import 'package:sharedinbox/core/models/mailbox.dart' as model;
import 'package:sharedinbox/core/repositories/account_repository.dart';
import 'package:sharedinbox/core/repositories/mailbox_repository.dart';
import 'package:sharedinbox/core/utils/logger.dart';
import 'package:sharedinbox/data/db/database.dart';
import 'package:sharedinbox/data/imap/imap_client_factory.dart';
import 'package:sharedinbox/data/jmap/jmap_client.dart';

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
  Stream<List<model.Mailbox>> observeMailboxes(String? accountId) {
    return (_db.select(_db.mailboxes)
          ..where((t) {
            if (accountId != null) return t.accountId.equals(accountId);
            return const Constant(true);
          })
          ..orderBy([(t) => OrderingTerm.asc(t.path)]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  @override
  Future<model.Mailbox?> findMailboxByRole(
    String accountId,
    String role,
  ) async {
    final row = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals(role),
          )
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  @override
  Future<int> syncMailboxes(String accountId) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _syncMailboxesImap(account, password);
      case account_model.AccountType.jmap:
        return _syncMailboxesJmap(account, password);
    }
  }

  // ── IMAP ──────────────────────────────────────────────────────────────────

  Future<int> _syncMailboxesImap(
    account_model.Account account,
    String password,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      final mailboxes = await client.listMailboxes(recursive: true);

      // Pre-load existing DB roles so we can preserve manually-set roles for
      // folders the server doesn't tag with a special-use attribute.
      final existingRows = await (_db.select(
        _db.mailboxes,
      )..where((t) => t.accountId.equals(account.id)))
          .get();
      final existingRoles = {for (final r in existingRows) r.id: r.role};

      // Reconcile server-side deletions: any locally cached mailbox that the
      // server no longer lists has been deleted upstream, so drop it (and its
      // cached emails / sync state) before upserting the survivors.
      final serverPaths = mailboxes.map((mb) => mb.path).toSet();
      await pruneLocalMailboxes(account.id, serverPaths);

      for (final mb in mailboxes) {
        final path = mb.path;
        final id = '${account.id}:$path';

        var unread = 0;
        var total = 0;
        try {
          final status = await client.statusMailbox(mb, [
            imap.StatusFlags.messages,
            imap.StatusFlags.unseen,
          ]);
          unread = status.messagesUnseen;
          total = status.messagesExists;
        } catch (e) {
          log('STATUS skipped for $path: $e');
        }

        // Use the server-assigned role when available; fall back to the
        // existing DB role so that manually-created folders (e.g. a user
        // who just created their Archive folder) keep their role across syncs
        // when the IMAP server does not expose a special-use attribute.
        final role = _imapRole(mb) ?? existingRoles[id];

        await _db.into(_db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: id,
                accountId: account.id,
                path: path,
                name: mb.name,
                unreadCount: Value(unread),
                totalCount: Value(total),
                role: Value(role),
                // IMAP paths are already hierarchical + human-readable, so the
                // display path just mirrors `path`.
                displayPath: Value(path),
              ),
            );
      }
      return mailboxes.length;
    } finally {
      await client.logout();
    }
  }

  // ── JMAP ──────────────────────────────────────────────────────────────────

  Future<int> _syncMailboxesJmap(
    account_model.Account account,
    String password,
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

    final storedState = await _loadSyncState(account.id, 'Mailbox');

    if (storedState == null) {
      return _jmapFullMailboxSync(account.id, jmap);
    } else {
      return _jmapIncrementalMailboxSync(account.id, jmap, storedState);
    }
  }

  /// First-time sync: fetch all mailboxes and persist state.
  Future<int> _jmapFullMailboxSync(String accountId, JmapClient jmap) async {
    final responses = await jmap.call([
      [
        'Mailbox/get',
        {'accountId': jmap.accountId, 'ids': null},
        '0',
      ],
    ]);

    final result = _responseArgs(responses, 0, 'Mailbox/get');
    final mailboxes = result['list'] as List<dynamic>;
    final newState = result['state'] as String;

    // Reconcile server-side deletions: for JMAP, `path` stores the opaque
    // server mailbox id, so we filter against the ids in the returned list.
    final serverIds = {
      for (final mb in mailboxes) (mb as Map<String, dynamic>)['id'] as String,
    };
    await pruneLocalMailboxes(accountId, serverIds);

    await _upsertJmapMailboxes(accountId, mailboxes);
    await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP full mailbox sync: ${mailboxes.length} mailboxes, state=$newState',
    );
    return mailboxes.length;
  }

  /// Incremental sync using Mailbox/changes since [sinceState].
  Future<int> _jmapIncrementalMailboxSync(
    String accountId,
    JmapClient jmap,
    String sinceState,
  ) async {
    final responses = await jmap.call([
      [
        'Mailbox/changes',
        {'accountId': jmap.accountId, 'sinceState': sinceState},
        '0',
      ],
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
        ],
      ]);
      final getResult = _responseArgs(getResponses, 0, 'Mailbox/get');
      await _upsertJmapMailboxes(accountId, getResult['list'] as List<dynamic>);
    }

    // Remove destroyed mailboxes (and their cached emails / sync state).
    for (final jmapId in destroyed) {
      await removeLocalMailbox(_db, accountId, jmapId);
    }

    await _saveSyncState(accountId, 'Mailbox', newState);
    log(
      'JMAP incremental mailbox sync: +${created.length} '
      '~${updated.length} -${destroyed.length}, state=$newState',
    );
    return toFetch.length + destroyed.length;
  }

  static String? _fallbackJmapRole(String? name) {
    if (name == null) return null;
    final lowerName = name.toLowerCase();
    if (lowerName == 'inbox') return 'inbox';
    if (lowerName == 'archive') return 'archive';
    if (lowerName == 'drafts' || lowerName == 'draft') return 'drafts';
    if (lowerName == 'trash' ||
        lowerName == 'deleted items' ||
        lowerName == 'deleted messages' ||
        lowerName == 'bin') {
      return 'trash';
    }
    if (lowerName == 'sent' ||
        lowerName == 'sent items' ||
        lowerName == 'sent messages') {
      return 'sent';
    }
    if (lowerName == 'junk' ||
        lowerName == 'junk mail' ||
        lowerName == 'spam') {
      return 'junk';
    }
    return null;
  }

  Future<void> _upsertJmapMailboxes(
    String accountId,
    List<dynamic> mailboxes,
  ) async {
    // For JMAP, `path` stores the opaque mailbox ID (so Email rows can
    // reference it via mailboxPath) but the UI wants the hierarchical,
    // human-readable path — e.g. "Archive/2026". Build that by walking each
    // mailbox's `parentId` chain and joining `name`s with '/'. Missing links
    // (parent not in this batch and not in the local cache) fall back to
    // the leaf name, so we always store something readable.
    final incoming = <String, Map<String, dynamic>>{};
    for (final mb in mailboxes) {
      final m = mb as Map<String, dynamic>;
      incoming[m['id'] as String] = m;
    }

    // Prime with previously-synced mailboxes so partial updates can still
    // resolve parents that aren't in the current batch.
    final cachedRows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final cachedName = <String, String>{};
    final cachedParent = <String, String?>{};
    for (final row in cachedRows) {
      cachedName[row.path] = row.name;
      cachedParent[row.path] = row.parentId;
    }

    String nameOf(String id) =>
        (incoming[id]?['name'] as String?) ?? cachedName[id] ?? id;
    String? parentOf(String id) {
      final m = incoming[id];
      if (m != null) return m['parentId'] as String?;
      return cachedParent[id];
    }

    String buildDisplayPath(String startId) {
      final parts = <String>[];
      var current = startId;
      final seen = <String>{};
      while (seen.add(current)) {
        parts.insert(0, nameOf(current));
        final parent = parentOf(current);
        if (parent == null || parent.isEmpty) break;
        current = parent;
      }
      return parts.join('/');
    }

    for (final mb in mailboxes) {
      final m = mb as Map<String, dynamic>;
      final jmapId = m['id'] as String;
      final dbId = '$accountId:$jmapId';
      final name = m['name'] as String? ?? jmapId;
      final role = m['role'] as String? ?? _fallbackJmapRole(name);
      final displayPath = buildDisplayPath(jmapId);
      await _db.into(_db.mailboxes).insertOnConflictUpdate(
            MailboxesCompanion.insert(
              id: dbId,
              accountId: accountId,
              path: jmapId,
              name: name,
              unreadCount: Value((m['unreadEmails'] as int?) ?? 0),
              totalCount: Value((m['totalEmails'] as int?) ?? 0),
              role: Value(role),
              displayPath: Value(displayPath),
              parentId: Value(m['parentId'] as String?),
            ),
          );
    }

    // When a parent's name changes, every descendant's displayPath goes stale.
    // Fix up every mailbox in the account whose displayPath no longer matches
    // its recomputed value. Cheap: mailboxes are few and rows already in cache.
    final refreshedRows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    for (final row in refreshedRows) {
      cachedName[row.path] = row.name;
      cachedParent[row.path] = row.parentId;
    }
    for (final row in refreshedRows) {
      if (incoming.containsKey(row.path)) continue;
      final rebuilt = buildDisplayPath(row.path);
      if (rebuilt != row.displayPath) {
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
            .write(MailboxesCompanion(displayPath: Value(rebuilt)));
      }
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

  // ── helpers ───────────────────────────────────────────────────────────────

  /// Extracts the argument map from a methodResponse at [index].
  /// Throws [JmapException] if the response is an error.
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

  model.Mailbox _toModel(MailboxRow row) => model.Mailbox(
        id: row.id,
        accountId: row.accountId,
        path: row.path,
        name: row.name,
        // Fall back to `path` when display_path is empty (row predates the
        // v47 migration, or was inserted by test setup with the older API).
        displayPath: row.displayPath.isEmpty ? row.path : row.displayPath,
        parentId: row.parentId,
        unreadCount: row.unreadCount,
        totalCount: row.totalCount,
        role: row.role,
      );

  /// Maps enough_mail special-use flags (RFC 6154) to JMAP role strings (RFC 8621).
  static String? _imapRole(imap.Mailbox mb) {
    if (mb.isInbox) {
      return 'inbox';
    }
    if (mb.isArchive) {
      return 'archive';
    }
    if (mb.isTrash) {
      return 'trash';
    }
    if (mb.isSent) {
      return 'sent';
    }
    if (mb.isDrafts) {
      return 'drafts';
    }
    if (mb.isJunk) {
      return 'junk';
    }

    // Name-based fallback for servers that do not support special-use flags
    final name = mb.name.toLowerCase();
    if (name == 'inbox') {
      return 'inbox';
    }
    if (name == 'archive') {
      return 'archive';
    }
    if (name == 'drafts' || name == 'draft') {
      return 'drafts';
    }
    if (name == 'trash' ||
        name == 'deleted items' ||
        name == 'deleted messages' ||
        name == 'bin') {
      return 'trash';
    }
    if (name == 'sent' || name == 'sent items' || name == 'sent messages') {
      return 'sent';
    }
    if (name == 'junk' || name == 'junk mail' || name == 'spam') {
      return 'junk';
    }

    return null;
  }

  @override
  Future<void> clearForResync(String accountId) async {
    await (_db.delete(
      _db.mailboxes,
    )..where((t) => t.accountId.equals(accountId)))
        .go();
  }

  /// Removes any locally cached mailbox for [accountId] whose `path` is not
  /// in [keepPaths] (paths the server still advertises). Cascade-deletes the
  /// related emails, threads, sync checkpoints, and queued pending changes.
  ///
  /// Public so [EmailRepositoryImpl] can call it when a `SELECT` blows up with
  /// `NONEXISTENT` between mailbox-sync and email-sync of the same cycle.
  Future<void> pruneLocalMailboxes(
    String accountId,
    Set<String> keepPaths,
  ) async {
    final existing = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    for (final row in existing) {
      if (keepPaths.contains(row.path)) continue;
      log('Mailbox "${row.path}" deleted on server — removing local cache');
      await removeLocalMailbox(_db, accountId, row.path);
    }
  }

  @override
  Future<model.Mailbox> createMailboxWithRole(
    String accountId,
    String name,
    String role, {
    String? parentDisplayPath,
  }) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final parent = await _findParent(accountId, parentDisplayPath);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _createMailboxWithRoleImap(
          account,
          password,
          name,
          role,
          parent,
        );
      case account_model.AccountType.jmap:
        return _createMailboxWithRoleJmap(
          account,
          password,
          name,
          role,
          parent,
        );
    }
  }

  @override
  Future<model.Mailbox> createMailbox(
    String accountId,
    String name, {
    String? parentDisplayPath,
  }) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final parent = await _findParent(accountId, parentDisplayPath);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _createMailboxWithRoleImap(
          account,
          password,
          name,
          null,
          parent,
        );
      case account_model.AccountType.jmap:
        return _createMailboxWithRoleJmap(
          account,
          password,
          name,
          null,
          parent,
        );
    }
  }

  /// Looks up the local mailbox row whose `displayPath` matches
  /// [parentDisplayPath]. Throws when a non-null displayPath does not resolve —
  /// creating a child under a parent that isn't in the local cache would leave
  /// the new mailbox unreachable in the UI's tree.
  Future<MailboxRow?> _findParent(
    String accountId,
    String? parentDisplayPath,
  ) async {
    if (parentDisplayPath == null || parentDisplayPath.isEmpty) return null;
    final row = await (_db.select(_db.mailboxes)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.displayPath.equals(parentDisplayPath),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      throw Exception(
        'Parent mailbox "$parentDisplayPath" not found in local cache',
      );
    }
    return row;
  }

  Future<model.Mailbox> _createMailboxWithRoleImap(
    account_model.Account account,
    String password,
    String name,
    String? role,
    MailboxRow? parent,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    String serverPath;
    try {
      if (parent != null) {
        // Discover the server's hierarchy separator so we can build a valid
        // subfolder path — LIST is cheap and every server responds with at
        // least INBOX, whose pathSeparator is the same for all mailboxes.
        final separator = await _imapPathSeparator(client, parent);
        serverPath = '${parent.path}$separator$name';
      } else {
        serverPath = name;
      }
      await client.createMailbox(serverPath);
    } finally {
      await client.logout();
    }
    final displayPath = parent != null ? '${parent.displayPath}/$name' : name;
    final id = '${account.id}:$serverPath';
    await _db.into(_db.mailboxes).insertOnConflictUpdate(
          MailboxesCompanion.insert(
            id: id,
            accountId: account.id,
            path: serverPath,
            name: name,
            role: Value(role),
            displayPath: Value(displayPath),
          ),
        );
    final row = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.id.equals(id)))
        .getSingle();
    return _toModel(row);
  }

  /// Returns the IMAP hierarchy separator to use when creating a subfolder
  /// of [parent]. Derives it from the parent's own path when possible
  /// (works for any hierarchical mailbox), otherwise asks the server via
  /// LIST. Falls back to `/` if the server returns nothing usable.
  Future<String> _imapPathSeparator(
    imap.ImapClient client,
    MailboxRow parent,
  ) async {
    if (parent.path.contains('/')) return '/';
    if (parent.path.contains('.')) return '.';
    final listed = await client.listMailboxes();
    if (listed.isNotEmpty && listed.first.pathSeparator.isNotEmpty) {
      return listed.first.pathSeparator;
    }
    return '/';
  }

  Future<model.Mailbox> _createMailboxWithRoleJmap(
    account_model.Account account,
    String password,
    String name,
    String? role,
    MailboxRow? parent,
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
    final responses = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'create': {
            'new-mailbox': {
              'name': name,
              if (role != null) 'role': role,
              if (parent != null) 'parentId': parent.path,
            },
          },
        },
        '0',
      ],
    ]);
    final result = _responseArgs(responses, 0, 'Mailbox/set');
    final created = result['created'] as Map<String, dynamic>?;
    final newId =
        (created?['new-mailbox'] as Map<String, dynamic>?)?['id'] as String?;
    if (newId == null) {
      throw Exception(
        'Failed to create mailbox "$name": server returned no ID',
      );
    }
    final dbId = '${account.id}:$newId';
    // Compute the new mailbox's displayPath by prefixing the parent's chain
    // (matching the walk in [_upsertJmapMailboxes]). Without a parent, the
    // display path is just the name — the next full sync will confirm.
    final displayPath = parent != null ? '${parent.displayPath}/$name' : name;
    await _db.into(_db.mailboxes).insertOnConflictUpdate(
          MailboxesCompanion.insert(
            id: dbId,
            accountId: account.id,
            path: newId,
            name: name,
            role: Value(role),
            displayPath: Value(displayPath),
            parentId: Value(parent?.path),
          ),
        );
    final row = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.id.equals(dbId)))
        .getSingle();
    return _toModel(row);
  }

  // ── rename / delete / move ──────────────────────────────────────────────

  @override
  Future<model.Mailbox> renameMailbox(
    String accountId,
    String mailboxPath,
    String newName,
  ) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'Name must not be empty');
    }
    if (trimmed.contains('/')) {
      throw ArgumentError.value(
        newName,
        'newName',
        'Name must not contain "/"',
      );
    }
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final row = await _requireRow(accountId, mailboxPath);
    switch (account.type) {
      case account_model.AccountType.imap:
        return _renameMailboxImap(account, password, row, trimmed);
      case account_model.AccountType.jmap:
        return _renameMailboxJmap(account, password, row, trimmed);
    }
  }

  @override
  Future<void> deleteMailbox(String accountId, String mailboxPath) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final row = await _requireRow(accountId, mailboxPath);
    switch (account.type) {
      case account_model.AccountType.imap:
        await _deleteMailboxImap(account, password, row);
      case account_model.AccountType.jmap:
        await _deleteMailboxJmap(account, password, row);
    }
    await removeLocalMailbox(_db, accountId, row.path);
  }

  @override
  Future<model.Mailbox> moveMailbox(
    String accountId,
    String mailboxPath, {
    required String? newParentDisplayPath,
  }) async {
    final account = (await _accounts.getAccount(accountId))!;
    final password = await _accounts.getPassword(accountId);
    final row = await _requireRow(accountId, mailboxPath);
    final newParent = await _findParent(accountId, newParentDisplayPath);
    if (newParent != null && newParent.id == row.id) {
      throw Exception('Cannot move a folder into itself');
    }
    if (newParent != null &&
        newParent.displayPath.startsWith('${row.displayPath}/')) {
      throw Exception('Cannot move a folder into one of its descendants');
    }
    switch (account.type) {
      case account_model.AccountType.imap:
        return _moveMailboxImap(account, password, row, newParent);
      case account_model.AccountType.jmap:
        return _moveMailboxJmap(account, password, row, newParent);
    }
  }

  Future<MailboxRow> _requireRow(String accountId, String mailboxPath) async {
    final row = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.path.equals(mailboxPath),
          )
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      throw Exception('Mailbox "$mailboxPath" not found in local cache');
    }
    return row;
  }

  // ── IMAP: rename / delete / move ────────────────────────────────────────

  Future<model.Mailbox> _renameMailboxImap(
    account_model.Account account,
    String password,
    MailboxRow row,
    String newName,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    String newServerPath;
    try {
      final separator = await _imapPathSeparator(client, row);
      final parts = row.path.split(separator);
      parts[parts.length - 1] = newName;
      newServerPath = parts.join(separator);
      // IMAP RENAME's second argument is the full destination path.
      await client.renameMailbox(_imapBoxFor(row), newServerPath);
    } finally {
      await client.logout();
    }
    return _applyImapPathRewrite(row, newServerPath, newName);
  }

  Future<void> _deleteMailboxImap(
    account_model.Account account,
    String password,
    MailboxRow row,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    try {
      await client.deleteMailbox(_imapBoxFor(row));
    } finally {
      await client.logout();
    }
  }

  Future<model.Mailbox> _moveMailboxImap(
    account_model.Account account,
    String password,
    MailboxRow row,
    MailboxRow? newParent,
  ) async {
    final client = await _imapConnect(
      account,
      _effectiveUsername(account),
      password,
    );
    String newServerPath;
    try {
      final separator = await _imapPathSeparator(client, row);
      newServerPath = newParent == null
          ? row.name
          : '${newParent.path}$separator${row.name}';
      // IMAP RENAME can both rename and relocate a mailbox.
      await client.renameMailbox(_imapBoxFor(row), newServerPath);
    } finally {
      await client.logout();
    }
    return _applyImapPathRewrite(row, newServerPath, row.name);
  }

  imap.Mailbox _imapBoxFor(MailboxRow row) => imap.Mailbox(
        encodedName: row.path,
        encodedPath: row.path,
        flags: <imap.MailboxFlag>[],
        pathSeparator: row.path.contains('.') ? '.' : '/',
      );

  /// Rewrites the local rows for [row] and every descendant so `path`,
  /// `displayPath`, and `name` reflect the new server path. IMAP `path`
  /// equals its hierarchical location, so relocating a folder cascades to
  /// every child. Also rewrites `emails.mailboxPath`, `threads.mailboxPath`
  /// and the `IMAP:$path` sync checkpoint so the local cache follows the
  /// server. Returns the updated [Mailbox] for the top row.
  Future<model.Mailbox> _applyImapPathRewrite(
    MailboxRow row,
    String newPath,
    String newName,
  ) async {
    final oldPath = row.path;
    if (oldPath == newPath && row.name == newName) {
      return _toModel(row);
    }
    final allRows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(row.accountId)))
        .get();
    // Only rewrite the row itself and its actual children; a LIKE prefix
    // match would also catch unrelated siblings like `INBOX/Workplace`.
    final descendants = [
      for (final r in allRows)
        if (r.path == oldPath ||
            r.path.startsWith('$oldPath/') ||
            r.path.startsWith('$oldPath.'))
          r,
    ];
    final newId = '${row.accountId}:$newPath';
    await _db.transaction(() async {
      for (final d in descendants) {
        final suffix = d.path.substring(oldPath.length);
        final rewrittenPath = '$newPath$suffix';
        final rewrittenId = '${row.accountId}:$rewrittenPath';
        final rewrittenName = d.id == row.id ? newName : d.name;
        await (_db.delete(_db.mailboxes)..where((t) => t.id.equals(d.id))).go();
        await _db.into(_db.mailboxes).insertOnConflictUpdate(
              MailboxesCompanion.insert(
                id: rewrittenId,
                accountId: d.accountId,
                path: rewrittenPath,
                name: rewrittenName,
                unreadCount: Value(d.unreadCount),
                totalCount: Value(d.totalCount),
                role: Value(d.role),
                displayPath: Value(rewrittenPath),
                parentId: Value(d.parentId),
              ),
            );
        await (_db.update(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(d.accountId) &
                    t.mailboxPath.equals(d.path),
              ))
            .write(EmailsCompanion(mailboxPath: Value(rewrittenPath)));
        await (_db.update(_db.threads)
              ..where(
                (t) =>
                    t.accountId.equals(d.accountId) &
                    t.mailboxPath.equals(d.path),
              ))
            .write(ThreadsCompanion(mailboxPath: Value(rewrittenPath)));
        // resource_type is part of the (accountId, resourceType) primary key,
        // so UPDATE can hit a collision. Rewriting the row via delete+insert
        // is safe and avoids a "UNIQUE constraint failed" from Drift.
        final oldStates = await (_db.select(_db.syncStates)
              ..where(
                (t) =>
                    t.accountId.equals(d.accountId) &
                    t.resourceType.equals('IMAP:${d.path}'),
              ))
            .get();
        for (final s in oldStates) {
          await (_db.delete(_db.syncStates)
                ..where(
                  (t) =>
                      t.accountId.equals(s.accountId) &
                      t.resourceType.equals(s.resourceType),
                ))
              .go();
          await _db.into(_db.syncStates).insertOnConflictUpdate(
                SyncStatesCompanion.insert(
                  accountId: s.accountId,
                  resourceType: 'IMAP:$rewrittenPath',
                  state: s.state,
                  syncedAt: s.syncedAt,
                ),
              );
        }
      }
    });
    final refreshed = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.id.equals(newId)))
        .getSingle();
    return _toModel(refreshed);
  }

  // ── JMAP: rename / delete / move ────────────────────────────────────────

  Future<JmapClient> _connectJmap(
    account_model.Account account,
    String password,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) {
      throw Exception('JMAP account ${account.id} has no jmapUrl');
    }
    return JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );
  }

  Future<model.Mailbox> _renameMailboxJmap(
    account_model.Account account,
    String password,
    MailboxRow row,
    String newName,
  ) async {
    final jmap = await _connectJmap(account, password);
    final responses = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'update': {
            row.path: {'name': newName},
          },
        },
        '0',
      ],
    ]);
    _requireJmapUpdated(responses, row.path);
    await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
        .write(MailboxesCompanion(name: Value(newName)));
    await _rebuildJmapDisplayPaths(row.accountId);
    final refreshed = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.id.equals(row.id)))
        .getSingle();
    return _toModel(refreshed);
  }

  Future<void> _deleteMailboxJmap(
    account_model.Account account,
    String password,
    MailboxRow row,
  ) async {
    final jmap = await _connectJmap(account, password);
    final responses = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'destroy': [row.path],
        },
        '0',
      ],
    ]);
    _requireJmapDestroyed(responses, row.path);
  }

  Future<model.Mailbox> _moveMailboxJmap(
    account_model.Account account,
    String password,
    MailboxRow row,
    MailboxRow? newParent,
  ) async {
    final jmap = await _connectJmap(account, password);
    final responses = await jmap.call([
      [
        'Mailbox/set',
        {
          'accountId': jmap.accountId,
          'update': {
            row.path: {'parentId': newParent?.path},
          },
        },
        '0',
      ],
    ]);
    _requireJmapUpdated(responses, row.path);
    await (_db.update(_db.mailboxes)..where((t) => t.id.equals(row.id)))
        .write(MailboxesCompanion(parentId: Value(newParent?.path)));
    await _rebuildJmapDisplayPaths(row.accountId);
    final refreshed = await (_db.select(
      _db.mailboxes,
    )..where((t) => t.id.equals(row.id)))
        .getSingle();
    return _toModel(refreshed);
  }

  void _requireJmapUpdated(List<dynamic> responses, String jmapId) {
    final result = _responseArgs(responses, 0, 'Mailbox/set');
    final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
    if (notUpdated != null && notUpdated.containsKey(jmapId)) {
      final err = notUpdated[jmapId] as Map<String, dynamic>;
      throw Exception('Mailbox/set update failed: ${err['type']}');
    }
  }

  void _requireJmapDestroyed(List<dynamic> responses, String jmapId) {
    final result = _responseArgs(responses, 0, 'Mailbox/set');
    final notDestroyed = result['notDestroyed'] as Map<String, dynamic>?;
    if (notDestroyed != null && notDestroyed.containsKey(jmapId)) {
      final err = notDestroyed[jmapId] as Map<String, dynamic>;
      throw Exception('Mailbox/set destroy failed: ${err['type']}');
    }
  }

  /// Recomputes `displayPath` for every locally cached JMAP mailbox in
  /// [accountId] by walking the `parentId` chain. Used after a rename or move
  /// so every descendant of the changed folder reflects the new tree layout.
  Future<void> _rebuildJmapDisplayPaths(String accountId) async {
    final rows = await (_db.select(_db.mailboxes)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    final byPath = {for (final r in rows) r.path: r};
    String buildDisplayPath(String startId) {
      final parts = <String>[];
      var current = startId;
      final seen = <String>{};
      while (seen.add(current)) {
        final r = byPath[current];
        if (r == null) {
          parts.insert(0, current);
          break;
        }
        parts.insert(0, r.name);
        final parent = r.parentId;
        if (parent == null || parent.isEmpty) break;
        current = parent;
      }
      return parts.join('/');
    }

    for (final r in rows) {
      final rebuilt = buildDisplayPath(r.path);
      if (rebuilt != r.displayPath) {
        await (_db.update(_db.mailboxes)..where((t) => t.id.equals(r.id)))
            .write(MailboxesCompanion(displayPath: Value(rebuilt)));
      }
    }
  }
}

/// Deletes the local cache rows that belong to a single mailbox that no
/// longer exists on the server.
///
/// Removes the row in `mailboxes`, every `emails` row whose `mailboxPath`
/// matches (which cascades into `email_bodies`), every `threads` row, the
/// IMAP per-mailbox checkpoint in `sync_states`, and any `pending_changes`
/// rows whose JSON payload references the path as `mailboxPath`, `src` or
/// `dest`. Idempotent — safe to call when nothing matches.
Future<void> removeLocalMailbox(
  AppDatabase db,
  String accountId,
  String path,
) async {
  await db.transaction(() async {
    await (db.delete(db.emails)
          ..where(
            (t) => t.accountId.equals(accountId) & t.mailboxPath.equals(path),
          ))
        .go();
    await (db.delete(db.threads)
          ..where(
            (t) => t.accountId.equals(accountId) & t.mailboxPath.equals(path),
          ))
        .go();
    await (db.delete(db.syncStates)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.resourceType.equals('IMAP:$path'),
          ))
        .go();

    // pending_changes payloads are protocol-specific JSON; drop any row
    // referring to the gone path so the queue doesn't keep retrying.
    final pending = await (db.select(db.pendingChanges)
          ..where((t) => t.accountId.equals(accountId)))
        .get();
    for (final row in pending) {
      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row.payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final refs = [payload['mailboxPath'], payload['src'], payload['dest']];
      if (refs.contains(path)) {
        await (db.delete(db.pendingChanges)..where((t) => t.id.equals(row.id)))
            .go();
      }
    }

    await (db.delete(db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.path.equals(path),
          ))
        .go();
  });
}
