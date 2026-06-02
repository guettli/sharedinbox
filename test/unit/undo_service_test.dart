import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/email.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/core/repositories/undo_repository.dart';
import 'package:sharedinbox/di.dart';

import 'undo_service_test.mocks.dart';

@GenerateMocks([EmailRepository, UndoRepository])
void main() {
  late ProviderContainer container;
  late MockEmailRepository mockEmailRepo;
  late MockUndoRepository mockUndoRepo;

  setUp(() {
    mockEmailRepo = MockEmailRepository();
    mockUndoRepo = MockUndoRepository();

    when(mockUndoRepo.saveAction(any)).thenAnswer((_) async {});
    when(mockUndoRepo.deleteAction(any)).thenAnswer((_) async {});
    when(
      mockUndoRepo.getHistory(limit: anyNamed('limit')),
    ).thenAnswer((_) async => []);
    when(mockEmailRepo.getEmail(any)).thenAnswer((_) async => null);
    when(
      mockEmailRepo.findEmailByMessageId(any, any),
    ).thenAnswer((_) async => null);

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
        mockUndoRepo.saveAction(
          argThat(predicate<UndoAction>((a) => a.id == 'del1-inv')),
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
    expect(container.read(undoServiceProvider), [action1, action2]);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
    verifyNever(mockEmailRepo.moveEmail('e2', 'INBOX'));
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
}
