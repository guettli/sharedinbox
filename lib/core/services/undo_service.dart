import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoService extends Notifier<List<UndoAction>> {
  static const int _maxHistory = 10;

  // Resolves once build() has loaded persisted history.
  late Future<void> _ready;

  @override
  List<UndoAction> build() {
    _ready = ref.read(undoRepositoryProvider).getHistory().then((history) {
      if (ref.mounted) state = history;
    });
    return [];
  }

  /// Waits for the persisted history to finish loading. Called by tests to
  /// ensure the provider is ready before asserting state.
  Future<void> init() => _ready;

  Future<void> pushAction(UndoAction action) async {
    await _ready;
    final newList = [...state, action];
    if (newList.length > _maxHistory) {
      final removed = newList.removeAt(0);
      await ref.read(undoRepositoryProvider).deleteAction(removed.id);
    }
    state = newList;
    await ref.read(undoRepositoryProvider).saveAction(action);
  }

  Future<void> clear() async {
    await _ready;
    state = [];
    unawaited(ref.read(undoRepositoryProvider).clearHistory());
  }

  Future<void> undo({String? actionId}) async {
    await _ready;
    if (state.isEmpty) return;

    final UndoAction action;
    if (actionId == null) {
      action = state.last;
    } else {
      try {
        action = state.firstWhere((a) => a.id == actionId);
      } catch (e) {
        return; // Action not found
      }
    }

    // Keep the original entry in state and DB so the user can see what
    // happened and retry if the undo failed (e.g. after an IMAP sync reverted
    // the local change). The inverse action added below allows undoing the undo.

    final repo = ref.read(emailRepositoryProvider);

    for (final id in action.emailIds) {
      // 1. Try to cancel the original change (if not started yet).
      final cancelled =
          await repo.cancelPendingChange(id, 'delete') ||
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
          currentEmail = await repo.findEmailByMessageId(
            action.accountId,
            original!.messageId!,
          );
        }
        final currentId = currentEmail?.id ?? id;

        // 3. If the row is absent (hard delete or UID changed after sync),
        // restore it from the saved snapshot so moveEmail can find it.
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

    // Add a reverse action so the undo log always retains a record and the
    // user can re-apply the original operation. sourceMailboxPath on the
    // inverse is the original destination (e.g. Trash) so that undoing the
    // inverse moves emails back there; destinationMailboxPath records where
    // they are now (the original source, e.g. INBOX).
    final inverseDest = action.destinationMailboxPath;
    if (inverseDest != null) {
      await pushAction(
        UndoAction(
          id: '${action.id}-inv',
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
