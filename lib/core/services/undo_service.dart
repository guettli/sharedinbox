import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoService extends Notifier<List<UndoAction>> {
  static const int _maxHistory = 100;

  // Resolves once build() has loaded persisted history and reconciled the DB
  // with the in-memory cap.
  late Future<void> _ready;

  @override
  List<UndoAction> build() {
    final repo = ref.read(undoRepositoryProvider);
    _ready = repo.getHistory(limit: _maxHistory).then((history) async {
      if (ref.mounted) state = history;
      // Reconcile the persisted log with the in-memory cap so an older app
      // version that allowed more entries cannot keep them around forever.
      await repo.trim(maxHistory: _maxHistory);
    });
    return [];
  }

  /// Waits for the persisted history to finish loading. Called by tests to
  /// ensure the provider is ready before asserting state.
  Future<void> init() => _ready;

  Future<void> pushAction(UndoAction action) async {
    await _ready;
    // The DB replaces a row with the same id (undoing an action twice pushes
    // its inverse again), so state must not keep the older copy either.
    final newList = [...state.where((a) => a.id != action.id), action];
    while (newList.length > _maxHistory) {
      newList.removeAt(0);
    }
    state = newList;
    // Insert + trim atomically so a crash between them cannot lose both rows.
    await ref
        .read(undoRepositoryProvider)
        .pushAndTrim(action, maxHistory: _maxHistory);
  }

  /// Returns the persisted copy of [action]. Row ids are frozen, but when
  /// sync merged a second row of a mail into the kept one, the stored action
  /// names the kept row (`_mergeDuplicateRow`) while [state] may still name
  /// the dropped one (#1048).
  Future<UndoAction> _reload(UndoAction action) async {
    final history =
        await ref.read(undoRepositoryProvider).getHistory(limit: _maxHistory);
    return history.where((a) => a.id == action.id).firstOrNull ?? action;
  }

  /// Marks [action] (the persisted copy, see [_reload]) undone, in state and
  /// DB. Undoing an inverse (`<id>-inv`) re-applies the action it reverted,
  /// whose own inverse it may be in turn, so the marks alternate up the
  /// chain: the parent stands again, the grandparent is undone again, ...
  Future<void> _markUndone(UndoAction action) async {
    final repo = ref.read(undoRepositoryProvider);
    final now = DateTime.now();
    var id = action.id;
    DateTime? mark = now;
    while (true) {
      await repo.setUndoneAt(id, mark);
      final (current, m) = (id, mark);
      state = [
        for (final a in state)
          if (a.id != current)
            a
          else
            // Take the persisted copy's email ids (a duplicate merge may
            // have re-pointed them).
            (a.id == action.id ? action : a).withUndoneAt(m),
      ];
      if (!id.endsWith(UndoAction.inverseSuffix)) break;
      id = id.substring(0, id.length - UndoAction.inverseSuffix.length);
      mark = mark == null ? now : null;
    }
  }

  Future<void> clear() async {
    await _ready;
    state = [];
    // Await so callers can rely on the next read seeing an empty log even
    // across an immediate process restart.
    await ref.read(undoRepositoryProvider).clearHistory();
  }

  Future<void> undo({String? actionId}) async {
    await _ready;
    if (state.isEmpty) return;

    final UndoAction inMemory;
    if (actionId == null) {
      // The most recent action whose effect still stands; an undone entry
      // without an inverse would otherwise be undone over and over.
      final standing = state.where((a) => a.undoneAt == null);
      if (standing.isEmpty) return;
      inMemory = standing.last;
    } else {
      try {
        inMemory = state.firstWhere((a) => a.id == actionId);
      } catch (e) {
        return; // Action not found
      }
    }
    final action = await _reload(inMemory);

    // Keep the original entry in state and DB so the user can see what
    // happened and retry if the undo failed (e.g. after an IMAP sync reverted
    // the local change). The inverse action added below allows undoing the undo.

    final repo = ref.read(emailRepositoryProvider);

    // Whether the action recorded the changes it queued (the UI does since
    // undo by change id); one stored before that has none at all.
    final recorded = action.opSeqs.isNotEmpty;

    for (final id in action.emailIds) {
      // 1. Try to cancel the original change (if nothing was sent for it
      // yet): exactly the changes the action queued when it recorded them,
      // otherwise (an action stored before that) the latest of each type.
      // An email the action queued nothing for (a local-only mail, one
      // already in the destination) has nothing on the server to undo.
      final seqs = action.opSeqs[id] ?? const <int>[];
      final bool cancelled;
      if (recorded) {
        cancelled =
            seqs.isEmpty || (await repo.cancelOps(seqs)).length == seqs.length;
      } else {
        cancelled = await repo.cancelPendingChange(id, 'delete') ||
            await repo.cancelPendingChange(id, 'move') ||
            await repo.cancelPendingChange(id, 'snooze');
      }

      try {
        final original = action.originalEmails.isEmpty
            ? null
            : action.originalEmails.where((e) => e.id == id).firstOrNull;

        // 2. Resolve the current DB row for the email.
        // A row keeps its id when its move is applied on the server (only
        // its UID changes), but it can be gone: deleted for good, or merged
        // into the row sync stored for the same mail. Then look it up by
        // Message-ID so the pending change names the mail's current row.
        var currentEmail = await repo.getEmail(id);
        if (currentEmail == null && original?.messageId != null) {
          // Prefer the copy where the email should be now, so a Sent copy
          // of a self-sent mail with the same Message-ID is never picked.
          currentEmail = await repo.findEmailByMessageId(
            action.accountId,
            original!.messageId!,
            preferMailboxPath: cancelled
                ? action.sourceMailboxPath
                : (action.destinationMailboxPath ?? action.sourceMailboxPath),
          );
        }
        final currentId = currentEmail?.id ?? id;

        // 3. If the row is absent (deleted for good, or merged away),
        // restore it from the saved snapshot so moveEmail can find it. When
        // not cancelled, the snapshot's UID is the pre-move one; the reverse
        // move carries the Message-ID so the flush re-resolves the real UID.
        if (currentEmail == null && original != null) {
          final currentPath = cancelled
              ? action.sourceMailboxPath
              : (action.destinationMailboxPath ?? action.sourceMailboxPath);
          await repo.restoreEmails([
            original.copyWith(mailboxPath: currentPath),
          ]);
        }

        // A move out of the Snoozed folder ends the snooze (locally and, once
        // flushed, its server-side `snz:` keyword), so undoing it must put
        // the snooze back rather than leave the mail in Snoozed with no wake
        // time.
        // Only when going back to the Snoozed folder: a stale snooze on a mail
        // filed elsewhere (e.g. Archive) is not one to restore.
        final snoozedUntil = original?.snoozedUntil;
        final restoreSnooze = snoozedUntil != null &&
            original!.mailboxPath == action.sourceMailboxPath &&
            await repo.isSnoozedMailbox(
              action.accountId,
              action.sourceMailboxPath,
            );

        // Changes the reverse step queued, per email id (the mail's own and
        // its counterparts' in paired accounts), to cancel when the
        // original was.
        var reverseOps = const <String, List<int>>{};
        if (restoreSnooze && !cancelled) {
          // The move reached the server: snoozing again moves the mail back
          // to Snoozed and re-adds the keyword.
          await repo.snoozeEmail(currentId, snoozedUntil);
        } else {
          // 4. Move it back to source.
          // This updates local DB optimistically and (if not cancelled)
          // enqueues a reverse move on the server using the correct UID.
          if (recorded) {
            final (_, ops) = await repo.captureOps(
              () => repo.moveEmail(currentId, action.sourceMailboxPath),
            );
            reverseOps = ops;
          } else {
            await repo.moveEmail(currentId, action.sourceMailboxPath);
          }
        }

        if (cancelled) {
          // 5. If we successfully cancelled the original, the reverse move
          // we just enqueued is redundant.
          if (recorded) {
            await repo.cancelOps(reverseOps[currentId] ?? const []);
            // A counterpart's change (the same mail seen through a paired
            // account) was mirrored with the original and again with the
            // reverse step: both go when the original one is cancelled;
            // otherwise its reverse must stay to undo it on the server.
            for (final MapEntry(key: twin, value: reverse)
                in reverseOps.entries) {
              if (twin == currentId || action.emailIds.contains(twin)) continue;
              final forward = action.opSeqs[twin] ?? const <int>[];
              if (forward.isNotEmpty &&
                  (await repo.cancelOps(forward)).length == forward.length) {
                await repo.cancelOps(reverse);
              }
            }
            // A counterpart the reverse step queued nothing for: cancelling
            // the original already put the mail back (the moved folder is
            // the fold of its queued changes), so the reverse step found it
            // in place and mirrored nothing. Its own forward change goes
            // too, if nothing was sent for it.
            for (final MapEntry(key: twin, value: forward)
                in action.opSeqs.entries) {
              if (twin == currentId ||
                  action.emailIds.contains(twin) ||
                  reverseOps.containsKey(twin)) {
                continue;
              }
              await repo.cancelOps(forward);
            }
          } else {
            await repo.cancelPendingChange(currentId, 'move');
          }
          // The server never saw the move, so it still holds the snooze;
          // only the optimistic local clear needs undoing.
          if (restoreSnooze) {
            await repo.restoreLocalSnooze(
              currentId,
              until: snoozedUntil,
              fromMailboxPath: original.snoozedFromMailboxPath,
            );
          }
        }
      } catch (e) {
        // Best effort.
      }
    }

    await _markUndone(action);

    // Add a reverse action so the undo log always retains a record and the
    // user can re-apply the original operation. sourceMailboxPath on the
    // inverse is the original destination (e.g. Trash) so that undoing the
    // inverse moves emails back there; destinationMailboxPath records where
    // they are now (the original source, e.g. INBOX).
    final inverseDest = action.destinationMailboxPath;
    if (inverseDest != null) {
      await pushAction(
        UndoAction(
          id: '${action.id}${UndoAction.inverseSuffix}',
          accountId: action.accountId,
          type: UndoType.move,
          emailIds: action.emailIds,
          sourceMailboxPath: inverseDest,
          destinationMailboxPath: action.sourceMailboxPath,
          originalEmails: action.originalEmails,
          timestamp: DateTime.now(),
        ),
      );
    }
  }
}
