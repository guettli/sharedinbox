import 'package:mockito/mockito.dart';

import '../undo_service_test.mocks.dart';

/// Stubs the email lookups [UndoService.undo] performs so they find nothing.
/// Shared by undo_service_test.dart and undo_shell_test.dart so both suites
/// use the same stubs without tripping the jscpd duplication gate.
void stubUndoEmailLookupsMiss(MockEmailRepository repo) {
  when(repo.getEmail(any)).thenAnswer((_) async => null);
  when(
    repo.findEmailByMessageId(
      any,
      any,
      preferMailboxPath: anyNamed('preferMailboxPath'),
    ),
  ).thenAnswer((_) async => null);
}
