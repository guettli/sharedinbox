part of '../email_repository_impl.dart';

// IMAP flush: a mail change whose folder was not at its path on the server
// waits for one folder listing (#1339), which may follow the folder another
// client renamed or moved, the way a folder rename or move does (#1329).

/// A queued IMAP change found [path], a cached server folder it names (its
/// source, or the folder a move, snooze or unsnooze goes into), not on the
/// server: `NO [NONEXISTENT]` from the SELECT, or a "no such folder" answer
/// of the MOVE after the source was selected. Another client may have
/// renamed or moved the folder, and the folder listing after this flush
/// follows it by its MAILBOXID (or the UIDVALIDITY / Message-ID rules): the
/// change waits for that listing ([_FlushImapFolderWait._waitForFolderListing])
/// instead of being dropped as moot or failed.
class _ImapFolderGoneException implements Exception {
  _ImapFolderGoneException(this.path, this.cause);

  final String path;
  final Object cause;

  @override
  String toString() => cause.toString();
}

extension _FlushImapFolderWait on EmailRepositoryImpl {
  /// Whether [path] is a folder of [accountId] the app has a server copy
  /// of (a mailbox row not created offline): one a folder listing can
  /// follow to its new path or remove. A path the app does not know (or
  /// one not created yet) gets nothing from waiting.
  Future<bool> _isCachedServerFolder(String accountId, String path) async {
    final row = await _mailboxState.rowByPath(accountId, path);
    return row != null && !row.isLocal;
  }

  /// The folder paths queued change [payload] names: its source
  /// (`mailboxPath`, or `src` for snooze and unsnooze) and its destination
  /// (`dest`). A folder listing that follows a folder rewrites them
  /// ([EmailStateWriter.renameFolder]).
  static Set<String> _namedFolders(Map<String, dynamic> payload) => {
        for (final key in const ['mailboxPath', 'src', 'dest'])
          if (payload[key] case final String path) path,
      };

