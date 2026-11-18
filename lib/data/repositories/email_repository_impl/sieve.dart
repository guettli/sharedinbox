part of '../email_repository_impl.dart';

// Sieve: running filter rules over the inbox and queueing their actions.

/// Selects how [_Sieve._runSieveOverInbox] tallies matches.
///
/// * [anyMatch] counts any INBOX row where a rule's test fires, including
///   pure-`keep` matches with no visible effect. Used by the "preview" and
///   "apply to inbox now" flows so the count matches user intuition.
/// * [visibleEffect] counts only rows whose actions would move, discard or
///   flag the message. Used by the automatic sync-time apply so the number
///   reported matches the number of pending changes actually enqueued.
enum _SieveCountMode { anyMatch, visibleEffect }

/// Maps an IMAP flag or keyword from [normalizeSieveFlags] to its JMAP
/// keyword (RFC 8621 §4.1.1): system flags become their `$` form, keywords
/// are case-insensitive and lower-cased.
String _imapFlagToJmapKeyword(String flag) {
  final lower = flag.toLowerCase();
  return lower.startsWith(r'\') ? '\$${lower.substring(1)}' : lower;
}

extension _Sieve on EmailRepositoryImpl {
  /// Applies locally stored active Sieve rules to INBOX emails that have not
  /// been processed yet. See [EmailRepository.applySieveRules] for details.
  Future<int> _applySieveRules(String accountId) async {
    final scriptRow = await (_db.select(_db.localSieveScripts)
          ..where(
            (t) => t.accountId.equals(accountId) & t.isActive.equals(true),
          )
          ..limit(1))
        .getSingleOrNull();
    if (scriptRow == null) return 0;

    List<SieveRule> rules;
    try {
      rules = SieveParser().parse(scriptRow.content);
    } catch (e) {
      log('Sieve parse error for account $accountId: $e');
      return 0;
    }
    if (rules.isEmpty) return 0;

    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: true,
      countMode: _SieveCountMode.visibleEffect,
      enqueueActions: true,
    );
  }

  Future<int> _previewSieveRuleMatches(
    String accountId,
    String scriptContent,
  ) async {
    final rules = SieveParser().parse(scriptContent);
    if (rules.isEmpty) return 0;
    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: false,
      countMode: _SieveCountMode.anyMatch,
      enqueueActions: false,
    );
  }

  Future<int> _applySieveScriptToInbox(
    String accountId,
    String scriptContent,
  ) async {
    final rules = SieveParser().parse(scriptContent);
    if (rules.isEmpty) return 0;
    return _runSieveOverInbox(
      accountId: accountId,
      rules: rules,
      skipAlreadyApplied: false,
      countMode: _SieveCountMode.anyMatch,
      enqueueActions: true,
    );
  }

  /// Shared driver used by [applySieveRules], [previewSieveRuleMatches] and
  /// [applySieveScriptToInbox]. Iterates INBOX messages, runs [rules] against
  /// each one and — depending on [enqueueActions] — enqueues the resulting
  /// moves/deletes/flag changes and records the message in LocalSieveApplied.
  Future<int> _runSieveOverInbox({
    required String accountId,
    required List<SieveRule> rules,
    required bool skipAlreadyApplied,
    required _SieveCountMode countMode,
    required bool enqueueActions,
  }) async {
    final inboxMailbox = await (_db.select(_db.mailboxes)
          ..where(
            (t) => t.accountId.equals(accountId) & t.role.equals('inbox'),
          )
          ..limit(1))
        .getSingleOrNull();
    final inboxPath = inboxMailbox?.path ?? 'INBOX';

    final Set<String> appliedIds;
    if (skipAlreadyApplied) {
      final alreadyApplied = await (_db.select(
        _db.localSieveApplied,
      )..where((t) => t.accountId.equals(accountId)))
          .get();
      appliedIds = alreadyApplied.map((r) => r.messageId).toSet();
    } else {
      appliedIds = const {};
    }

    // LocalSieveApplied is keyed on the Message-ID, which survives moves, so
    // the automatic run can only remember mail that has one and skips the
    // rest. The preview and the explicit "apply now" remember nothing, so
    // they take every inbox mail, with or without a Message-ID.
    final inboxEmails = await (_db.select(_db.emails)
          ..where(
            (t) {
              final inInbox = t.accountId.equals(accountId) &
                  t.mailboxPath.equals(inboxPath);
              return skipAlreadyApplied
                  ? inInbox & t.messageId.isNotNull()
                  : inInbox;
            },
          ))
        .get();

    final account = (await _accounts.getAccount(accountId))!;
    final interpreter = SieveInterpreter();
    var matched = 0;

    for (final row in inboxEmails) {
      final msgId = row.messageId;
      if (skipAlreadyApplied && appliedIds.contains(msgId)) continue;

      final emailCtx = _buildSieveContext(row);

      SieveExecutionContext result;
      try {
        result = interpreter.execute(rules, emailCtx);
      } catch (e) {
        log('Sieve interpreter error for message ${msgId ?? row.id}: $e');
        if (enqueueActions && msgId != null) {
          await _markSieveApplied(accountId, msgId);
        }
        continue;
      }

      final counts = switch (countMode) {
        _SieveCountMode.anyMatch => result.anyRuleMatched,
        _SieveCountMode.visibleEffect => result.isCancelled ||
            result.targetFolders.isNotEmpty ||
            result.flagsToAdd.isNotEmpty,
      };

      if (counts) matched++;

      if (!enqueueActions) continue;

      if (msgId != null) await _markSieveApplied(accountId, msgId);

      if (result.isCancelled) {
        await _enqueueSieveDelete(account, row);
        continue;
      }
      // Flags first: an IMAP move relocates the row (new UID in the
      // destination), so a flag change queued after it would address the
      // vanished source UID. Queued before, it is flushed first and the
      // MOVE carries the flags along (RFC 6851 keeps them; JMAP ids are
      // stable anyway). This also matches RFC 5232, where `fileinto`
      // files the message with the flags set so far.
      if (result.flagsToAdd.isNotEmpty) {
        await _enqueueSieveFlags(account, row, result.flagsToAdd);
      }
      if (result.targetFolders.isNotEmpty) {
        // The local model holds a message in exactly one folder, so a
        // script with several `fileinto` targets (copies, in Sieve) is
        // applied as a move to the first one.
        if (result.targetFolders.length > 1) {
          log(
            'Sieve: message ${row.id} has ${result.targetFolders.length} '
            'fileinto targets; moving to the first only',
          );
        }
        await _enqueueSieveMove(account, row, result.targetFolders.first);
      }
    }
    return matched;
  }

  SieveEmailContext _buildSieveContext(Email row) {
    String formatAddrs(String json) {
      try {
        final list = jsonDecode(json) as List<dynamic>;
        return list.map((e) {
          final m = e as Map<String, dynamic>;
          final name = m['name'] as String? ?? '';
          final email = m['email'] as String? ?? '';
          return name.isEmpty ? email : '$name <$email>';
        }).join(', ');
      } catch (_) {
        return '';
      }
    }

    return SieveEmailContext(
      headers: {
        if (row.subject != null && row.subject!.isNotEmpty)
          'subject': [row.subject!],
        'from': [formatAddrs(row.fromJson)],
        'to': [formatAddrs(row.toAddresses)],
        'cc': [formatAddrs(row.ccJson)],
        if (row.messageId != null) 'message-id': [row.messageId!],
      },
      sizeBytes: row.sizeBytes,
    );
  }

  Future<void> _markSieveApplied(String accountId, String messageId) async {
    await _db.into(_db.localSieveApplied).insertOnConflictUpdate(
          LocalSieveAppliedCompanion.insert(
            accountId: accountId,
            messageId: messageId,
            appliedAt: DateTime.now(),
          ),
        );
  }

  Future<void> _enqueueSieveMove(
    account_model.Account account,
    Email row,
    String folder,
  ) async {
    String destPath;
    if (account.type == account_model.AccountType.jmap) {
      final destMailbox = await (_db.select(_db.mailboxes)
            ..where(
              (t) => t.accountId.equals(account.id) & t.name.equals(folder),
            )
            ..limit(1))
          .getSingleOrNull();
      if (destMailbox == null) {
        log(
          'Sieve: JMAP mailbox "$folder" not found for account ${account.id}',
        );
        return;
      }
      destPath = destMailbox.path;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({'src': row.mailboxPath, 'dest': destPath}),
        supersedeFailures: false,
      );
    } else {
      destPath = folder;
      await _enqueueChange(
        account.id,
        row.id,
        'move',
        jsonEncode({
          'uid': row.uid,
          'mailboxPath': row.mailboxPath,
          'dest': destPath,
        }),
        supersedeFailures: false,
      );
    }
    // The queued move folds into the row: it shows in [destPath].
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
    await _updateThread(account.id, destPath, row.threadId ?? row.id);
  }

  Future<void> _enqueueSieveDelete(
    account_model.Account account,
    Email row,
  ) async {
    // The queued delete folds into the row: it is hidden until the server
    // confirms the mail is gone. A row with no server copy is deleted.
    final queued = await _enqueueChange(
      account.id,
      row.id,
      'delete',
      account.type == account_model.AccountType.jmap
          ? jsonEncode(<String, dynamic>{})
          : jsonEncode({'uid': row.uid, 'mailboxPath': row.mailboxPath}),
      supersedeFailures: false,
    );
    if (!queued) await _state.deleteRow(row.id);
    await _updateThread(account.id, row.mailboxPath, row.threadId ?? row.id);
  }

  /// Applies the Sieve `setflag` / `addflag` / mark / star actions in
  /// [flags] to [row]. `\Seen` and `\Flagged` go through [setFlag], the same
  /// path as the read/star buttons, so the local row, thread and push stay
  /// consistent. Any other flag or keyword is queued as an `add_keywords`
  /// change; the app has no local column for those, so it is server-only.
  /// Strings that are not valid IMAP flags are dropped (see
  /// [normalizeSieveFlags]) and logged.
  Future<void> _enqueueSieveFlags(
    account_model.Account account,
    Email row,
    Set<String> flags,
  ) async {
    final normalized = normalizeSieveFlags(flags);
    if (normalized.dropped.isNotEmpty) {
      log(
        'Sieve: ignoring invalid flags ${normalized.dropped} for message '
        '${row.id}',
      );
      unawaited(
        _appLogger?.warn(
          'sieve.flag_ignored',
          'Local filter flag(s) ignored: ${normalized.dropped.join(', ')}',
          accountId: account.id,
          emailId: row.id,
          mailboxPath: row.mailboxPath,
        ),
      );
    }
    final seen = normalized.flags.contains(r'\Seen');
    final flagged = normalized.flags.contains(r'\Flagged');
    if (seen || flagged) {
      await _asAutomaticChange(
        () => _setFlag(
          row.id,
          seen: seen ? true : null,
          flagged: flagged ? true : null,
          source: 'sieve',
        ),
      );
    }
    final keywords = normalized.flags
        .where((f) => f != r'\Seen' && f != r'\Flagged')
        .toList()
      ..sort();
    if (keywords.isEmpty) return;
    await _enqueueChange(
      account.id,
      row.id,
      'add_keywords',
      jsonEncode(
        account.type == account_model.AccountType.jmap
            ? {'keywords': keywords}
            : {
                'uid': row.uid,
                'mailboxPath': row.mailboxPath,
                'keywords': keywords,
              },
      ),
      supersedeFailures: false,
    );
  }
}
