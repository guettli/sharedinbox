import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/di.dart';

class UndoService extends StateNotifier<UndoAction?> {
  UndoService(this._ref) : super(null);

  final Ref _ref;
  final ListQueue<UndoAction> _history = ListQueue<UndoAction>();
  static const int _maxHistory = 10;

  void pushAction(UndoAction action) {
    _history.addLast(action);
    if (_history.length > _maxHistory) {
      _history.removeFirst();
    }
    state = action;
  }

  void clear() {
    _history.clear();
    state = null;
  }

  Future<void> undo() async {
    if (_history.isEmpty) return;

    final action = _history.removeLast();
    // Update state to the new last action or null
    state = _history.isNotEmpty ? _history.last : null;

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
