import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/undo_repository.dart';
import 'package:sharedinbox/core/services/undo_service.dart';
import 'package:sharedinbox/di.dart';

import 'helpers/undo_mock_stubs.dart';
import 'undo_service_test.mocks.dart';

/// Pushes [count] distinct move actions (`a0`..`a{count-1}`) onto [notifier],
/// awaiting each so the in-memory cap and DB trim run per push.
Future<void> _pushMoveActions(UndoService notifier, int count) async {
  for (var i = 0; i < count; i++) {
    await notifier.pushAction(
      UndoAction(
        id: 'a$i',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e$i'],
        sourceMailboxPath: 'INBOX',
      ),
    );
  }
}

@GenerateMocks([EmailRepository, UndoRepository])
void main() {
  late ProviderContainer container;
  late MockEmailRepository mockEmailRepo;
  late MockUndoRepository mockUndoRepo;

  setUp(() {
    mockEmailRepo = MockEmailRepository();
    mockUndoRepo = MockUndoRepository();

    when(
      mockUndoRepo.pushAndTrim(any, maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.trim(maxHistory: anyNamed('maxHistory')),
    ).thenAnswer((_) async {});
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);
    when(mockUndoRepo.clearHistory()).thenAnswer((_) async {});
    stubUndoEmailLookupsMiss(mockEmailRepo);

    container = ProviderContainer(
      overrides: [
        emailRepositoryProvider.overrideWithValue(mockEmailRepo),
        undoRepositoryProvider.overrideWithValue(mockUndoRepo),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  /// The `del1` delete-to-Trash action the undo-mark tests start from.
  UndoAction trashedAction({
    List<String> emailIds = const ['e1'],
    DateTime? timestamp,
  }) =>
      UndoAction(
        id: 'del1',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: emailIds,
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: 'Trash',
        timestamp: timestamp,
      );

  /// Stubs the email writes [UndoService.undo] performs, then returns an
  /// initialised notifier with [actions] pushed in order.
  Future<UndoService> pushForUndo(List<UndoAction> actions) async {
    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(
      mockEmailRepo.cancelPendingChange(any, any),
    ).thenAnswer((_) async => false);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    for (final action in actions) {
      await notifier.pushAction(action);
    }
    return notifier;
  }

  test('UndoService initial state is empty list', () {
    expect(container.read(undoServiceProvider), isEmpty);
  });

  test('pushAction maintains history and updates state', () async {
    final action1 = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    final action2 = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init(); // Wait for persistent load

    await notifier.pushAction(action1);
    expect(container.read(undoServiceProvider), [action1]);

    await notifier.pushAction(action2);
    expect(container.read(undoServiceProvider), [action1, action2]);
  });

  test('undo pops history and updates state', () async {
    // action1 has no destinationMailboxPath → no inverse action pushed.
    final action1 = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    // action2 has a destinationMailboxPath → inverse action IS pushed after undo.
    final action2 = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
      destinationMailboxPath: 'Trash',
    );

    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(
      mockEmailRepo.cancelPendingChange(any, any),
    ).thenAnswer((_) async => false);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(action1);
    await notifier.pushAction(action2);

    // Undo action2 (delete); the original entry is kept and a reverse action is added.
    await notifier.undo();
    final stateAfterUndo2 = container.read(undoServiceProvider);
    expect(stateAfterUndo2.length, 3);
    expect(stateAfterUndo2[0].id, '1');
    expect(stateAfterUndo2[1].id, '2');
    expect(stateAfterUndo2[2].id, '2-inv');
    expect(stateAfterUndo2[2].sourceMailboxPath, 'Trash');
    expect(stateAfterUndo2[2].destinationMailboxPath, 'INBOX');
    verify(mockEmailRepo.moveEmail('e2', 'INBOX')).called(1);

    // Undo action1 (no dest → no inverse); original stays, log is unchanged.
    await notifier.undo(actionId: '1');
    final stateAfterUndo1 = container.read(undoServiceProvider);
    expect(stateAfterUndo1.length, 3);
    expect(stateAfterUndo1[0].id, '1');
    expect(stateAfterUndo1[1].id, '2');
    expect(stateAfterUndo1[2].id, '2-inv');
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
  });

  test(
    'undo pushes inverse action into log when destinationMailboxPath is set',
    () async {
      final action = UndoAction(
        id: 'del1',
        accountId: 'acc1',
        type: UndoType.delete,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
        destinationMailboxPath: 'Trash',
      );

      when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
      when(
        mockEmailRepo.cancelPendingChange(any, any),
      ).thenAnswer((_) async => false);

      final notifier = container.read(undoServiceProvider.notifier);
      await notifier.init();
      await notifier.pushAction(action);
      await notifier.undo(actionId: 'del1');

      // Original entry stays; inverse is added.
      final log = container.read(undoServiceProvider);
      expect(log.length, 2);
      expect(log[0].id, 'del1');
      final inv = log[1];
      expect(inv.id, 'del1-inv');
      expect(inv.type, UndoType.move);
      expect(inv.emailIds, ['e1']);
      expect(inv.sourceMailboxPath, 'Trash');
      expect(inv.destinationMailboxPath, 'INBOX');
      verify(
        mockUndoRepo.pushAndTrim(
          argThat(predicate<UndoAction>((a) => a.id == 'del1-inv')),
          maxHistory: anyNamed('maxHistory'),
        ),
      ).called(1);
    },
  );

  test(
    'undo without destinationMailboxPath does not push inverse action',
    () async {
      final action = UndoAction(
        id: 'mv1',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
        // no destinationMailboxPath
      );

      when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
      when(
        mockEmailRepo.cancelPendingChange(any, any),
      ).thenAnswer((_) async => false);

      final notifier = container.read(undoServiceProvider.notifier);
      await notifier.init();
      await notifier.pushAction(action);
      await notifier.undo(actionId: 'mv1');

      // Original entry stays; no inverse since no destinationMailboxPath.
      final log = container.read(undoServiceProvider);
      expect(log.length, 1);
      expect(log.first.id, 'mv1');
    },
  );

  test('undo with actionId removes and undos specific action', () async {
    // action1 has no destination → no inverse action
    final action1 = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    final action2 = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(
      mockEmailRepo.cancelPendingChange(any, any),
    ).thenAnswer((_) async => false);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(action1);
    await notifier.pushAction(action2);

    // action1 has no destinationMailboxPath → no inverse pushed, original stays.
    await notifier.undo(actionId: '1');
    final log = container.read(undoServiceProvider);
    expect(log.map((a) => a.id), ['1', '2']);
    expect(log[0].undoneAt, isNotNull);
    expect(log[1], action2);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
    verifyNever(mockEmailRepo.moveEmail('e2', 'INBOX'));
  });

  test('undo marks the entry undone and persists the mark', () async {
    final notifier = await pushForUndo([trashedAction()]);
    expect(container.read(undoServiceProvider).single.undoneAt, isNull);

    await notifier.undo(actionId: 'del1');

    final log = container.read(undoServiceProvider);
    expect(log.first.undoneAt, isNotNull);
    expect(log.last.undoneAt, isNull, reason: 'the inverse still stands');
    verify(mockUndoRepo.setUndoneAt('del1', argThat(isNotNull))).called(1);
    verifyNever(mockUndoRepo.saveAction(any));
  });

  test('the undone entry takes the re-keyed email ids from the DB', () async {
    final action = trashedAction(emailIds: ['acc1:INBOX:7']);
    // A flush re-keyed the stored copy after the move reached the server.
    final rekeyed = trashedAction(
      emailIds: ['acc1:Trash:3'],
      timestamp: action.timestamp,
    );
    final notifier = await pushForUndo([action]);
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => [rekeyed]);

    await notifier.undo(actionId: 'del1');

    final entry = container.read(undoServiceProvider).first;
    expect(entry.emailIds, ['acc1:Trash:3']);
    expect(entry.undoneAt, isNotNull);
  });

  test('marks alternate up a chain of inverses', () async {
    final notifier = await pushForUndo([trashedAction()]);
    await notifier.undo(actionId: 'del1'); // back in INBOX
    await notifier.undo(actionId: 'del1-inv'); // in Trash again
    await notifier.undo(actionId: 'del1-inv-inv'); // back in INBOX

    final undone = {
      for (final a in container.read(undoServiceProvider))
        a.id: a.undoneAt != null,
    };
    expect(undone, {
      'del1': true,
      'del1-inv': false,
      'del1-inv-inv': true,
      'del1-inv-inv-inv': false,
    });
  });

  test('undo without an id skips entries that are already undone', () async {
    // No destination → undo pushes no inverse, so the undone entry stays last.
    final notifier = await pushForUndo([
      UndoAction(
        id: 'mv0',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e0'],
        sourceMailboxPath: 'INBOX',
      ),
      UndoAction(
        id: 'mv1',
        accountId: 'acc1',
        type: UndoType.move,
        emailIds: ['e1'],
        sourceMailboxPath: 'INBOX',
      ),
    ]);

    await notifier.undo();
    await notifier.undo();
    await notifier.undo(); // nothing left standing

    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
    verify(mockEmailRepo.moveEmail('e0', 'INBOX')).called(1);
  });

  test('undoing an entry twice keeps one inverse entry', () async {
    final notifier = await pushForUndo([trashedAction()]);
    await notifier.undo(actionId: 'del1');
    await notifier.undo(actionId: 'del1');

    expect(
      container.read(undoServiceProvider).map((a) => a.id),
      ['del1', 'del1-inv'],
    );
  });

  test('undoing the inverse clears the undone mark of the original', () async {
    final notifier = await pushForUndo([trashedAction()]);
    await notifier.undo(actionId: 'del1');
    await notifier.undo(actionId: 'del1-inv');

    final byId = {
      for (final a in container.read(undoServiceProvider)) a.id: a,
    };
    expect(byId.keys, ['del1', 'del1-inv', 'del1-inv-inv']);
    expect(byId['del1']!.undoneAt, isNull);
    expect(byId['del1-inv']!.undoneAt, isNotNull);
    expect(byId['del1-inv-inv']!.undoneAt, isNull);
  });

  test('undo performs cancelPendingChange optimization', () async {
    final action = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );

    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(
      mockEmailRepo.cancelPendingChange('e1', 'delete'),
    ).thenAnswer((_) async => false);
    when(
      mockEmailRepo.cancelPendingChange('e1', 'move'),
    ).thenAnswer((_) async => true);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(action);

    await notifier.undo();
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
    verify(mockEmailRepo.cancelPendingChange('e1', 'move')).called(2);
  });

  test('undo restores hard-deleted emails if provided', () async {
    final email = Email(
      id: 'e1',
      accountId: 'acc1',
      mailboxPath: 'Trash',
      uid: 10,
      from: [const EmailAddress(email: 'me@me.com')],
      to: [],
      cc: [],
      subject: 'hi',
      receivedAt: DateTime.now(),
      isSeen: true,
      isFlagged: false,
      hasAttachment: false,
    );
    final action = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
      originalEmails: [email],
    );

    when(
      mockEmailRepo.cancelPendingChange(any, any),
    ).thenAnswer((_) async => false);
    when(mockEmailRepo.restoreEmails(any)).thenAnswer((_) async {});
    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(action);

    await notifier.undo();

    verify(mockEmailRepo.restoreEmails(any)).called(1);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
  });

  test('init loads persisted history from repository', () async {
    final persisted = UndoAction(
      id: '99',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e99'],
      sourceMailboxPath: 'INBOX',
    );

    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => [persisted]);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();

    expect(container.read(undoServiceProvider), [persisted]);
  });

  test('pushAction after restart appends to persisted history', () async {
    final persisted = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    final newAction = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => [persisted]);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(newAction);

    expect(container.read(undoServiceProvider), [persisted, newAction]);
  });

  test('pushAction concurrent with init waits for init to complete', () async {
    final persisted = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    final raced = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    // Simulate slow DB load
    when(mockUndoRepo.getHistory(limit: anyNamed('limit'))).thenAnswer(
      (_) =>
          Future.delayed(const Duration(milliseconds: 10), () => [persisted]),
    );

    final notifier = container.read(undoServiceProvider.notifier);
    final initFuture = notifier.init();
    // pushAction issued before init completes — it must still see persisted history
    final pushFuture = notifier.pushAction(raced);

    await Future.wait([initFuture, pushFuture]);

    expect(container.read(undoServiceProvider), [persisted, raced]);
  });

  test('pushAction persists via pushAndTrim (atomic insert + trim)', () async {
    final action = UndoAction(
      id: 'a1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();
    await notifier.pushAction(action);

    verify(
      mockUndoRepo.pushAndTrim(action, maxHistory: anyNamed('maxHistory')),
    ).called(1);
    verifyNever(mockUndoRepo.saveAction(any));
    verifyNever(mockUndoRepo.deleteAction(any));
  });

  test('clear awaits the persisted delete', () async {
    final completer = Completer<void>();
    when(mockUndoRepo.clearHistory()).thenAnswer((_) => completer.future);

    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();

    final clearFuture = notifier.clear();
    // State is cleared eagerly so the UI updates immediately…
    expect(container.read(undoServiceProvider), isEmpty);
    // …but clear() must not resolve until the DB write finishes so a process
    // restart right after a successful clear() cannot resurrect entries.
    var resolved = false;
    unawaited(clearFuture.then((_) => resolved = true));
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);

    completer.complete();
    await clearFuture;
    expect(resolved, isTrue);
    verify(mockUndoRepo.clearHistory()).called(1);
  });

  test('init trims the persisted log down to the in-memory cap', () async {
    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();

    verify(mockUndoRepo.trim(maxHistory: anyNamed('maxHistory'))).called(1);
  });

  test('keeps well more than ten actions in history', () async {
    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();

    await _pushMoveActions(notifier, 50);

    // The old cap of 10 would have dropped the earliest 40 entries.
    expect(container.read(undoServiceProvider), hasLength(50));
    expect(container.read(undoServiceProvider).first.id, 'a0');
    expect(container.read(undoServiceProvider).last.id, 'a49');
  });

  test('caps history at 100 and drops the oldest entries', () async {
    final notifier = container.read(undoServiceProvider.notifier);
    await notifier.init();

    await _pushMoveActions(notifier, 105);

    final state = container.read(undoServiceProvider);
    expect(state, hasLength(100));
    // Oldest five (a0..a4) trimmed; window is a5..a104.
    expect(state.first.id, 'a5');
    expect(state.last.id, 'a104');
  });
}
