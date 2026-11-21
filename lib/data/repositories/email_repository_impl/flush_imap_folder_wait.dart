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

/// A [mailboxOpGoneAt] mark ([MailboxStateWriter.goneAtOf]).
typedef _GoneAtMark = ({
  String path,
  int seq,
  DateTime? since,
  int waits,
  Map<String, String> at,
});

/// What [_FlushImapFolderWait._resolveFolderGoneAt] decided for a marked
/// change: [send] it (as stored), or it [failed], or neither (put back).
typedef _GoneAtOutcome = ({
  PendingChangeRow? send,
  _GoneAtMark? mark,
  ({String why, List<PendingChangeRow> dependents, bool listed})? failed,
});

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

  /// Claimed change [claimed] after [_waitForFolderListing] marked it
  /// ([mailboxOpGoneAt]), before anything is sent. Decided on the change as
  /// stored, in one transaction: a folder listing (another isolate's, the
  /// folder diagnostics') may have followed the folder since [claimed] was
  /// read, and only the mark is ever written back.
  ///
  /// - the change no longer names the marked path: a folder listing
  ///   followed the folder to its new path and named that in the change
  ///   ([EmailStateWriter.renameFolder], App Log warn
  ///   `pending_change.folder_renamed`). The mark goes, and the change is
  ///   returned to be sent there (App Log `pending_change.folder_followed`
  ///   with the paths that changed: info, or warn when the change was sent
  ///   before without an answer and may have reached the server at the old
  ///   path). Not a delete that was sent before: its resend would look the
  ///   mail up by Message-ID in a renumbered folder and could expunge
  ///   another copy, so it fails visibly;
  /// - it still names it, and a folder listing that could follow every
  ///   folder ([MailboxStateWriter.trustedListingSeq]) started after the
  ///   mark and finished: that listing did not find the folder elsewhere
  ///   and kept a folder at that path, which may be another folder. The
  ///   change fails visibly without being sent: sent to the path, a delete
  ///   or flag change could land on a folder another client made there. A
  ///   listing that removed the folder failed the change itself
  ///   (`removeLocalMailbox`, "folder removed on the server");
  /// - otherwise (no such listing since: listings fail, or are in doubt)
  ///   the change waits on, put back uncharged and unsent, at most
  ///   [MailboxStateWriter.goneAtMaxWait] and
  ///   [MailboxStateWriter.goneAtMaxWaits] flushes; then it fails visibly.
  ///
  /// Returns the change to send (as stored), or null when it was settled
  /// here (failed or put back) or the claim was lost.
  Future<PendingChangeRow?> _resolveFolderGoneAt(
    account_model.Account account,
    PendingChangeRow claimed,
  ) async {
    if (MailboxStateWriter.goneAtOf(claimed) == null) return claimed;
    final listed = await _mailboxState.trustedListingSeq(claimed.accountId);
    final outcome = await _db.transaction<_GoneAtOutcome?>(() async {
      final row = await (_db.select(_db.pendingChanges)
            ..where((t) => _ownsClaim(t, claimed)))
          .getSingleOrNull();
      if (row == null) return null;
      final mark = MailboxStateWriter.goneAtOf(row);
      if (mark == null) return (send: row, mark: null, failed: null);
      final payload = _decodePayload(row)!;
      final followed = !_namedFolders(payload).contains(mark.path);
      final since = mark.since;
      final capped = mark.waits + 1 >= MailboxStateWriter.goneAtMaxWaits ||
          (since != null &&
              _now().difference(since) >= MailboxStateWriter.goneAtMaxWait);
      final listedSince = listed != null && listed >= mark.seq;
      final String why;
      if (followed && (row.changeType != 'delete' || row.attempts == 0)) {
        final stored = await _mailboxState.updateGoneAt(row.id, (_) => null);
        return (send: stored, mark: mark, failed: null);
      } else if (followed) {
        why = 'the folder "${mark.path}" was renamed or moved by another '
            'client after this delete was sent without an answer; it is not '
            'sent to the new path, where it could delete another copy of the '
            'mail';
      } else if (!listedSince && !capped) {
        await _mailboxState.updateGoneAt(
          row.id,
          (stored) => {...?stored, 'waits': mark.waits + 1},
        );
        await _unclaimPendingChange(row);
        return (send: null, mark: mark, failed: null);
      } else {
        why = listedSince
            ? 'the folder "${mark.path}" is not on the server, and the '
                'folder list did not find it renamed or moved'
            : 'the folder "${mark.path}" is not on the server, and no '
                'folder list could be read to find it renamed or moved';
      }
      // The mark goes with the failure: a Retry waits for one listing
      // again.
      final stored =
          await _mailboxState.updateGoneAt(row.id, (_) => null) ?? row;
      final dependents =
          await _markChangeFailedInTransaction(stored, why, revert: true);
      if (dependents == null) return null;
      return (
        send: null,
        mark: mark,
        failed: (why: why, dependents: dependents, listed: listedSince),
      );
    });
    if (outcome == null) return null;
    final (:send, :mark, :failed) = outcome;
    if (mark == null) return send;
    if (send != null) {
      _logFolderFollowed(send, mark);
      return send;
    }
    if (failed == null) return null;
    _logDependentFailures(claimed, failed.dependents);
    log('IMAP change ${claimed.id} failed: ${failed.why}');
    unawaited(
      _appLogger?.warn(
        'pending_change.folder_not_found',
        'Could not apply ${_describeChange(claimed)} — ${failed.why}; not '
            'sent, kept on the Pending Changes screen',
        accountId: account.id,
        emailId: claimed.resourceId,
        mailboxPath: mark.path,
        data: {
          'changeId': claimed.id,
          'changeType': claimed.changeType,
          'gone': mark.path,
          'listed': failed.listed,
          'waits': mark.waits + 1,
          'attempts': claimed.attempts,
        },
      ),
    );
    return null;
  }

  /// App Log `pending_change.folder_followed` for [row], as stored after a
  /// folder listing followed the folder its [mark] names: the payload keys
  /// whose paths changed since the mark (`from`, `to`), and the change's
  /// source folder now.
  void _logFolderFollowed(
    PendingChangeRow row,
    _GoneAtMark mark,
  ) {
    final payload = _decodePayload(row) ?? const <String, dynamic>{};
    final from = <String, String>{};
    final to = <String, String>{};
    for (final MapEntry(:key, :value) in mark.at.entries) {
      final now = payload[key];
      if (now is! String || now == value) continue;
      from[key] = value;
      to[key] = now;
    }
    if (from.isEmpty) from['path'] = mark.path;
    final source = (payload['mailboxPath'] ?? payload['src']) as String?;
    final sentBefore = row.attempts > 0;
    final moved = [
      for (final key in from.keys)
        '"${from[key]}"${to[key] == null ? '' : ' → "${to[key]}"'}',
    ].join(', ');
    final message = 'The ${_describeChange(row)} waited because its folder '
        '"${mark.path}" was not on the server; the folder list found it '
        'renamed or moved by another client ($moved), and the change is '
        'sent there now'
        '${sentBefore ? ' (it was sent before without an answer, to the '
            'old path)' : ''}';
    final data = {
      'changeId': row.id,
      'changeType': row.changeType,
      'from': from,
      'to': to,
      'attempts': row.attempts,
    };
    unawaited(
      sentBefore
          ? _appLogger?.warn(
              'pending_change.folder_followed',
              message,
              accountId: row.accountId,
              emailId: row.resourceId,
              mailboxPath: source,
              data: data,
            )
          : _appLogger?.info(
              'pending_change.folder_followed',
              message,
              accountId: row.accountId,
              emailId: row.resourceId,
              mailboxPath: source,
              data: data,
            ),
    );
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
    await _mailboxState.markGoneAt(
      row.id,
      e.path,
      pathKeys: const ['mailboxPath', 'src', 'dest'],
    );
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