  /// Claimed change [row] after [_waitForFolderListing] marked it
  /// ([mailboxOpGoneAt]), before anything is sent:
  ///
  /// - the change no longer names the marked path: a folder listing
  ///   followed the folder to its new path and named that in the change
  ///   ([EmailStateWriter.renameFolder], App Log warn
  ///   `pending_change.folder_renamed`). The mark goes, and the change is
  ///   returned to be sent there (App Log `pending_change.folder_followed`:
  ///   info, or warn when the change was sent before without an answer and
  ///   may have reached the server at the old path);
  /// - it still names it, and a listing that started after the mark
  ///   finished: that listing did not find the folder elsewhere and kept a
  ///   folder at that path (one listed there again, which may be another
  ///   folder, or one a listing in doubt kept, #1312). The change fails
  ///   visibly without being sent: sent to the path, a delete or flag
  ///   change could land on a folder another client made there. A listing
  ///   that removed the folder failed the change itself
  ///   (`removeLocalMailbox`, "folder removed on the server");
  /// - otherwise (no listing finished since: listings fail) the change
  ///   waits on, put back uncharged and unsent, at most
  ///   [MailboxStateWriter.goneAtMaxWait] and
  ///   [MailboxStateWriter.goneAtMaxWaits] flushes; then it fails visibly.
  ///
  /// Returns the change to send (as stored), or null when it was settled
  /// here (failed or put back).
  Future<PendingChangeRow?> _resolveFolderGoneAt(
    account_model.Account account,
    PendingChangeRow row,
  ) async {
    final mark = MailboxStateWriter.goneAtOf(row);
    if (mark == null) return row;
    final payload = _decodePayload(row)!;
    final named = _namedFolders(payload);
    payload.remove(mailboxOpGoneAt);
    if (!named.contains(mark.path)) {
      final stored = await _db.transaction(() async {
        final owned = await (_db.update(_db.pendingChanges)
                  ..where((t) => _ownsClaim(t, row)))
                .write(
              PendingChangesCompanion(payload: Value(jsonEncode(payload))),
            ) >
            0;
        if (!owned) return null;
        return (_db.select(_db.pendingChanges)
              ..where((t) => t.id.equals(row.id)))
            .getSingle();
      });
      if (stored == null) return null;
      final sentBefore = row.attempts > 0;
      final to = _namedFolders(payload).join('" and "');
      final message = 'The ${_describeChange(row)} waited because its '
          'folder "${mark.path}" was not on the server; the folder list '
          'found it renamed or moved by another client, and the change is '
          'sent to "$to" now'
          '${sentBefore ? ' (it was sent before without an answer, to the '
              'old path)' : ''}';
      final data = {
        'changeId': row.id,
        'changeType': row.changeType,
        'from': mark.path,
        'attempts': row.attempts,
      };
      unawaited(
        sentBefore
            ? _appLogger?.warn(
                'pending_change.folder_followed',
                message,
                accountId: row.accountId,
                emailId: row.resourceId,
                data: data,
              )
            : _appLogger?.info(
                'pending_change.folder_followed',
                message,
                accountId: row.accountId,
                emailId: row.resourceId,
                data: data,
              ),
      );
      return stored;
    }
    final listed = await _mailboxState.folderListedSeq(row.accountId);
    final since = mark.since;
    final listedSince = listed != null && listed >= mark.seq;
    final capped = mark.waits + 1 >= MailboxStateWriter.goneAtMaxWaits ||
        (since != null &&
            _now().difference(since) >= MailboxStateWriter.goneAtMaxWait);
    if (!listedSince && !capped) {
      payload[mailboxOpGoneAt] = {
        ...(_decodePayload(row)![mailboxOpGoneAt] as Map<String, dynamic>),
        'waits': mark.waits + 1,
      };
      await _db.transaction(() async {
        await (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, row)))
            .write(
          PendingChangesCompanion(payload: Value(jsonEncode(payload))),
        );
        await _unclaimPendingChange(row);
      });
      return null;
    }
    final why = listedSince
        ? 'the folder "${mark.path}" is not on the server, and the folder '
            'list did not find it renamed or moved'
        : 'the folder "${mark.path}" is not on the server, and no folder '
            'list could be read to find it renamed or moved';
    // The mark goes with the failure: a Retry waits for one listing again.
    final dependents = await _db.transaction(() async {
      await (_db.update(_db.pendingChanges)..where((t) => _ownsClaim(t, row)))
          .write(PendingChangesCompanion(payload: Value(jsonEncode(payload))));
      return _markChangeFailedInTransaction(row, why, revert: true);
    });
    if (dependents == null) return null;
    _logDependentFailures(row, dependents);
    log('IMAP change ${row.id} failed: $why');
    unawaited(
      _appLogger?.warn(
        'pending_change.folder_not_found',
        'Could not apply ${_describeChange(row)} — $why; not sent, kept on '
            'the Pending Changes screen',
        accountId: account.id,
        emailId: row.resourceId,
        mailboxPath: mark.path,
        data: {
          'changeId': row.id,
          'changeType': row.changeType,
          'gone': mark.path,
          'listed': listedSince,
          'waits': mark.waits + 1,
        },
      ),
    );
    return null;
  }

  /// Claimed change [row] found [e]'s folder not on the server (#1339): it
  /// goes back uncharged and waits for the folder listing after this
  /// flush, marked ([mailboxOpGoneAt], [MailboxStateWriter.markGoneAt],
  /// with a read sequence taken once it is back, so that only a listing
  /// started after that counts), with App Log info
  /// `pending_change.waits_for_listing` and a kick of the sync loop. The
  /// listing follows the folder and names its new path in the change, or
  /// removes it and fails the change ("folder removed on the server");
  /// [_resolveFolderGoneAt] decides at the next flush. Nothing reached the
  /// server that a resend would repeat wrongly: the SELECT failed, or the
  /// MOVE into the gone folder did (a snooze's keyword, a clear-snooze's
  /// flag edits are set again by the resend, which they are not hurt by).
  Future<void> _waitForFolderListing(
    account_model.Account account,
    PendingChangeRow row,
    _ImapFolderGoneException e,
  ) async {
    await _unclaimPendingChange(row);
    await _mailboxState.markGoneAt(row.id, e.path);
    log('IMAP change ${row.id} waits: ${e.path} is not on the server');
    unawaited(
      _appLogger?.info(
        'pending_change.waits_for_listing',
        'The ${_describeChange(row)} waits: its folder "${e.path}" is not on '
            'the server (${e.cause}). Another client may have renamed or '
            'moved it; the folder list is read first, and the change is '
            'sent to where it finds the folder, or fails if it does not',
        accountId: account.id,
        emailId: row.resourceId,
        mailboxPath: e.path,
        data: {
          'changeId': row.id,
          'changeType': row.changeType,
          'gone': e.path,
        },
      ),
    );
    _changeCtrl.add(account.id);
  }
}
