import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sharedinbox/ui/widgets/mailbox_role.dart';

void main() {
  group('mailboxRoleLabel', () {
    test('maps known roles to human-readable labels', () {
      expect(mailboxRoleLabel('inbox'), 'Inbox');
      expect(mailboxRoleLabel('sent'), 'Sent');
      expect(mailboxRoleLabel('drafts'), 'Drafts');
      expect(mailboxRoleLabel('junk'), 'Junk');
      expect(mailboxRoleLabel('trash'), 'Trash');
      expect(mailboxRoleLabel('archive'), 'Archive');
      expect(mailboxRoleLabel('snoozed'), 'Snoozed');
    });

    test('returns null for null / unknown roles', () {
      expect(mailboxRoleLabel(null), isNull);
      expect(mailboxRoleLabel('custom'), isNull);
    });
  });

  group('mailboxRoleIcon', () {
    test('maps known roles to distinct icons', () {
      expect(mailboxRoleIcon('inbox'), Icons.inbox);
      expect(mailboxRoleIcon('sent'), Icons.send);
      expect(mailboxRoleIcon('trash'), Icons.delete);
      expect(mailboxRoleIcon('archive'), Icons.archive);
    });

    test('falls back to the generic folder icon for null / unknown roles', () {
      expect(mailboxRoleIcon(null), Icons.folder);
      expect(mailboxRoleIcon('custom'), Icons.folder);
    });
  });
}
