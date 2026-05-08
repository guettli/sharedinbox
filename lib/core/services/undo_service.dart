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
      // Optimization: if the original change is still in the queue and hasn't
      // been attempted yet, we can just remove it from the queue.
      // Whether it was a move or a delete, the local state change needs
      // to be reversed.
      final cancelled = await repo.cancelPendingChange(
        id,
        action.type == UndoType.delete ? 'delete' : 'move',
      );

      // Whether cancelled or not, we move the email back to its source
      // to restore the local DB state and (if not cancelled) enqueue
      // the reverse change on the server.
      try {
        await repo.moveEmail(id, action.sourceMailboxPath);

        if (cancelled) {
          // If we cancelled the original change, and then moved it back,
          // we've just enqueued a NEW 'move' change that is redundant
          // (because the server never saw the first one).
          // So we should cancel this one too!
          await repo.cancelPendingChange(id, 'move');
        }
      } catch (e) {
        // If the row is gone (hard delete), we can't undo it locally.
        // TODO: Could consider re-fetching if it was a JMAP delete that
        // hasn't synced yet, but that's complex.
      }
    }
  }
}
