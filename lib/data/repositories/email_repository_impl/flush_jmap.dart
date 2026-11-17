part of '../email_repository_impl.dart';

// JMAP flush: draining the queue to a JMAP server, including the snoozed
// placeholder resolution.

extension _FlushJmap on EmailRepositoryImpl {
  Future<int> _flushPendingChangesJmap(
    account_model.Account account,
    String password,
    List<PendingChangeRow> rows,
  ) async {
    final jmapUrl = account.jmapUrl;
    if (jmapUrl == null || jmapUrl.isEmpty) return 0;

    final jmap = await JmapClient.connect(
      httpClient: _httpClient,
      jmapUrl: Uri.parse(jmapUrl),
      username: _effectiveUsername(account),
      password: password,
    );

    var applied = 0;
    // Mails whose move/snooze/unsnooze/delete did not apply in this flush:
    // their later changes address the mail where that change would have put
    // it, so they wait (unclaimed, uncharged) for the next flush.
    final blocked = await _mailsInFlightElsewhere(
      account.id,
      selected: {for (final r in rows) r.id},
    );

    for (final snapshot in rows) {
      if (blocked.contains(snapshot.resourceId)) continue;
      final row = await _claimPendingChange(snapshot);
      if (row == null) {
        // Cancelled, failed or claimed by another flush since the snapshot:
        // the mail's later changes wait for the next flush.
        blocked.add(snapshot.resourceId);
        continue;
      }
      final placement = _placementChangeTypes.contains(row.changeType);
      if (placement) {
        // Unblocked again below once it applied.
        blocked.add(row.resourceId);
      }
      try {
        // Pending-change `Email/set`s deliberately omit `ifInState`: each patch
        // targets a single email's own `mailboxIds`/`keywords`, so it is safe
        // to apply regardless of unrelated concurrent changes. Sending
        // `ifInState` made a routine move fail with `stateMismatch` whenever
        // the account's Email state had moved on (issue #746). We also leave
        // the Email checkpoint untouched — the next `Email/changes` sync
        // reconciles this mutation together with any concurrent server changes
        // (re-applying our own change is idempotent).
        await _applyPendingChangeJmap(jmap, row);
        await _settleApplied(row);
        applied++;
        blocked.remove(row.resourceId);
      } on JmapSetItemException catch (e) {
        if (e.type == 'notFound' && row.changeType == 'delete') {
          // The mail is already gone: the delete's intent is satisfied.
          blocked.remove(row.resourceId);
          await _deletePendingChange(row);
          log('JMAP change ${row.id} skipped: message already gone ($e)');
          unawaited(
            _appLogger?.info(
              'pending_change.skipped_gone',
              'Skipped ${_describeChange(row)} — message already gone on '
                  'the server',
              accountId: account.id,
              emailId: row.resourceId,
              data: {'changeType': row.changeType},
            ),
          );
          applied++;
          continue;
        }
        // Permanent per-item rejection (e.g. notFound, forbidden): retrying
        // cannot help, so mark it failed at once and keep it for the user.
        // `notFound`: the mail is gone, there is no place to go back to.
        if (!await _markChangeFailed(row, e, revert: e.type != 'notFound')) {
          continue;
        }
        log('JMAP permanent error for change ${row.id}: $e');
        unawaited(
          _appLogger?.error(
            'pending_change.rejected',
            'Server rejected ${_describeChange(row)}; kept on the Pending '
                'Changes screen',
            accountId: account.id,
            emailId: row.resourceId,
            data: {'changeType': row.changeType},
            error: e,
          ),
        );
      } catch (e) {
        if (isJmapNetworkError(e)) {
          // No answer from the server (offline, network switch, timeout):
          // no step towards giving up, like a failed IMAP connect (#1224).
          // The request may still have landed (a timeout does not cancel
          // it), so the claim stays: Undo must queue a reverse change, not
          // cancel this one (#1048). Sending it again is safe: a move sets
          // `mailboxIds`, flag patches are idempotent and a second destroy
          // answers `notFound`, which counts as applied. The rest of the
          // queue would fail the same way: stop and retry next sync.
          await _keepClaimWithoutCharge(row, e);
          log('JMAP flush for ${account.id} stopped: network error ($e)');
          break;
        }
        await _recordChangeError(row, e);
        // Retried later: the mail's later changes wait, so they keep their
        // order (a newer read/star change must not land before an older one
        // that is retried later).
        blocked.add(row.resourceId);
      }
    }
    return applied;
  }

