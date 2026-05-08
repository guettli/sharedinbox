import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/undo_action.dart';
import 'package:sharedinbox/core/repositories/email_repository.dart';
import 'package:sharedinbox/di.dart';

import 'undo_service_test.mocks.dart';

@GenerateMocks([EmailRepository])
void main() {
  late ProviderContainer container;
  late MockEmailRepository mockEmailRepo;

  setUp(() {
    mockEmailRepo = MockEmailRepository();
    container = ProviderContainer(
      overrides: [
        emailRepositoryProvider.overrideWithValue(mockEmailRepo),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('UndoService initial state is null', () {
    expect(container.read(undoServiceProvider), isNull);
  });

  test('pushAction maintains history and updates state to latest', () {
    const action1 = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    const action2 = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    final notifier = container.read(undoServiceProvider.notifier);
    notifier.pushAction(action1);
    expect(container.read(undoServiceProvider), action1);

    notifier.pushAction(action2);
    expect(container.read(undoServiceProvider), action2);
  });

  test('undo pops history and updates state to previous action', () async {
    const action1 = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );
    const action2 = UndoAction(
      id: '2',
      accountId: 'acc1',
      type: UndoType.delete,
      emailIds: ['e2'],
      sourceMailboxPath: 'INBOX',
    );

    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(mockEmailRepo.cancelPendingChange(any, any))
        .thenAnswer((_) async => false);

    final notifier = container.read(undoServiceProvider.notifier);
    notifier.pushAction(action1);
    notifier.pushAction(action2);

    await notifier.undo();
    expect(container.read(undoServiceProvider), action1);
    verify(mockEmailRepo.moveEmail('e2', 'INBOX')).called(1);

    await notifier.undo();
    expect(container.read(undoServiceProvider), isNull);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
  });

  test('undo performs cancelPendingChange optimization', () async {
    const action = UndoAction(
      id: '1',
      accountId: 'acc1',
      type: UndoType.move,
      emailIds: ['e1'],
      sourceMailboxPath: 'INBOX',
    );

    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});
    when(mockEmailRepo.cancelPendingChange('e1', 'move'))
        .thenAnswer((_) async => true);

    container.read(undoServiceProvider.notifier).pushAction(action);
    await container.read(undoServiceProvider.notifier).undo();

    // Should cancel the original move, then perform the local move back,
    // then cancel the redundant reverse move.
    verify(mockEmailRepo.cancelPendingChange('e1', 'move')).called(2);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
  });

  test('undo does nothing if history is empty', () async {
    await container.read(undoServiceProvider.notifier).undo();
    verifyNever(mockEmailRepo.moveEmail(any, any));
  });
}
