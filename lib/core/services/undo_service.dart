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
    
    // For IMAP, the rows were hard-deleted, so we must restore them first.
    if (action.originalEmails.isNotEmpty) {
      await repo.restoreEmails(action.originalEmails);
    }

    for (final id in action.emailIds) {
      // Try to cancel the original change. 
      // Deletes might have been implemented as moves to Trash, so try both.
      final cancelled = await repo.cancelPendingChange(id, 'delete') ||
          await repo.cancelPendingChange(id, 'move');

      // Move the email back to its source to reverse local DB state and
      // (if not cancelled) enqueue the reverse change on the server.
      try {
        await repo.moveEmail(id, action.sourceMailboxPath);

        if (cancelled) {
          // If we cancelled the original change, and then moved it back,
          // we've just enqueued a NEW 'move' change that is redundant.
          await repo.cancelPendingChange(id, 'move');
        }
      } catch (e) {
        // If it still fails, nothing more we can do locally.
      }
    }
  }
}
