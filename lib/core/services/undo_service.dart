import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoService extends StateNotifier<List<UndoAction>> {
  UndoService(this._ref) : super([]);

  final Ref _ref;
  static const int _maxHistory = 10;

  Future<void> init() async {
    final repo = _ref.read(undoRepositoryProvider);
    state = await repo.getHistory();
  }

  void pushAction(UndoAction action) {
    final newList = [...state, action];
    if (newList.length > _maxHistory) {
      final removed = newList.removeAt(0);
      unawaited(_ref.read(undoRepositoryProvider).deleteAction(removed.id));
    }
    state = newList;
    unawaited(_ref.read(undoRepositoryProvider).saveAction(action));
  }

  void clear() {
    state = [];
    unawaited(_ref.read(undoRepositoryProvider).clearHistory());
  }

  Future<void> undo({String? actionId}) async {
    if (state.isEmpty) return;

    final UndoAction action;
    if (actionId == null) {
      action = state.last;
      state = state.sublist(0, state.length - 1);
    } else {
      try {
        action = state.firstWhere((a) => a.id == actionId);
        state = state.where((a) => a.id != actionId).toList();
      } catch (e) {
        return; // Action not found
      }
    }

    unawaited(_ref.read(undoRepositoryProvider).deleteAction(action.id));

    final repo = _ref.read(emailRepositoryProvider);

    for (final id in action.emailIds) {
      // 1. Try to cancel the original change (if not started yet).
      final cancelled = await repo.cancelPendingChange(id, 'delete') ||
          await repo.cancelPendingChange(id, 'move') ||
          await repo.cancelPendingChange(id, 'snooze');

      try {
        final original = action.originalEmails.isEmpty
            ? null
            : action.originalEmails.where((e) => e.id == id).firstOrNull;

        // 2. If row is missing (hard delete), restore it first.
        // We restore it at its CURRENT state (where it is on the server,
        // or where it was moving to).
        if (original != null) {
          final currentPath = cancelled
              ? action.sourceMailboxPath
              : (action.destinationMailboxPath ?? action.sourceMailboxPath);
          await repo.restoreEmails([
            original.copyWith(mailboxPath: currentPath),
          ]);
        }

        // 3. Move it back to source.
        // This updates local DB optimistically and (if not cancelled) enqueues
        // a reverse move on the server.
        await repo.moveEmail(id, action.sourceMailboxPath);

        if (cancelled) {
          // 4. If we successfully cancelled the original, the reverse move
          // we just enqueued is redundant.
          await repo.cancelPendingChange(id, 'move');
        }
      } catch (e) {
        // Best effort.
      }
    }
  }
}
