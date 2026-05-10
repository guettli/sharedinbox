import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:sharedinbox/core/models/email.dart';
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

  test('UndoService initial state is empty list', () {
    expect(container.read(undoServiceProvider), isEmpty);
  });

  test('pushAction maintains history and updates state', () {
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
    notifier.pushAction(action1);
    expect(container.read(undoServiceProvider), [action1]);

    notifier.pushAction(action2);
    expect(container.read(undoServiceProvider), [action1, action2]);
  });

  test('undo pops history and updates state', () async {
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
    when(mockEmailRepo.cancelPendingChange(any, any))
        .thenAnswer((_) async => false);

    final notifier = container.read(undoServiceProvider.notifier);
    notifier.pushAction(action1);
    notifier.pushAction(action2);

    await notifier.undo();
    expect(container.read(undoServiceProvider), [action1]);
    verify(mockEmailRepo.moveEmail('e2', 'INBOX')).called(1);

    await notifier.undo();
    expect(container.read(undoServiceProvider), isEmpty);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
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
    when(mockEmailRepo.cancelPendingChange('e1', 'delete'))
        .thenAnswer((_) async => false);
    when(mockEmailRepo.cancelPendingChange('e1', 'move'))
        .thenAnswer((_) async => true);

    final notifier = container.read(undoServiceProvider.notifier);
    notifier.pushAction(action);

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

    when(mockEmailRepo.cancelPendingChange(any, any))
        .thenAnswer((_) async => false);
    when(mockEmailRepo.restoreEmails(any)).thenAnswer((_) async {});
    when(mockEmailRepo.moveEmail(any, any)).thenAnswer((_) async {});

    final notifier = container.read(undoServiceProvider.notifier);
    notifier.pushAction(action);

    await notifier.undo();

    verify(mockEmailRepo.restoreEmails(any)).called(1);
    verify(mockEmailRepo.moveEmail('e1', 'INBOX')).called(1);
  });
}