  /// The JMAP id of [accountId]'s Snoozed mailbox, or null when neither the
  /// local cache nor the server has one and [create] is false. With [create]
  /// a missing mailbox is made on the server — the case on every fresh JMAP
  /// account. A snooze queued while the folder was unknown targets
  /// [_snoozedPlaceholder]; resolving it here, at flush time, keeps snoozing
  /// usable offline. Whenever an id is found, every row still parked under
  /// the placeholder is moved onto it, so the list, [isSnoozedMailbox] and the
  /// wake-up all see one Snoozed folder.
  ///
  /// The `snoozed` role is not in the IANA registry and servers such as
  /// Stalwart reject it (`invalidProperties`), so creation retries without a
  /// role; the folder is then found by name, as [_UserActions._snoozedMailboxPath] does.
  ///
  /// Throws when creation fails, so the change stays queued and is retried
  /// (up to [_maxChangeAttempts]) rather than dropped as a per-email reject.
  Future<String?> _resolveJmapSnoozedMailbox(
    JmapClient jmap,
    String accountId, {
    required bool create,
  }) async {
    final known = await _snoozedMailboxPath(accountId);
    if (known != _snoozedPlaceholder) {
      await _repointSnoozedPlaceholder(accountId, known);
      return known;
    }

    final getResponses = await jmap.call([
      [
        'Mailbox/get',
        {
          'accountId': jmap.accountId,
          'properties': ['name', 'role', 'parentId'],
        },
        '0',
      ],
    ]);
    final list =
        (_responseArgs(getResponses, 0, 'Mailbox/get')['list'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    final existing = list.where((m) => m['role'] == 'snoozed').firstOrNull ??
        list
            .where(
              (m) => m['name'] == _snoozedPlaceholder && m['parentId'] == null,
            )
            .firstOrNull;
    var id = existing?['id'] as String?;
    var role = existing?['role'] as String?;

    if (id == null) {
      if (!create) return null;
      for (final withRole in const [true, false]) {
        final setResponses = await jmap.call([
          [
            'Mailbox/set',
            {
              'accountId': jmap.accountId,
              'create': {
                'snoozed': {
                  'name': _snoozedPlaceholder,
                  if (withRole) 'role': 'snoozed',
                },
              },
            },
            '0',
          ],
        ]);
        final result = _responseArgs(setResponses, 0, 'Mailbox/set');
        final created = (result['created'] as Map<String, dynamic>?)?['snoozed']
            as Map<String, dynamic>?;
        id = created?['id'] as String?;
        if (id != null) {
          role = withRole ? 'snoozed' : null;
          break;
        }
      }
    }
    if (id == null) {
      // Not a per-email rejection: keep the snooze queued and retry later.
      throw StateError('Could not create the Snoozed mailbox on the server');
    }

    await _repointSnoozedPlaceholder(
      accountId,
      id,
      mailbox: MailboxesCompanion.insert(
        id: '$accountId:$id', // not an email id
        accountId: accountId,
        path: id,
        name: _snoozedPlaceholder,
        role: Value(role),
        displayPath: const Value(_snoozedPlaceholder),
      ),
    );
    return id;
  }

  /// Records [mailbox] (when given) and moves every email and thread row of
  /// [accountId] still under [_snoozedPlaceholder] onto [snoozedId], in one
  /// transaction. Threads are rebuilt rather than renamed: the same thread
  /// can already have a row under [snoozedId], and the key would collide.
  Future<void> _repointSnoozedPlaceholder(
    String accountId,
    String snoozedId, {
    MailboxesCompanion? mailbox,
  }) =>
      _db.transaction(() async {
        if (mailbox != null) {
          await _db.into(_db.mailboxes).insertOnConflictUpdate(mailbox);
        }
        await (_db.update(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(_snoozedPlaceholder),
              ))
            .write(EmailsCompanion(mailboxPath: Value(snoozedId)));
        await (_db.update(_db.emails)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.snoozedFromMailboxPath.equals(_snoozedPlaceholder),
              ))
            .write(EmailsCompanion(snoozedFromMailboxPath: Value(snoozedId)));
        final placeholderThreads = _db.select(_db.threads)
          ..where(
            (t) =>
                t.accountId.equals(accountId) &
                t.mailboxPath.equals(_snoozedPlaceholder),
          );
        final threadIds =
            (await placeholderThreads.get()).map((t) => t.id).toSet();
        if (threadIds.isEmpty) return;
        await (_db.delete(_db.threads)
              ..where(
                (t) =>
                    t.accountId.equals(accountId) &
                    t.mailboxPath.equals(_snoozedPlaceholder),
              ))
            .go();
        for (final threadId in threadIds) {
          await _updateThread(accountId, snoozedId, threadId);
        }
      });

  /// `Email/set` patch entries (`keywords/snz:…: null`) that remove every
  /// snooze keyword [jmapEmailId] currently carries on the server.
  Future<Map<String, dynamic>> _jmapSnoozeKeywordRemovals(
    JmapClient jmap,
    String jmapEmailId,
  ) async {
    final getResponses = await jmap.call([
      [
        'Email/get',
        {
          'accountId': jmap.accountId,
          'ids': [jmapEmailId],
          'properties': ['keywords'],
        },
        '0',
      ],
    ]);
    final getResult = _responseArgs(getResponses, 0, 'Email/get');
    final email = (getResult['list'] as List).firstOrNull as Map?;
    final keywords = (email?['keywords'] as Map?) ?? {};
    return {
      for (final k in keywords.keys)
        if (k.toString().startsWith('snz:')) 'keywords/$k': null,
    };
  }

  /// Applies a single pending change to the JMAP server.
  ///
  /// The `Email/set` calls intentionally omit `ifInState`: each is a targeted
  /// patch to one email's own `mailboxIds`/`keywords`, safe to apply without an
  /// optimistic-concurrency precondition, so a routine move never fails with
  /// `stateMismatch` because the account state moved on (issue #746). The
  /// caller does not advance the local checkpoint from the result — the next
  /// `Email/changes` sync reconciles this mutation with any concurrent changes.
  ///
  /// Throws [JmapSetItemException] on a permanent per-item rejection
  /// (`notUpdated`/`notDestroyed`), or [JmapException] on any other error.
  Future<void> _applyPendingChangeJmap(
    JmapClient jmap,
    PendingChangeRow row,
  ) async {
    final payload = jsonDecode(row.payload) as Map<String, dynamic>;
    final jmapEmailId = await _jmapIdOfChange(row);

    Map<String, dynamic> setArgs(Map<String, dynamic> extra) => {
          'accountId': jmap.accountId,
          ...extra,
        };

    List<dynamic> responses;
    switch (row.changeType) {
      case 'flag_seen':
        final seen = payload['seen'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$seen': seen},
              },
            }),
            '0',
          ],
        ]);

      case 'flag_flagged':
        final flagged = payload['flagged'] as bool;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {'keywords/\$flagged': flagged},
              },
            }),
            '0',
          ],
        ]);

      case 'add_keywords':
        final update = <String, dynamic>{
          for (final k in (payload['keywords'] as List<dynamic>).cast<String>())
            'keywords/${_imapFlagToJmapKeyword(k)}': true,
        };
        if (update.isEmpty) return;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      case 'move':
        final destMailboxId = payload['dest'] as String;
        final moveUpdate = <String, dynamic>{
          'mailboxIds': {destMailboxId: true},
          if (payload['clearSnooze'] == true)
            ...await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId),
        };
        // Set `mailboxIds` outright rather than patching `dest: true` plus
        // `src: null`. `src` is the folder the row sat in when the move was
        // queued; by flush time the server can hold the message elsewhere
        // (another client moved it, or an earlier queued move of ours landed
        // first). Dropping only the stale `src` then leaves it filed in two
        // folders at once, which the single-folder local model cannot
        // represent, so the mail sticks in a folder the local cache never
        // shows and the account diverges permanently (#910). A replacement is
        // also what a move means here: the mail is now in the destination and
        // nowhere else.
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: moveUpdate},
            }),
            '0',
          ],
        ]);

      case 'delete':
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'destroy': [jmapEmailId],
            }),
            '0',
          ],
        ]);

      case 'snooze':
        final until = payload['until'] as String;
        final timestamp = until.replaceAll(':', '').replaceAll('-', '');
        final keyword = 'snz:$timestamp';
        var destMailboxId = payload['dest'] as String;
        var srcMailboxId = payload['src'] as String;
        // When the Snoozed folder didn't exist at enqueue time, 'dest' holds
        // the literal name 'Snoozed' rather than a JMAP mailbox ID — and so
        // does 'src' for a re-snooze of a mail parked under that placeholder.
        if (destMailboxId == _snoozedPlaceholder) {
          destMailboxId = (await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: true,
          ))!;
        }
        if (srcMailboxId == _snoozedPlaceholder) {
          srcMailboxId = (await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: true,
          ))!;
        }
        // A re-snooze replaces the earlier snooze keyword: with both, sync
        // would read back whichever comes first.
        final earlier = payload['prevSnoozedUntil'] == null
            ? const <String, dynamic>{}
            : await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId);
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {
                jmapEmailId: {
                  ...earlier,
                  'keywords/$keyword': true,
                  // A re-snooze from the Snoozed folder only re-tags: patching
                  // the same id to true and null is a conflicting update.
                  if (srcMailboxId != destMailboxId) ...{
                    'mailboxIds/$destMailboxId': true,
                    'mailboxIds/$srcMailboxId': null,
                  },
                },
              },
            }),
            '0',
          ],
        ]);

      case 'unsnooze':
        final destMailboxId = payload['dest'] as String;
        String? srcMailboxId = payload['src'] as String;
        // An unsnooze queued before its snooze reached the server still names
        // the placeholder. Look the folder up, but never create one just to
        // leave it: with no Snoozed mailbox the mail cannot be in it.
        if (srcMailboxId == _snoozedPlaceholder) {
          srcMailboxId = await _resolveJmapSnoozedMailbox(
            jmap,
            row.accountId,
            create: false,
          );
        }
        final update = <String, dynamic>{
          'mailboxIds/$destMailboxId': true,
          if (srcMailboxId != null && srcMailboxId != destMailboxId)
            'mailboxIds/$srcMailboxId': null,
          ...await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId),
        };

        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: update},
            }),
            '0',
          ],
        ]);

      case 'clear_snooze':
        final removals = await _jmapSnoozeKeywordRemovals(jmap, jmapEmailId);
        if (removals.isEmpty) return;
        responses = await jmap.call([
          [
            'Email/set',
            setArgs({
              'update': {jmapEmailId: removals},
            }),
            '0',
          ],
        ]);

      default:
        return;
    }

    final result = _responseArgs(responses, 0, 'Email/set');

    // Check for per-item rejection (notUpdated / notDestroyed).
    final notUpdated = result['notUpdated'] as Map<String, dynamic>?;
    if (notUpdated != null && notUpdated.containsKey(jmapEmailId)) {
      final err = notUpdated[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }
    final notDestroyed = result['notDestroyed'] as Map<String, dynamic>?;
    if (notDestroyed != null && notDestroyed.containsKey(jmapEmailId)) {
      final err = notDestroyed[jmapEmailId] as Map<String, dynamic>;
      throw JmapSetItemException(
        err['type'] as String? ?? 'unknown',
        err['description'] as String?,
      );
    }
  }
}
