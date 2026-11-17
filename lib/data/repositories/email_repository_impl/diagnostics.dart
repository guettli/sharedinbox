part of '../email_repository_impl.dart';

// Diagnostics: the mailbox diagnosis and the sync reliability probe.

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

extension _Diagnostics on EmailRepositoryImpl {
  // ── Sync Reliability ──────────────────────────────────────────────────────

  Future<model.ReliabilityResult> _verifySyncReliability(
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

  Future<model.MailboxDiagnostics> _diagnoseMailbox(
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
    final client = await _connectImapAs(account, password);
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
    final localIdSet = {
      for (final r in localRows)
        if (r.srvJmapId != null) r.srvJmapId!,
    };

    final missingLocally = [
      for (final id in allServerIds)
        if (!localIdSet.contains(id)) id,
    ];
    final missingOnServer = [
      for (final row in localRows)
        if (!serverIdSet.contains(row.srvJmapId)) row.id,
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
    final client = await _connectImapAs(account, password);
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
    final localIdSet = {
      for (final r in localRows)
        if (r.srvJmapId != null) r.srvJmapId!,
    };

    final missingLocally = <String>[];
    for (final id in allServerIds) {
      if (!localIdSet.contains(id)) {
        missingLocally.add(id);
      }
    }

    final missingOnServer = <String>[];
    for (final row in localRows) {
      if (!serverIdSet.contains(row.srvJmapId)) {
        missingOnServer.add(row.id);
      }
    }

    final flagMismatches = <model.FlagMismatch>[];
    if (allServerIds.isNotEmpty) {
      final localMap = {
        for (final r in localRows)
          if (r.srvJmapId != null) r.srvJmapId!: r,
      };

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
}
