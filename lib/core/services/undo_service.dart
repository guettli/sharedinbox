import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoService extends StateNotifier<List<UndoAction>> {
  UndoService(this._ref) : super([]);

  final Ref _ref;
  static const int _maxHistory = 10;

  void pushAction(UndoAction action) {
    final newList = [...state, action];
    if (newList.length > _maxHistory) {
      newList.removeAt(0);
    }
    state = newList;
  }

  void clear() {
    state = [];
  }

  Future<void> undo() async {
    if (state.isEmpty) return;

    final action = state.last;
    state = state.sublist(0, state.length - 1);

    final repo = _ref.read(emailRepositoryProvider);

    for (final id in action.emailIds) {
      // 1. Try to cancel the original change (if not started yet).
      final cancelled = await repo.cancelPendingChange(id, 'delete') ||
          await repo.cancelPendingChange(id, 'move');

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
          await repo
              .restoreEmails([original.copyWith(mailboxPath: currentPath)]);
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
