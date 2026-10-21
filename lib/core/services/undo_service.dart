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

  /// Returns the persisted copy of [action]. When the original move reached
  /// the server, the IMAP re-key rewrote the email ids in the stored action
  /// (see `_rekeyEmailRow`) but not in [state], so the in-memory copy may
  /// still reference the pre-move id (#1048).
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
            // Take the persisted copy's (possibly re-keyed) email ids.
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

    for (final id in action.emailIds) {
      // 1. Try to cancel the original change (if not started yet).
      final cancelled = await repo.cancelPendingChange(id, 'delete') ||
          await repo.cancelPendingChange(id, 'move') ||
          await repo.cancelPendingChange(id, 'snooze');

      try {
        final original = action.originalEmails.isEmpty
            ? null
            : action.originalEmails.where((e) => e.id == id).firstOrNull;

        // 2. Resolve the current DB row for the email.
        // For IMAP, after a server-applied move the email gets a new UID, so
        // the original id ('accountId:oldUid') no longer exists. Look it up by
        // Message-ID so we use the correct UID in the pending change.
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

        // 3. If the row is absent (hard delete or UID changed after sync),
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

        // 4. Move it back to source.
        // This updates local DB optimistically and (if not cancelled) enqueues
        // a reverse move on the server using the correct UID.
        await repo.moveEmail(currentId, action.sourceMailboxPath);

        if (cancelled) {
          // 5. If we successfully cancelled the original, the reverse move
          // we just enqueued is redundant.
          await repo.cancelPendingChange(currentId, 'move');
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
