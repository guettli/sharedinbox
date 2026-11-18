part of '../email_repository_impl.dart';

// Reads: observe streams, single-row lookups, search and the structured
// filter.

/// SQL `ORDER BY` of the mail search results (table alias `e`): starred
/// first, then [model.compareNewestFirst]. Searches span folders and
/// accounts, whose UIDs are not comparable; there the UID tiebreak only
/// makes the order deterministic.
const _emailListOrderSql =
    'e.is_flagged DESC, e.received_at DESC, e.uid DESC, e.id DESC';

/// Not a hidden row: one deleted for good, or gone on the server, has the
/// empty string as its `mailbox_path` (SYNC-REDESIGN.md §2); nor a mail
/// shown in a folder whose delete is queued (`mailboxes.local_hidden`,
/// phase 5b): the folder shows nowhere, so its mail does not either (in
/// search, by address, by thread, by id). Queries that filter by a folder
/// exclude it already; the others add this. A watched query using it also
/// re-runs when a folder's `local_hidden` changes (phase 6b), so an open
/// thread drops the mail of a folder just deleted at once.
Expression<bool> _visible($EmailsTable t) =>
    t.mailboxPath.equals('').not() &
    CustomExpression<bool>(
      'NOT (${_inHiddenFolderSql(t.aliasedName)})',
      watchedTables: [(t.attachedDatabase as AppDatabase).mailboxes],
    );

/// SQL (correlated on the `emails` alias [e]): the mail shows in a folder
/// whose delete is queued.
String _inHiddenFolderSql(String e) =>
    'EXISTS (SELECT 1 FROM mailboxes hm WHERE hm.account_id = $e.account_id '
    'AND hm.path = $e.mailbox_path AND hm.local_hidden = 1)';

/// Escapes characters that would break out of a JSON string literal.
String _jsonEsc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

/// Escapes SQL LIKE meta-characters (`%`, `_`) with a leading `!`; the
/// caller must pair this with `escapeChar: '!'` on the LIKE call. `!` is
/// used instead of `\` so it never collides with the literal backslashes
/// that JSON encoding inserts into the header value.
String _likeEsc(String s) =>
    s.replaceAll('!', '!!').replaceAll('%', '!%').replaceAll('_', '!_');

