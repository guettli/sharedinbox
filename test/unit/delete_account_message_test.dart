import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/core/models/account.dart';
import 'package:sharedinbox/core/repositories/unsynced_work_repository.dart';
import 'package:sharedinbox/ui/screens/account_actions.dart';

void main() {
  const account = Account(
    id: 'acc1',
    displayName: 'Work',
    email: 'me@example.com',
  );

  test('singular and plural wording', () {
    expect(
      const UnsyncedWork(
        queuedChanges: 1,
        unsentEmails: 1,
        unsyncedNotes: 1,
        localFilters: 1,
        notificationRules: 1,
      ).describe(),
      [
        '1 unsent email',
        '1 queued change (read, star, move, delete, snooze)',
        '1 new note',
        '1 local filter',
        '1 notification rule',
      ],
    );
    expect(
      const UnsyncedWork(queuedChanges: 3, unsentEmails: 2).describe(),
      [
        '2 unsent emails',
        '3 queued changes (read, star, move, delete, snooze)',
      ],
    );
  });

  test('no device-only work keeps the short confirmation', () {
    expect(
      deleteAccountMessage(account, const UnsyncedWork()),
      'Remove "Work" (me@example.com)? This cannot be undone.',
    );
  });

  test('device-only work is listed as lost', () {
    final text = deleteAccountMessage(
      account,
      const UnsyncedWork(unsentEmails: 2),
    );
    expect(text, contains('Only on this device, and will be lost:'));
    expect(text, contains('• 2 unsent emails'));
  });
}