/// Converts a glob pattern to a SQL LIKE pattern, escaping LIKE
/// meta-characters with `!` to match the escape char used by [_Queries._headerLike].
String _globToLikeBang(String glob) {
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

String _globToLike(String glob) {
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
///
/// The query is first split on whitespace into the chunks the user actually
/// typed. Each chunk becomes a quoted prefix phrase: `foo` → `"foo" *`, so
/// partial words still match while typing. A punctuated chunk (`foo.com`)
/// becomes the adjacent phrase `"foo com" *`: the default `unicode61`
/// tokenizer splits on the punctuation on the index side too, so requiring
/// the tokens to stay adjacent is the closest FTS5 can get to an exact
/// "foo.com" match — and, unlike the old `foo* com*`, it no longer matches
/// mails that merely contain `foo` and `com` far apart (#806). The trailing
/// `*` keeps prefix matching on the last token (`foo.co` → `"foo co" *`).
/// Separate chunks are still combined with FTS5's implicit AND, so
/// `foo com` finds mails containing both words anywhere.
///
/// The quotes keep a typed `AND`, `OR` or `NOT` a plain word: unquoted, FTS5
/// reads it as an operator and the search fails with a syntax error.
///
/// Every Unicode letter, mark and digit counts as part of a word. Dart's
/// `\w` is ASCII-only, so `Müller` used to become the phrase `"M ller"` and
/// `Привет` an empty query, and neither found anything. unicode61 does not
/// split CJK text into words, so there only a prefix of the whole run
/// matches (`東京` finds `東京駅`, `駅` does not).
String _toFtsQuery(String query) {
  final terms = <String>[];
  for (final chunk in query.trim().split(RegExp(r'\s+'))) {
    final tokens =
        chunk.split(_nonWordChars).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) continue;
    terms.add('"${tokens.join(' ')}" *');
  }
  return terms.join(' ');
}

final _nonWordChars = RegExp(r'[^\p{L}\p{M}\p{N}_]+', unicode: true);

extension _Queries on EmailRepositoryImpl {
  // ── Observe ────────────────────────────────────────────────────────────────

  Stream<List<model.Email>> _observeEmails(
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
          // Mail from the same second: highest UID (newest arrival) first.
          // `id` makes rows with equal UIDs (JMAP, local) deterministic.
          // Matches the `emails_list_order` index.
          ..orderBy([
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Stream<List<model.EmailThread>> _observeThreads(
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
          // Matches the `threads_list_order` index; see [observeEmails] for
          // the tiebreakers.
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.latestDate),
            (t) => OrderingTerm.desc(t.latestUid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .watch()
        .map((rows) => rows.map(_threadRowToModel).toList());
  }

  Stream<List<model.EmailThread>> _observeAllInboxThreads({int limit = 50}) {
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
        // UIDs of different accounts are not comparable: across inboxes
        // this tiebreak only makes the order deterministic.
        OrderingTerm.desc(_db.threads.latestUid),
        OrderingTerm.desc(_db.threads.id),
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

  /// The mail [emailId], or null when it is gone or hidden (deleted for
  /// good, or no longer on the server): the detail view and a notification
  /// tap show "deleted" then (SYNC-REDESIGN.md §2).
  Future<model.Email?> _getEmail(String emailId) async {
    final row = await (_db.select(
      _db.emails,
    )..where((t) => t.id.equals(emailId) & _visible(t)))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  Future<model.Email?> _findEmailByMessageId(
    String accountId,
    String messageId, {
    String? preferMailboxPath,
  }) async {
    final row = await (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.messageId.equals(messageId) &
                _visible(t),
          )
          ..orderBy([
            if (preferMailboxPath != null)
              (t) => OrderingTerm.desc(t.mailboxPath.equals(preferMailboxPath)),
          ])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _toModel(row);
  }

  Future<List<model.Email>> _searchEmailsGlobal(
    String? accountId,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsLocal(
        accountId: accountId,
        mailboxPath: null,
        query: query,
        limit: limit,
      );

  /// Shared body of [searchEmails] and [searchEmailsGlobal]: the subject/
  /// preview/From FTS hits merged with the note and body hits, deduplicated,
  /// flagged then newest first, capped at [limit].
  ///
  /// Each source returns its own first [limit] rows in that same order, so
  /// the first [limit] of the merge are exactly the first [limit] of the full
  /// union — growing [limit] (the UI's "Load more") extends the list without
  /// reordering what is already shown.
  Future<List<model.Email>> _searchEmailsLocal({
    required String? accountId,
    required String? mailboxPath,
    required String query,
    required int limit,
  }) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty || limit <= 0) return [];

    final subjectRows = await _searchEmailsByFts(
      fromJoin: 'FROM email_fts f JOIN emails e ON e.rowid = f.rowid',
      ftsTable: 'email_fts',
      readsFrom: {_db.emails},
      accountId: accountId,
      mailboxPath: mailboxPath,
      query: query,
      limit: limit,
      // email_fts maps 1:1 onto emails by rowid: no duplicates to collapse.
      distinct: false,
    );
    final noteRows =
        await _searchEmailsByNotes(accountId, mailboxPath, query, limit);
    final bodyRows =
        await _searchEmailsByBody(accountId, mailboxPath, query, limit);

    final seen = <String>{};
    final merged = <model.Email>[];
    for (final e in [...subjectRows, ...noteRows, ...bodyRows]) {
      if (seen.add(e.id)) merged.add(e);
    }
    merged.sort(model.compareFlaggedThenNewest);
    return merged.length > limit ? merged.sublist(0, limit) : merged;
  }

  /// Returns emails whose plaintext body matches [query] via the
  /// `email_body_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByBody(
    String? accountId,
    String? mailboxPath,
    String query,
    int limit,
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
        limit: limit,
      );

  /// Returns emails whose associated notes match [query] via the
  /// `email_notes_fts` FTS5 index. Optionally filtered by [accountId] and
  /// [mailboxPath].
  Future<List<model.Email>> _searchEmailsByNotes(
    String? accountId,
    String? mailboxPath,
    String query,
    int limit,
  ) =>
      _searchEmailsByFts(
        fromJoin: 'FROM email_notes_fts f'
            ' JOIN email_notes n ON n.rowid = f.rowid'
            ' JOIN emails e ON e.message_id = n.message_id'
            ' AND e.account_id = n.account_id'
            // Deleted locally, still waiting for the server delete.
            ' AND n.pending_delete = 0',
        ftsTable: 'email_notes_fts',
        readsFrom: {_db.emails, _db.emailNotes},
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
        limit: limit,
      );

  /// Runs an FTS5 `MATCH` search whose hits resolve back to `emails` (aliased
  /// `e`) and returns them as models, flagged and newest first. [fromJoin] is
  /// the `FROM …` clause joining the [ftsTable] shadow index to `emails`;
  /// [ftsTable] is the virtual-table name used in the `MATCH` predicate.
  /// Optionally filtered by [accountId] and [mailboxPath]; at most [limit]
  /// rows. Shared by the subject, body and note search paths.
  Future<List<model.Email>> _searchEmailsByFts({
    required String fromJoin,
    required String ftsTable,
    required Set<ResultSetImplementation> readsFrom,
    required String? accountId,
    required String? mailboxPath,
    required String query,
    required int limit,
    bool distinct = true,
  }) async {
    final ftsQuery = _toFtsQuery(query);
    if (ftsQuery.isEmpty) return [];

    // Not a hidden row (SYNC-REDESIGN.md §2).
    final extraConditions = StringBuffer(
      " AND e.mailbox_path <> '' AND NOT (${_inHiddenFolderSql('e')})",
    );
    final extraVars = <Variable<String>>[];
    if (accountId != null) {
      extraConditions.write(' AND e.account_id = ?');
      extraVars.add(Variable<String>(accountId));
    }
    if (mailboxPath != null) {
      extraConditions.write(' AND e.mailbox_path = ?');
      extraVars.add(Variable<String>(mailboxPath));
    }

    final sql = 'SELECT${distinct ? ' DISTINCT' : ''} e.* $fromJoin'
        ' WHERE $ftsTable MATCH ?$extraConditions'
        ' ORDER BY $_emailListOrderSql LIMIT ?';

    final rows = await _db
        .customSelect(
          sql,
          variables: [
            Variable<String>(ftsQuery),
            ...extraVars,
            Variable<int>(limit),
          ],
          readsFrom: readsFrom,
        )
        .get();
    final emailRows =
        await Future.wait(rows.map((r) => _db.emails.mapFromRow(r)));
    return emailRows.map(_toModel).toList();
  }

  Future<List<model.Email>> _searchEmailsStructured(
    String? accountId,
    FilterGroup filter, {
    int limit = searchPageSize,
  }) async {
    final rows = await (_db.select(_db.emails)
          ..where((t) {
            final fe = _filterGroup(filter, t) & _visible(t);
            if (accountId == null) return fe;
            return t.accountId.equals(accountId) & fe;
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.isFlagged),
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
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
      FilterField.size => _sizeCompare(t.sizeBytes, leaf),
      FilterField.header => _headerLike(leaf, t),
      // `is` compares the whole stored path, ignoring ASCII case. Not LIKE:
      // that lowercased the value first, and as SQLite folds only ASCII case
      // a non-ASCII path ("Übersicht") never matched; `_`/`%` in a path also
      // acted as wildcards.
      FilterField.folder => leaf.comparison == FilterComparison.is_
          ? t.mailboxPath.collate(Collate.noCase).equals(leaf.value)
          : const Constant(false),
    };
  }

  /// Compares the stored message size. An unparseable value matches
  /// nothing (the editors refuse it), and so does a row whose size is unknown
  /// (NULL: cached before schema v64 and not yet backfilled by a reconcile):
  /// SQL `NULL > n` is not true.
  Expression<bool> _sizeCompare(GeneratedColumn<int> col, FilterLeaf leaf) {
    final bytes = parseFilterSize(leaf.value);
    if (bytes == null) return const Constant(false);
    return switch (leaf.comparison) {
      FilterComparison.over => col.isBiggerThanValue(bytes),
      FilterComparison.under => col.isSmallerThanValue(bytes),
      _ => const Constant(false),
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
        // over/under on a text field: the editors never offer it, but a
        // hand-made or imported filter must not match every mail.
        _ => const Constant(false),
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
        // over/under on a text field: the editors never offer it, but a
        // hand-made or imported filter must not match every mail.
        _ => const Constant(false),
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
    if (pattern == null) return const Constant(false);
    final sub = _db.selectOnly(_db.emailBodies)
      ..addColumns([_db.emailBodies.emailId])
      ..where(
        _db.emailBodies.emailId.equalsExp(t.id) &
            _db.emailBodies.headersJson.like(pattern, escapeChar: '!'),
      );
    return existsQuery(sub);
  }

  Future<List<model.Email>> _getEmailsByAddress(
    String? accountId,
    String address, {
    int? limit,
  }) async {
    final pattern = '%${address.toLowerCase()}%';
    final select = _db.select(_db.emails)
      ..where((t) {
        Expression<bool> condition = _visible(t);
        if (accountId != null) {
          condition = condition & t.accountId.equals(accountId);
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
        (t) => OrderingTerm.desc(t.uid),
        (t) => OrderingTerm.desc(t.id),
      ]);
    if (limit != null) select.limit(limit);
    final rows = await select.get();
    return rows.map(_toModel).toList();
  }

  Future<List<model.EmailAddress>> _searchAddresses(
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
            Expression<bool> cond = _visible(t);
            if (accountId != null) cond = cond & t.accountId.equals(accountId);
            cond = cond &
                (t.fromJson.like(pattern) |
                    t.toAddresses.like(pattern) |
                    t.ccJson.like(pattern));
            return cond;
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.receivedAt),
            (t) => OrderingTerm.desc(t.uid),
            (t) => OrderingTerm.desc(t.id),
          ])
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

  // Results are limited to emails already synced into the local SQLite FTS5
  // index; call syncEmails first to ensure the index is up-to-date.
  Future<List<model.Email>> _searchEmails(
    String accountId,
    String mailboxPath,
    String query, {
    int limit = searchPageSize,
  }) =>
      _searchEmailsLocal(
        accountId: accountId,
        mailboxPath: mailboxPath,
        query: query,
        limit: limit,
      );

  Stream<List<model.Email>> _observeEmailsInThread(
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
            (t) => OrderingTerm.asc(t.uid),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }

  Stream<List<model.Email>> _observeThreadAcrossFolders(
    String accountId,
    String threadId,
  ) {
    // Same as observeEmailsInThread but without the mailboxPath filter, so a
    // conversation's Inbox, Sent and Archive copies are gathered together
    // (#754). The UID tiebreak compares UIDs of different folders, so for
    // same-second copies it only makes the order deterministic.
    return (_db.select(_db.emails)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.threadId.equals(threadId) &
                _visible(t),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sentAt),
            (t) => OrderingTerm.asc(t.receivedAt),
            (t) => OrderingTerm.asc(t.uid),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch()
        .map((rows) => rows.map(_toModel).toList());
  }
}
